package main

import (
	"os"
	"path/filepath"
	"testing"
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
