@tool
extends EditorPlugin
## Registers the Glitchscout autoload when the addon is enabled.

const AUTOLOAD := "Glitchscout"


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/glitchscout/glitchscout.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)
