package main

import (
	"encoding/json"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	spec "github.com/glitchscout/protocol"
)

func TestCheck(t *testing.T) {
	dir := t.TempDir()
	valid := `{"protocol":"glitchscout/1","message_type":"HEARTBEAT","id":"00000001-0000-4000-8000-000000000001",` +
		`"reply_to":null,"session":"s-1","tick_frame":3,"ts":1.5,"payload":{"uptime_ms":10}}`
	invalid := `{"protocol":"glitchscout/1","message_type":"HEARTBEAT","id":"nope","reply_to":null,` +
		`"session":null,"tick_frame":null,"ts":1,"payload":{}}`
	for name, body := range map[string]string{"a.json": valid, "b.json": invalid, "note.txt": "ignored"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	n, bad, err := check(dir)
	if err != nil || n != 2 || bad != 1 {
		t.Fatalf("check = %d, %d, %v; want 2 messages, 1 invalid", n, bad, err)
	}
}

func TestRequireMessages(t *testing.T) {
	if err := run([]string{"-min", "1", t.TempDir()}); err == nil {
		t.Fatal("an empty directory passed with -min 1")
	}
	if err := run([]string{t.TempDir()}); err != nil {
		t.Fatalf("an empty directory without -min: %v", err)
	}
}

func copyFixtures(t *testing.T, from, to string, skip ...string) {
	t.Helper()
	entries, err := fs.ReadDir(spec.FS, from)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".bin") || slices.Contains(skip, e.Name()) {
			continue
		}
		b, err := spec.FS.ReadFile(path.Join(from, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(to, e.Name()), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestFrameReasonsMatchTheProtocolFixtures(t *testing.T) {
	entries, err := fs.ReadDir(spec.FS, "fixtures/binary/invalid")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".bin") {
			continue
		}
		b, _ := spec.FS.ReadFile("fixtures/binary/invalid/" + e.Name())
		j, _ := spec.FS.ReadFile("fixtures/binary/invalid/" + strings.TrimSuffix(e.Name(), ".bin") + ".json")
		var want struct {
			Reason string `json:"reason"`
		}
		if err := json.Unmarshal(j, &want); err != nil {
			t.Fatal(err)
		}
		if got := frameReason(b); got != want.Reason {
			t.Errorf("%s: frameReason = %q, want %q", e.Name(), got, want.Reason)
		}
	}
}

func TestCheckFrames(t *testing.T) {
	valid := t.TempDir()
	copyFixtures(t, "fixtures/binary/valid", valid)
	copyFixtures(t, "fixtures/binary/chunked/png-3-chunks", valid)
	n, problems, err := checkFrames(valid)
	if err != nil || n != 8 || len(problems) != 0 {
		t.Fatalf("checkFrames(valid) = %d, %q, %v; want 8 frames, no problems", n, problems, err)
	}
	broken := t.TempDir()
	copyFixtures(t, "fixtures/binary/chunked/png-3-chunks", broken, "chunk-1.bin")
	copyFixtures(t, "fixtures/binary/invalid", broken, "truncated.bin", "bad-magic.bin", "bad-version.bin",
		"bad-header-length.bin", "length-mismatch.bin", "truncated-payload.bin")
	_, problems, err = checkFrames(broken)
	if err != nil || len(problems) != 2 || !strings.Contains(strings.Join(problems, "\n"), "incomplete") ||
		!strings.Contains(strings.Join(problems, "\n"), "bad_crc") {
		t.Fatalf("checkFrames(broken) = %q, %v; want bad_crc and an incomplete chunk set", problems, err)
	}
}

func TestFramesFlag(t *testing.T) {
	frames := t.TempDir()
	copyFixtures(t, "fixtures/binary/invalid", frames)
	if err := run([]string{"-frames", frames, t.TempDir()}); err == nil {
		t.Fatal("invalid frames passed")
	}
}
