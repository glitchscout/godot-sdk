extends GdUnitTestSuite
## Step mode. The SDK holds the main loop between steps, so these tests drive it from a
## ScriptedOrchestrator thread and read a probe node's frame counts while the game is held.


## A pausable game node that counts its frames.
class Probe:
	extends Node

	var idle := 0
	var physics := 0

	func _process(_delta: float) -> void:
		idle += 1

	func _physics_process(_delta: float) -> void:
		physics += 1


var orch: ScriptedOrchestrator
var sdk: GlitchscoutSDK
var probe: Probe


func before_test() -> void:
	orch = ScriptedOrchestrator.new()
	orch.listen()
	probe = Probe.new()
	add_child(probe)


func after_test() -> void:
	orch.stop()
	if is_instance_valid(sdk):
		sdk.free()
	probe.free()
	get_tree().paused = false


func _start(method := "hold", time_mode := "step") -> void:
	sdk = GlitchscoutSDK.new()
	sdk.quit_on_goodbye = false
	sdk.max_hold_ms = 10000 # a bug must not hang the test run
	sdk.time_mode = time_mode
	sdk.step_method = method
	sdk.configure(orch.endpoint(), "tok")
	add_child(sdk)


## Runs the script and waits for it; the main loop only moves while the SDK lets it.
func _run(steps: Array[Callable]) -> bool:
	orch.run(steps)
	var deadline := Time.get_ticks_msec() + 20000
	while not orch.done() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return orch.done()


## Records [physics, idle] frame counts of the probe as vars[key].
func _snap(key: String) -> Callable:
	return orch.call_once(func(): orch.vars[key] = [probe.physics, probe.idle])


func _delta(a: Array, b: Array) -> Array:
	return [b[0] - a[0], b[1] - a[1]]


func _exact_steps(method: String) -> void:
	_start(method)
	var ok: bool = await _run([
		orch.ack_hello(), orch.wait_ms(150), _snap("s0"),
		orch.request("STEP", {"ticks": 5}, "five"), orch.reply_to("five"), _snap("s5"),
		orch.request("STEP", {"ticks": 3}, "three"), orch.reply_to("three"), _snap("s3"),
		orch.wait_ms(150), _snap("after"),
		orch.goodbye(),
	])
	assert_bool(ok).is_true()
	assert_array(_delta(orch.vars.s0, orch.vars.s5)).is_equal([5, 5])
	assert_array(_delta(orch.vars.s5, orch.vars.s3)).is_equal([3, 3])
	assert_array(orch.vars.after).is_equal(orch.vars.s3) # held again after the step
	var five: Dictionary = orch.vars.five_reply
	var three: Dictionary = orch.vars.three_reply
	assert_str(five.message_type).is_equal("ACK")
	assert_int(int(five.payload.result.frames)).is_equal(5)
	assert_int(int(three.payload.result.tick_frame - five.payload.result.tick_frame)).is_equal(3)
	assert_int(int(three.tick_frame)).is_equal(int(three.payload.result.tick_frame))


func test_holds_from_the_handshake_until_the_first_step() -> void:
	_start()
	var ok: bool = await _run([orch.ack_hello(), orch.wait_ms(150), _snap("a"), orch.wait_ms(300), _snap("b"), orch.goodbye()])
	assert_bool(ok).is_true()
	assert_array(orch.vars.b).is_equal(orch.vars.a)


func test_hold_mode_steps_exactly_n_physics_and_idle_frames() -> void:
	await _exact_steps("hold")


func test_pause_mode_steps_exactly_n_physics_and_idle_frames() -> void:
	await _exact_steps("pause")


func test_pause_mode_pauses_the_tree_between_steps() -> void:
	_start("pause")
	var ok: bool = await _run([
		orch.ack_hello(), orch.wait_ms(150),
		orch.call_once(func(): orch.vars.paused = get_tree().paused),
		orch.goodbye(),
	])
	assert_bool(ok).is_true()
	assert_bool(orch.vars.paused).is_true()
	assert_bool(get_tree().paused).is_false() # released after GOODBYE


