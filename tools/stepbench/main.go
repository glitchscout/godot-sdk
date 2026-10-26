// Command stepbench measures the Glitchscout Godot SDK's per-step overhead. It stands in for the
// orchestrator: listens on loopback, launches Godot on an empty scene with the SDK, completes the
// handshake and times STEP{ticks:1} round trips. It prints a JSON summary and exits 1 when the median is
// over -max-p50-ms (2 when the benchmark couldn't run).
//
//	go run . [-godot PATH] [-project DIR] [-steps 1000] [-max-p50-ms 5]
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"time"

	"github.com/coder/websocket"
)

type config struct {
	godot, project, scene string
	warmup, steps         int
}

func main() {
	godot := os.Getenv("GODOT_BIN")
	if godot == "" {
		godot = "godot"
	}
	cfg := config{}
	flag.StringVar(&cfg.godot, "godot", godot, "Godot binary ($GODOT_BIN)")
	flag.StringVar(&cfg.project, "project", "../..", "the SDK's Godot project directory")
	flag.StringVar(&cfg.scene, "scene", "res://bench/empty.tscn", "scene to run")
	flag.IntVar(&cfg.warmup, "warmup", 100, "steps before measuring")
	flag.IntVar(&cfg.steps, "steps", 1000, "steps measured")
	maxP50 := flag.Float64("max-p50-ms", 5, "fail when the median step round trip is over this")
	timeout := flag.Duration("timeout", 2*time.Minute, "give up after this long")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	s, err := run(ctx, cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "stepbench:", err)
		os.Exit(2)
	}
	out, _ := json.MarshalIndent(s, "", "  ")
	fmt.Println(string(out))
	if err := gate(s, *maxP50); err != nil {
		fmt.Fprintln(os.Stderr, "stepbench:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg config) (Summary, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return Summary{}, err
	}
	conns := make(chan *websocket.Conn, 1)
	srv := &http.Server{ReadHeaderTimeout: 10 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c, err := websocket.Accept(w, r, nil); err == nil {
			conns <- c
		}
	})}
	go func() { _ = srv.Serve(ln) }()
	defer func() { _ = srv.Close() }()

	token := newID()
	var godotOut bytes.Buffer
	cmd := exec.CommandContext(ctx, cfg.godot, "--headless", "--fixed-fps", "60", "--audio-driver", "Dummy",
		"--path", cfg.project, cfg.scene, "--",
		"--glitchscout-endpoint=ws://"+ln.Addr().String()+"/", "--glitchscout-token="+token)
	cmd.Stdout, cmd.Stderr = &godotOut, &godotOut
	if err := cmd.Start(); err != nil {
		return Summary{}, err
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()
	fail := func(err error) (Summary, error) {
		return Summary{}, fmt.Errorf("%w\nGodot output:\n%s", err, godotOut.String())
	}

	var conn *websocket.Conn
	select {
	case conn = <-conns:
	case <-ctx.Done():
		return fail(errors.New("the SDK never connected"))
	}
	conn.SetReadLimit(4 << 20)
	defer func() { _ = conn.CloseNow() }()

	hello, err := next(ctx, conn, "HELLO", "")
	if err != nil {
		return fail(err)
	}
	if err := send(ctx, conn, "HELLO_ACK", hello.ID, map[string]any{"protocol": "glitchscout/1", "session": "s-bench", "resumed": false}); err != nil {
		return fail(err)
	}
	var samples []time.Duration
	for i := range cfg.warmup + cfg.steps {
		id := newUUID()
		start := time.Now()
		if err := sendID(ctx, conn, id, "STEP", "", map[string]any{"ticks": 1}); err != nil {
			return fail(err)
		}
		reply, err := next(ctx, conn, "", id)
		if err != nil {
			return fail(err)
		}
		if reply.MessageType != "ACK" {
			return fail(fmt.Errorf("STEP %d got %s: %s", i, reply.MessageType, reply.Payload))
		}
		if i >= cfg.warmup {
			samples = append(samples, time.Since(start))
		}
	}
	_ = send(ctx, conn, "GOODBYE", "", map[string]any{"reason": "benchmark over"})
	return summarize(samples), nil
}

type message struct {
	MessageType string          `json:"message_type"`
	ID          string          `json:"id"`
	ReplyTo     *string         `json:"reply_to"`
	Payload     json.RawMessage `json:"payload"`
}

// next reads until a message of the given type, or one answering replyTo (heartbeats in between are skipped).
func next(ctx context.Context, conn *websocket.Conn, messageType, replyTo string) (message, error) {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return message{}, err
		}
		var m message
		if err := json.Unmarshal(data, &m); err != nil {
			return message{}, fmt.Errorf("bad message from the SDK: %w", err)
		}
		if (messageType != "" && m.MessageType == messageType) || (replyTo != "" && m.ReplyTo != nil && *m.ReplyTo == replyTo) {
			return m, nil
		}
	}
}

func send(ctx context.Context, conn *websocket.Conn, messageType, replyTo string, payload any) error {
	return sendID(ctx, conn, newUUID(), messageType, replyTo, payload)
}

func sendID(ctx context.Context, conn *websocket.Conn, id, messageType, replyTo string, payload any) error {
	env := map[string]any{
		"protocol": "glitchscout/1", "message_type": messageType, "id": id, "reply_to": nil,
		"session": "s-bench", "tick_frame": nil, "ts": float64(time.Now().UnixMilli()) / 1000, "payload": payload,
	}
	if replyTo != "" {
		env["reply_to"] = replyTo
	}
	b, err := json.Marshal(env)
	if err != nil {
		return err
	}
	return conn.Write(ctx, websocket.MessageText, b)
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// newUUID returns a random RFC 4122 version 4 UUID, as the protocol's message ids are.
func newUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}
