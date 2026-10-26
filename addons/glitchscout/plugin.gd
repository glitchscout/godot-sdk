@tool
extends EditorPlugin
## Registers the Glitchscout autoload when the addon is enabled, and helps keep the SDK out of shipping
## builds (see StripFromShipping).

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
	## exclude filter ("addons/glitchscout/*"). When a preset leaves them out, debug export or not, this drops
	## the settings that name the addon (its autoload and its editor_plugins entry) so the game doesn't look
	## for it. A shipping export that keeps them gets an error (Godot gives export plugins no way to stop an
	## export, so tools/releasescan is the gate).

	const ExportFilter := preload("export_filter.gd")

	var _saved := {} ## setting -> value before the export

	func _get_name() -> String:
		return "Glitchscout"

	func _export_begin(features: PackedStringArray, is_debug: bool, _path: String, _flags: int) -> void:
		var preset := get_export_preset()
		if not ExportFilter.excludes_sdk(preset.get_exclude_filter()):
			if ExportFilter.is_shipping(features, is_debug):
				push_error("Glitchscout: preset '%s' is a shipping export but includes the SDK; add \"addons/glitchscout/*\" to its exclude filter (Resources), or give it the \"qa\" feature tag for a QA build" % preset.get_preset_name())
			return
		for setting: String in ExportFilter.SETTINGS:
			if ProjectSettings.has_setting(setting):
				_saved[setting] = ProjectSettings.get_setting(setting)
				ProjectSettings.set_setting(setting, ExportFilter.without_sdk(setting, _saved[setting]))

	func _export_end() -> void:
		for setting: String in _saved:
			ProjectSettings.set_setting(setting, _saved[setting])
		_saved.clear()