func test_heartbeats_continue_while_held() -> void:
	_start()
	var ok: bool = await _run([
		orch.ack_hello(), orch.wait_ms(2500),
		orch.call_once(func(): orch.vars.heartbeats = orch.messages("HEARTBEAT").size()),
		orch.goodbye(),
	])
	assert_bool(ok).is_true()
	assert_int(orch.vars.heartbeats).is_greater_equal(2)


func test_a_step_while_one_runs_is_refused() -> void:
	_start()
	var ok: bool = await _run([
		orch.ack_hello(), orch.wait_ms(100),
		# Both in one step: a poll between them (parsing whatever the SDK sent meanwhile) could outlast the
		# 60 frames, and then "extra" would arrive after "long" had finished.
		orch.call_once(func():
			orch.vars.long = orch.send("STEP", {"ticks": 60})
			orch.vars.extra = orch.send("STEP", {"ticks": 2})),
		orch.reply_to("extra"), orch.reply_to("long"),
		orch.goodbye(),
	])
	assert_bool(ok).is_true()
	assert_str(orch.vars.extra_reply.message_type).is_equal("ERROR")
	assert_str(orch.vars.extra_reply.payload.code).is_equal("step_in_progress")
	assert_str(orch.vars.long_reply.message_type).is_equal("ACK")
	assert_int(int(orch.vars.long_reply.payload.result.frames)).is_equal(60)


func test_realtime_mode_never_holds() -> void:
	_start("hold", "realtime")
	var ok: bool = await _run([
		orch.ack_hello(), orch.wait_ms(150), _snap("a"), orch.wait_ms(300), _snap("b"),
		orch.request("STEP", {"ticks": 4}, "four"), orch.reply_to("four"),
		orch.goodbye(),
	])
	assert_bool(ok).is_true()
	assert_bool(orch.vars.b[1] > orch.vars.a[1]).is_true()
	assert_str(orch.vars.four_reply.message_type).is_equal("ACK") # STEP still waits N frames and answers


func test_time_mode_and_method_come_from_user_args() -> void:
	var s := auto_free(GlitchscoutSDK.new()) as GlitchscoutSDK
	s.configure_from_args(PackedStringArray([
		"--glitchscout-endpoint=ws://127.0.0.1:9/", "--glitchscout-time=realtime", "--glitchscout-step-method=pause",
	]))
	assert_str(s.time_mode).is_equal("realtime")
	assert_str(s.step_method).is_equal("pause")


func test_manifest_advertises_step_mode() -> void:
	var s := auto_free(GlitchscoutSDK.new()) as GlitchscoutSDK
	assert_bool(s.build_manifest().supports.step_mode).is_true()


func test_ticks_count_stepped_frames_while_the_game_pauses_itself() -> void:
	get_tree().paused = true # e.g. the game's pause menu is open
	_start()
	var ok: bool = await _run([
		orch.ack_hello(), orch.wait_ms(100),
		orch.request("STEP", {"ticks": 1}, "one"), orch.reply_to("one"),
		orch.request("STEP", {"ticks": 5}, "five"), orch.reply_to("five"),
		orch.goodbye(),
	])
	assert_bool(ok).is_true()
	var t1 := int(orch.vars.one_reply.payload.result.tick_frame)
	var t5 := int(orch.vars.five_reply.payload.result.tick_frame)
	assert_int(t5 - t1).is_equal(5)


func test_pause_mode_keeps_the_games_own_pause() -> void:
	get_tree().paused = true # the game paused itself before the session
	_start("pause")
	var ok: bool = await _run([
		orch.ack_hello(), orch.wait_ms(100), _snap("s0"),
		orch.request("STEP", {"ticks": 3}, "three"), orch.reply_to("three"), _snap("s3"),
		orch.goodbye(),
	])
	assert_bool(ok).is_true()
	assert_array(_delta(orch.vars.s0, orch.vars.s3)).is_equal([0, 0]) # the game stayed paused
	assert_int(int(orch.vars.three_reply.payload.result.frames)).is_equal(3)
	await get_tree().process_frame
	assert_bool(get_tree().paused).is_true() # released to the game's own state, not forced on
