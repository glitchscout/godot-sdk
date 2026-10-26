extends GdUnitTestSuite

const SETTINGS := {
	"glitchscout/movement_space": "world",
	"glitchscout/physics/move_speed": 6.5,
	"glitchscout/physics/jump_height": 1.25,
	"glitchscout/physics/units_per_meter": 2.0,
	"glitchscout/camera_actions": ["gs_test_look"],
}


func before_test() -> void:
	InputMap.add_action("gs_test_jump")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SPACE
	InputMap.action_add_event("gs_test_jump", key)
	InputMap.add_action("gs_test_steer")
	var axis := InputEventJoypadMotion.new()
	axis.axis = JOY_AXIS_LEFT_X
	InputMap.action_add_event("gs_test_steer", axis)
	InputMap.add_action("gs_test_look")
	for k in SETTINGS:
		ProjectSettings.set_setting(k, SETTINGS[k])


func after_test() -> void:
	for a in ["gs_test_jump", "gs_test_steer", "gs_test_look"]:
		InputMap.erase_action(a)
	for k in SETTINGS:
		ProjectSettings.set_setting(k, null)


func _manifest() -> Dictionary:
	var sdk := auto_free(GlitchscoutSDK.new()) as GlitchscoutSDK
	return sdk.build_manifest()


func test_engine_and_versions() -> void:
	var m := _manifest()
	assert_str(m.engine.name).is_equal("godot")
	assert_str(m.engine.version).starts_with("4.")
	assert_str(m.sdk_version).is_equal(GlitchscoutSDK.SDK_VERSION)


func test_every_input_action_is_listed_with_its_type() -> void:
	var actions := {}
	for a in _manifest().input_actions:
		actions[a.name] = a.type
	for a in InputMap.get_actions():
		assert_bool(actions.has(String(a))).is_true()
	# Every InputMap action, plus the virtual 2D axes from glitchscout/axes.
	assert_int(actions.size()).is_equal(InputMap.get_actions().size() + GlitchscoutSDK.InputInjection.axes().size())
	assert_str(actions.get("gs_test_jump", "")).is_equal("button")
	assert_str(actions.get("gs_test_steer", "")).is_equal("axis_1d")
	assert_str(actions.get("ui_accept", "")).is_equal("button")


func test_movement_space_and_physics_hints_come_from_project_settings() -> void:
	var m := _manifest()
	assert_str(m.movement_space).is_equal("world")
	assert_float(m.physics_hints.move_speed).is_equal(6.5)
	assert_float(m.physics_hints.jump_height).is_equal(1.25)
	assert_float(m.physics_hints.units_per_meter).is_equal(2.0)
	assert_array(m.camera_actions).contains_exactly(["gs_test_look"])


func test_defaults_without_settings() -> void:
	for k in SETTINGS:
		ProjectSettings.set_setting(k, null)
	var m := _manifest()
	assert_str(m.movement_space).is_equal("camera")
	assert_float(m.physics_hints.units_per_meter).is_equal(1.0)


func test_supports_lists_every_capability() -> void:
	var supports: Dictionary = _manifest().supports
	assert_array(supports.keys()).contains_exactly_in_any_order([
		"step_mode", "reset_tiers", "navmesh", "nav_links", "ui_tree", "screenshots", "seed", "save_fixtures", "god_mode",
	])
	assert_bool(supports.reset_tiers is Array).is_true()


func test_limits_match_the_protocol_defaults() -> void:
	var limits: Dictionary = _manifest().limits
	assert_int(limits.max_text_frame_bytes).is_equal(262144)
	assert_int(limits.max_binary_frame_bytes).is_equal(4194304)
