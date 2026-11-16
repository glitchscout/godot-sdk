package godotsdk

import (
	"io/fs"
	"slices"
	"strings"
	"testing"
)

func files(t *testing.T, fsys fs.FS) []string {
	t.Helper()
	var names []string
	err := fs.WalkDir(fsys, ".", func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			names = append(names, path)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return names
}

func TestAddonIsTheAddonFolder(t *testing.T) {
	names := files(t, Addon())
	for _, want := range []string{"plugin.cfg", "plugin.gd", "glitchscout.gd", "glitchscout.gd.uid"} {
		if !slices.Contains(names, want) {
			t.Errorf("the addon has no %s: %v", want, names)
		}
	}
	for _, name := range names {
		if strings.Contains(name, "/") || strings.HasSuffix(name, ".import") {
			t.Errorf("%s isn't one of the addon's own files", name)
		}
	}
}

// The starter is carried as the repository tracks it: its dotfiles too, and nothing a local run leaves behind.
func TestStarterIsTheSampleAsTracked(t *testing.T) {
	names := files(t, Starter())
	for _, want := range []string{"project.godot", "vault.tscn", "qa/features/first_test.feature", ".gitignore", "README.md"} {
		if !slices.Contains(names, want) {
			t.Errorf("the starter has no %s: %v", want, names)
		}
	}
	for _, name := range names {
		for _, local := range []string{"addons/", ".godot/", ".glitchscout/"} {
			if strings.HasPrefix(name, local) {
				t.Errorf("%s is from a local run of samples/starter, not the sample: remove it", name)
			}
		}
	}
}

// A tool that writes the starter out and the addon into it gets a project that needs no step in the editor.
func TestStarterTurnsTheAddonOn(t *testing.T) {
	b, err := fs.ReadFile(Starter(), "project.godot")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`Glitchscout="*res://addons/glitchscout/glitchscout.gd"`,
		`enabled=PackedStringArray("res://addons/glitchscout/plugin.cfg")`,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("the starter's project.godot has no %s", want)
		}
	}
	ignore, err := fs.ReadFile(Starter(), ".gitignore")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(ignore), "addons/") {
		t.Errorf("the starter's .gitignore leaves the addon out of the game's repository:\n%s", ignore)
	}
}
