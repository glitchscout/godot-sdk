extends RefCounted
## The shipping-exclusion rules plugin.gd's export plugin applies, kept outside the editor-only plugin so
## they can be tested.

const ADDON_DIR := "res://addons/glitchscout/"
const SETTINGS := ["autoload/Glitchscout", "editor_plugins/enabled"]


## A release export without the "qa" feature tag is a shipping build.
static func is_shipping(features: PackedStringArray, is_debug: bool) -> bool:
	return not is_debug and not "qa" in features


## Whether a preset's exclude filter (comma-separated globs, with or without res://) leaves the addon out.
static func excludes_sdk(exclude_filter: String) -> bool:
	var probe := ADDON_DIR + "glitchscout.gd"
	for f in exclude_filter.split(",", false):
		var glob := f.strip_edges()
		if not glob.is_empty() and (probe.matchn(glob) or probe.trim_prefix("res://").matchn(glob)):
			return true
	return false


## A setting's value in an export without the SDK: the autoload goes; other enabled editor plugins stay.
static func without_sdk(setting: String, value: Variant) -> Variant:
	if setting != "editor_plugins/enabled":
		return null
	var rest := Array(value).filter(func(p: String): return not p.begins_with(ADDON_DIR))
	return PackedStringArray(rest) if not rest.is_empty() else null
