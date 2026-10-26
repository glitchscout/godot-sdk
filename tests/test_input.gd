extends GdUnitTestSuite
## ACTION_INJECT. Driven from a ScriptedOrchestrator thread because step mode holds the main loop.

const MOVE := ["move_left", "move_right", "move_forward", "move_back"]


## Records what the game sees of the injected input.
class InputProbe:
	extends Node

	var physics_pressed := 0 ## physics frames with jump held
	var idle_pressed := 0 ## idle frames with jump held
	var events: Array = [] ## jump InputEventActions seen by _input: true = pressed
	var move_left_events := 0
	var jump_edges := 0 ## physics frames where jump was just pressed
	var strengths := {}

	func _physics_process(_delta: float) -> void:
		if Input.is_action_pressed("jump"):
			physics_pressed += 1
		if Input.is_action_just_pressed("jump"):
			jump_edges += 1

	func _process(_delta: float) -> void:
		if Input.is_action_pressed("jump"):
			idle_pressed += 1
		for a in ["move_left", "move_right", "move_forward", "move_back", "interact"]:
			strengths[a] = snappedf(Input.get_action_strength(a), 0.001)

	func _input(event: InputEvent) -> void:
		if event is InputEventAction and event.action == "jump":
			events.append(event.pressed)
		if event is InputEventAction and event.action == "move_left":
			move_left_events += 1


var orch: ScriptedOrchestrator
var sdk: GlitchscoutSDK
var probe: InputProbe


func before_test() -> void:
	orch = ScriptedOrchestrator.new()
	orch.listen()
	probe = InputProbe.new()
	add_child(probe)
	sdk = GlitchscoutSDK.new()
	sdk.quit_on_goodbye = false
	sdk.max_hold_ms = 10000
	sdk.configure(orch.endpoint(), "tok")
	add_child(sdk)


func after_test() -> void:
	orch.stop()
	if is_instance_valid(sdk):
		sdk.free()
	probe.free()
	for a in InputMap.get_actions():
		Input.action_release(a)


func _run(steps: Array[Callable]) -> bool:
	orch.run(steps)
	var deadline := Time.get_ticks_msec() + 20000
	while not orch.done() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return orch.done()


func _inject(payload: Dictionary, key: String) -> Array[Callable]:
	return [orch.request("ACTION_INJECT", payload, key), orch.reply_to(key)]


func _step(ticks: int, key: String) -> Array[Callable]:
	return [orch.request("STEP", {"ticks": ticks}, key), orch.reply_to(key)]


func _snap(key: String) -> Callable:
	return orch.call_once(func(): orch.vars[key] = [probe.physics_pressed, probe.idle_pressed])


func _strengths(key: String) -> Callable:
	return orch.call_once(func(): orch.vars[key] = probe.strengths.duplicate())


func _press(action: String, hold_ticks := 0) -> Dictionary:
	var b := {"action": action, "op": "press"}
	if hold_ticks > 0:
		b.hold_ticks = hold_ticks
	return {"digital_buttons": [b]}


func test_hold_ticks_holds_for_exactly_n_physics_and_idle_frames() -> void:
	var steps: Array[Callable] = [orch.ack_hello(), orch.wait_ms(100), _snap("before")]
	steps.append_array(_inject(_press("jump", 3), "press"))
	steps.append_array(_step(6, "six"))
	steps.append_array([_snap("after"), orch.goodbye()])
	assert_bool(await _run(steps)).is_true()
	assert_str(orch.vars.press_reply.message_type).is_equal("ACK")
	var d := [orch.vars.after[0] - orch.vars.before[0], orch.vars.after[1] - orch.vars.before[1]]
	assert_array(d).is_equal([3, 3])
	assert_array(probe.events).is_equal([true, false])


func test_press_holds_until_release() -> void:
	var steps: Array[Callable] = [orch.ack_hello(), orch.wait_ms(100), _snap("before")]
	steps.append_array(_inject(_press("jump"), "press"))
	steps.append_array(_step(4, "a"))
	steps.append_array(_inject({"digital_buttons": [{"action": "jump", "op": "release"}]}, "release"))
	steps.append_array(_step(4, "b"))
	steps.append_array([_snap("after"), orch.goodbye()])
	assert_bool(await _run(steps)).is_true()
	assert_array([orch.vars.after[0] - orch.vars.before[0], orch.vars.after[1] - orch.vars.before[1]]).is_equal([4, 4])
	assert_array(probe.events).is_equal([true, false])


func test_analog_values_on_single_actions_and_virtual_axes() -> void:
	var steps: Array[Callable] = [orch.ack_hello(), orch.wait_ms(100)]
	steps.append_array(_inject({"analog_axes": [{"action": "move", "x": 0.8, "y": -0.5}, {"action": "interact", "x": 0.4}]}, "a"))
	steps.append_array(_step(1, "s1"))
	steps.append(_strengths("first"))
	steps.append_array(_inject({"analog_axes": [{"action": "move", "x": -0.3, "y": 0.0}, {"action": "interact", "x": 0.0}]}, "b"))
	steps.append_array(_step(1, "s2"))
	steps.append_array([_strengths("second"), orch.goodbye()])
	assert_bool(await _run(steps)).is_true()
	assert_dict(orch.vars.first).is_equal({"move_left": 0.0, "move_right": 0.8, "move_forward": 0.5, "move_back": 0.0, "interact": 0.4})
	assert_dict(orch.vars.second).is_equal({"move_left": 0.3, "move_right": 0.0, "move_forward": 0.0, "move_back": 0.0, "interact": 0.0})


