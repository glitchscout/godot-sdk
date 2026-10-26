@tool
extends EditorPlugin
## Registers the Glitchscout autoload when the addon is enabled, and keeps the SDK out of shipping builds:
## a release export without the "qa" feature tag drops the autoload and every file of the addon.

const AUTOLOAD := "Glitchscout"

var _export_plugin: StripFromShipping


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/glitchscout/glitchscout.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)


func _enter_tree() -> void:
	_export_plugin = StripFromShipping.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)


class StripFromShipping:
	extends EditorExportPlugin
	## Godot doesn't pass scripts through _export_file, so the addon's files are left out by the preset's
	## exclude_filter ("addons/glitchscout/*"); this plugin drops the settings that name the addon (its
	## autoload and its editor_plugins entry) and complains about a shipping preset that would still ship it.

	const ADDON_DIR := "res://addons/glitchscout/"
	const SETTINGS := ["autoload/" + AUTOLOAD, "editor_plugins/enabled"]

	var _saved := {} ## setting -> value before the export

	func _get_name() -> String:
		return "Glitchscout"

	func _export_begin(features: PackedStringArray, is_debug: bool, _path: String, _flags: int) -> void:
		if not is_shipping(features, is_debug):
			return
		var leaked := Array(get_export_preset().get_files_to_export()).filter(func(f: String): return f.begins_with(ADDON_DIR))
		if not leaked.is_empty():
			push_error("Glitchscout: preset '%s' is a shipping export but would include %d SDK files; add \"addons/glitchscout/*\" to its exclude filter (Export > Resources) or the \"qa\" feature tag for a QA build" % [get_export_preset().get_preset_name(), leaked.size()])
		for setting: String in SETTINGS:
			if ProjectSettings.has_setting(setting):
				_saved[setting] = ProjectSettings.get_setting(setting)
				ProjectSettings.set_setting(setting, without_sdk(setting, _saved[setting]))

	func _export_end() -> void:
		for setting: String in _saved:
			ProjectSettings.set_setting(setting, _saved[setting])
		_saved.clear()

	## A release export without the "qa" feature tag is a shipping build.
	static func is_shipping(features: PackedStringArray, is_debug: bool) -> bool:
		return not is_debug and not "qa" in features

	## A setting's shipping value: the autoload goes; other enabled editor plugins stay.
	static func without_sdk(setting: String, value: Variant) -> Variant:
		if setting != "editor_plugins/enabled":
			return null
		var rest := Array(value).filter(func(p: String): return not p.begins_with(ADDON_DIR))
		return PackedStringArray(rest) if not rest.is_empty() else null
