// Command schemacheck validates JSON protocol messages captured from the SDK's tests against the
// glitchscout/1 schemas in github.com/glitchscout/protocol, and binary frames against binary-frame-v1.
//
//	go run . [-min n] [-frames dir] <dir>   # every *.json file in dir must be a valid message; -min
//	                                        # requires n of them; every *.bin in -frames a valid frame
package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"sort"

	"github.com/santhosh-tekuri/jsonschema/v6"

	spec "github.com/glitchscout/protocol"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "schemacheck:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("schemacheck", flag.ContinueOnError)
	minMessages := fs.Int("min", 0, "fail unless at least this many messages were captured")
	framesDir := fs.String("frames", "", "a directory of binary frames (*.bin) to validate too")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: schemacheck [-min n] <dir>")
	}
	n, bad, err := check(fs.Arg(0))
	if err != nil {
		return err
	}
	fmt.Printf("schemacheck: %d messages, %d invalid\n", n, bad)
	switch {
	case bad > 0:
		return fmt.Errorf("%d invalid messages", bad)
	case n < *minMessages:
		return fmt.Errorf("only %d messages captured, want at least %d: is the test mock still saving them?", n, *minMessages)
	}
	if *framesDir == "" {
		return nil
	}
	frames, problems, err := checkFrames(*framesDir)
	if err != nil {
		return err
	}
	for _, p := range problems {
		fmt.Fprintln(os.Stderr, p)
	}
	fmt.Printf("schemacheck: %d binary frames, %d problems\n", frames, len(problems))
	if len(problems) > 0 {
		return fmt.Errorf("%d binary frame problems", len(problems))
	}
	return nil
}

// header is binary-frame-v1's 64-byte header (all little-endian).
type header struct {
	Magic         [4]byte
	HeaderVersion uint8
	FrameType     uint8
	Encoding      uint8
	Flags         uint8
	HeaderLength  uint16
	Reserved0     uint16
	PayloadLength uint32
	TickFrame     uint64
	RequestID     [16]byte
	Width         uint16
	Height        uint16
	SourceWidth   uint16
	SourceHeight  uint16
	ChunkIndex    uint16
	ChunkCount    uint16
	PayloadCRC32  uint32
	Reserved1     [8]byte
}

const (
	maxFrame     = 4 << 20
	flagFinal    = 1 << 0
	flagChunked  = 1 << 1
	maxChunkSize = 1 << 20
)

// frameReason applies binary-frame-v1's validation order to one message: "" if it's valid, else the
// spec's reason (request matching, step 8, needs a live session and isn't checked).
func frameReason(msg []byte) string {
	if len(msg) < 64 {
		return "truncated"
	}
	h := parseHeader(msg)
	switch {
	case string(h.Magic[:]) != "GSBF":
		return "bad_magic"
	case h.HeaderVersion < 1:
		return "bad_version"
	case h.HeaderLength < 64:
		return "bad_header_length"
	case int(h.HeaderLength)+int(h.PayloadLength) != len(msg):
		return "length_mismatch"
	case len(msg) > maxFrame:
		return "too_large"
	case crc32.ChecksumIEEE(msg[h.HeaderLength:]) != h.PayloadCRC32:
		return "bad_crc"
	}
	return ""
}

func parseHeader(msg []byte) header {
	var h header
	_ = binary.Read(bytes.NewReader(msg[:64]), binary.LittleEndian, &h)
	return h
}

type chunk struct {
	file string
	h    header
	size int
}

// checkFrames validates every *.bin in dir and checks that chunked frames form complete sets that
// reassemble within the size cap. It returns the frame count and one line per problem.
func checkFrames(dir string) (n int, problems []string, err error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.bin"))
	if err != nil {
		return 0, nil, err
	}
	sets := map[[16]byte][]chunk{}
	for _, f := range files {
		msg, err := os.ReadFile(f)
		if err != nil {
			return n, problems, err
		}
		n++
		if r := frameReason(msg); r != "" {
			problems = append(problems, fmt.Sprintf("%s: %s", filepath.Base(f), r))
			continue
		}
		if h := parseHeader(msg); h.Flags&flagChunked != 0 {
			sets[h.RequestID] = append(sets[h.RequestID], chunk{filepath.Base(f), h, int(h.PayloadLength)})
		}
	}
	for _, set := range sets {
		if p := checkSet(set); p != "" {
			problems = append(problems, p)
		}
	}
	sort.Strings(problems)
	return n, problems, nil
}

func checkSet(set []chunk) string {
	sort.Slice(set, func(i, j int) bool { return set[i].h.ChunkIndex < set[j].h.ChunkIndex })
	first := set[0]
	count := int(first.h.ChunkCount)
	total := 0
	for i, c := range set {
		switch {
		case int(c.h.ChunkCount) != count:
			return c.file + ": chunk_count_mismatch"
		case int(c.h.ChunkIndex) >= count:
			return c.file + ": chunk_index_out_of_range"
		case i > 0 && c.h.ChunkIndex == set[i-1].h.ChunkIndex:
			return c.file + ": duplicate_chunk"
		case c.h.FrameType != first.h.FrameType || c.h.Encoding != first.h.Encoding || c.h.TickFrame != first.h.TickFrame ||
			c.h.Width != first.h.Width || c.h.Height != first.h.Height:
			return c.file + ": chunk_mismatch"
		case c.size > maxChunkSize:
			return fmt.Sprintf("%s: chunk payload %d bytes is over 1 MiB", c.file, c.size)
		case (int(c.h.ChunkIndex) == count-1) != (c.h.Flags&flagFinal != 0):
			return c.file + ": final_chunk flag on the wrong chunk"
		}
		total += c.size
	}
	switch {
	case len(set) != count:
		return fmt.Sprintf("%s: incomplete (%d of %d chunks)", first.file, len(set), count)
	case total+64 > maxFrame:
		return first.file + ": assembled_too_large"
	}
	return ""
}

func check(dir string) (n, bad int, err error) {
	c, err := spec.Compiler(spec.FS)
	if err != nil {
		return 0, 0, err
	}
	sch, err := c.Compile(spec.SchemaURL("schemas/message.schema.json"))
	if err != nil {
		return 0, 0, err
	}
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return 0, 0, err
	}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return n, bad, err
		}
		n++
		doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
		if err == nil {
			err = sch.Validate(doc)
		}
		if err != nil {
			bad++
			fmt.Fprintf(os.Stderr, "%s: %s\n%v\n", filepath.Base(f), data, err)
		}
	}
	return n, bad, nil
}
