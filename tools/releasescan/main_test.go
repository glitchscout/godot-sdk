package main

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
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

func TestScanZipPack(t *testing.T) {
	// A .zip export deflates its files, so the SDK has to be found in the entries, not the raw bytes.
	path := filepath.Join(t.TempDir(), "game.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	w, err := zw.Create("addons/glitchscout/glitchscout.gdc")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w.Write([]byte("class_name GlitchscoutSDK class_name GlitchscoutSDK class_name GlitchscoutSDK"))
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	hits, err := scan(path)
	if err != nil || len(hits) != 2 {
		t.Fatalf("scan(zip) = %v, %v; want the addon path and the class name", hits, err)
	}
}

func TestExpectSDKNeedsTheAutoloadToo(t *testing.T) {
	// A QA build whose SDK files shipped but whose autoload was stripped can't connect: that's a failure.
	dir := t.TempDir()
	noAutoload := filepath.Join(dir, "qa-broken.pck")
	full := filepath.Join(dir, "qa.pck")
	files := "GDPC...res://addons/glitchscout/glitchscout.gdc...GlitchscoutSDK"
	if err := os.WriteFile(noAutoload, []byte(files), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(files+"...autoload/Glitchscout...*res://addons/glitchscout/glitchscout.gd"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"-expect-sdk", noAutoload}); err == nil {
		t.Error("run(-expect-sdk) passed a QA pack without the Glitchscout autoload")
	}
	if err := run([]string{"-expect-sdk", full}); err != nil {
		t.Errorf("run(-expect-sdk) = %v on a complete QA pack", err)
	}
}

func TestExpectSDKFindsTheAutoloadInAZipExport(t *testing.T) {
	path := filepath.Join(t.TempDir(), "qa.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	for name, body := range map[string]string{
		"addons/glitchscout/glitchscout.gdc": "class_name GlitchscoutSDK class_name GlitchscoutSDK",
		".godot/project.binary":              "autoload/Glitchscout *res://addons/glitchscout/glitchscout.gd autoload/Glitchscout",
	} {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = w.Write([]byte(strings.Repeat(body+" ", 200))) // compressible, so it's really deflated
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	if raw, _ := os.ReadFile(path); bytes.Contains(raw, []byte("autoload/Glitchscout")) {
		t.Fatal("the test zip isn't compressed")
	}
	if err := run([]string{"-expect-sdk", path}); err != nil {
		t.Errorf("run(-expect-sdk) = %v on a complete QA zip", err)
	}
}
