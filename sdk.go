// Package godotsdk carries the Glitchscout addon and the starter sample for tools that install them, such as
// gscout init. Games don't use it: they get addons/glitchscout/ itself.
package godotsdk

import (
	"embed"
	"io/fs"
)

//go:embed all:addons/glitchscout
var addon embed.FS

//go:embed all:samples/starter
var starter embed.FS

// Addon is addons/glitchscout/, the folder a game installs at res://addons/glitchscout/.
func Addon() fs.FS { return sub(addon, "addons/glitchscout") }

// Starter is samples/starter/, the getting-started guide's sample game. It is a Godot project without the addon:
// write Addon into its addons/glitchscout/ to run it.
func Starter() fs.FS { return sub(starter, "samples/starter") }

func sub(fsys fs.FS, dir string) fs.FS {
	s, err := fs.Sub(fsys, dir)
	if err != nil {
		panic(err) // dir is one of the constants above
	}
	return s
}
