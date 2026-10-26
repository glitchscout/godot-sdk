package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScan(t *testing.T) {
	dir := t.TempDir()
	clean := filepath.Join(dir, "clean.pck")
	dirty := filepath.Join(dir, "dirty.pck")
	game := "group glitchscout_interactable; meta glitchscout_id; get_node_or_null(\"/root/Glitchscout\")"
	if err := os.WriteFile(clean, []byte("GDPC...res://fixture/main.gd..."+game), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dirty, []byte("GDPC...res://addons/glitchscout/glitchscout.gd...class_name GlitchscoutSDK"), 0o600); err != nil {
		t.Fatal(err)
	}
	if hits, err := scan(clean); err != nil || len(hits) != 0 {
		t.Fatalf("scan(clean) = %v, %v; game-side integration names must not count", hits, err)
	}
	hits, err := scan(dirty)
	if err != nil || len(hits) != 2 {
		t.Fatalf("scan(dirty) = %v, %v; want the addon path and the class name", hits, err)
	}
}