func test_an_unknown_action_is_refused_and_nothing_applies() -> void:
	var steps: Array[Callable] = [orch.ack_hello(), orch.wait_ms(100), _snap("before")]
	steps.append_array(_inject({"digital_buttons": [{"action": "jump", "op": "press"}, {"action": "fly", "op": "press"}]}, "bad"))
	steps.append_array(_step(3, "s"))
	steps.append_array([_snap("after"), orch.goodbye()])
	assert_bool(await _run(steps)).is_true()
	assert_str(orch.vars.bad_reply.message_type).is_equal("ERROR")
	assert_str(orch.vars.bad_reply.payload.code).is_equal("unknown_action")
	assert_array(orch.vars.after).is_equal(orch.vars.before)


func test_everything_is_released_when_the_session_ends() -> void:
	var steps: Array[Callable] = [orch.ack_hello(), orch.wait_ms(100)]
	steps.append_array(_inject(_press("jump"), "press"))
	steps.append_array(_inject({"analog_axes": [{"action": "move", "x": 1.0}]}, "move"))
	steps.append_array(_step(2, "s"))
	steps.append(orch.goodbye())
	assert_bool(await _run(steps)).is_true()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_bool(Input.is_action_pressed("jump")).is_false()
	assert_float(Input.get_action_strength("move_right")).is_equal(0.0)


func test_manifest_lists_every_action_and_the_virtual_axes() -> void:
	var types := {}
	for a in sdk.build_manifest().input_actions:
		types[a.name] = a.type
	for a in InputMap.get_actions():
		assert_bool(types.has(String(a))).is_true()
	assert_str(types.get("move", "")).is_equal("axis_2d")
	assert_str(types.get("move_left", "")).is_equal("axis_1d") # bound to a joypad axis
	assert_str(types.get("jump", "")).is_equal("button")


func test_fixture_player_walks_with_analog_input_and_jumps_on_a_held_button() -> void:
	var level: Node = load("res://fixture/levels/flat.tscn").instantiate()
	add_child(level)
	var player: CharacterBody3D = level.get_node("Player")
	var pos := func(key): return orch.call_once(func(): orch.vars[key] = player.last_position)
	var steps: Array[Callable] = [orch.ack_hello(), orch.wait_ms(100)]
	steps.append_array(_step(10, "settle"))
	steps.append(pos.call("start"))
	steps.append_array(_inject({"analog_axes": [{"action": "move", "x": 1.0, "y": 0.0}]}, "go"))
	steps.append_array(_step(60, "walk"))
	steps.append(pos.call("walked"))
	steps.append_array(_inject({"analog_axes": [{"action": "move", "x": 0.5, "y": 0.0}]}, "slow"))
	steps.append_array(_step(60, "walk_slow"))
	steps.append(pos.call("walked_slow"))
	steps.append_array(_inject({"analog_axes": [{"action": "move", "x": 0.0, "y": 0.0}]}, "stop"))
	steps.append_array(_inject(_press("jump", 2), "jump"))
	steps.append_array(_step(40, "air"))
	steps.append(orch.call_once(func(): orch.vars.jump = [player.jumps, player.max_height]))
	steps.append(orch.goodbye())
	assert_bool(await _run(steps)).is_true()
	level.free()
	var full: float = orch.vars.walked.x - orch.vars.start.x
	var half: float = orch.vars.walked_slow.x - orch.vars.walked.x
	assert_float(full).is_between(4.8, 5.2) # 1 s at speed 5
	assert_bool(half > 0.5 and half < full).is_true() # analog: slower, but moving
	assert_int(orch.vars.jump[0]).is_equal(1)
	assert_bool(orch.vars.jump[1] > 2.0).is_true() # left the floor (centre starts at 1.0)


func test_analog_input_never_releases_actions_it_did_not_press() -> void:
	var steps: Array[Callable] = [orch.ack_hello(), orch.wait_ms(100)]
	steps.append_array(_inject({"analog_axes": [{"action": "move", "x": 1.0, "y": 0.0}]}, "a"))
	steps.append_array(_step(2, "s"))
	steps.append_array(_inject({"analog_axes": [{"action": "move", "x": 0.5, "y": 0.0}]}, "b"))
	steps.append_array(_step(2, "s2"))
	steps.append(orch.goodbye())
	assert_bool(await _run(steps)).is_true()
	assert_int(probe.move_left_events).is_equal(0)


func test_pressing_a_held_action_again_extends_it_without_a_new_press() -> void:
	var steps: Array[Callable] = [orch.ack_hello(), orch.wait_ms(100), _snap("before")]
	steps.append_array(_inject(_press("jump"), "first"))
	steps.append_array(_step(2, "a"))
	steps.append_array(_inject(_press("jump", 2), "again"))
	steps.append_array(_step(4, "b"))
	steps.append_array([_snap("after"), orch.goodbye()])
	assert_bool(await _run(steps)).is_true()
	assert_int(probe.jump_edges).is_equal(1)
	assert_array([orch.vars.after[0] - orch.vars.before[0], orch.vars.after[1] - orch.vars.before[1]]).is_equal([4, 4])
