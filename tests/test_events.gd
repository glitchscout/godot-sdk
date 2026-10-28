extends SdkTestCase
## EVENT (game events, scene changes, forwarded logs and errors), STATE_CTRL tier-1 reset, and when the SDK
## switches itself on.


func _events(kind := "") -> Array:
	return orch.messages("EVENT").filter(func(m): return kind.is_empty() or m.payload.kind == kind)


func _ready_sdk() -> void:
	start_sdk()
	await handshake()


func test_game_events_reach_the_orchestrator_with_json_safe_data() -> void:
	await _ready_sdk()
	sdk.event("dialogue_started", {"npc_id": "elder", "where": Vector3(1, 2, 3)})
	assert_bool(await pump_until(func(): return not _events("game").is_empty())).is_true()
	var e: Dictionary = _events("game")[0].payload
	assert_str(e.name).is_equal("dialogue_started")
	assert_str(e.data.npc_id).is_equal("elder")
	assert_float(e.data.where.z).is_equal(3.0)


func test_events_before_the_session_opens_are_kept_in_order() -> void:
	start_sdk()
	sdk.event("boot_a")
	sdk.event("boot_b")
	await handshake()
	sdk.event("after")
	assert_bool(await pump_until(func(): return _events("game").size() >= 3)).is_true()
	assert_array(_events("game").map(func(m): return m.payload.name)).contains_exactly(["boot_a", "boot_b", "after"])


func test_scene_changes_are_reported() -> void:
	await _ready_sdk()
	get_tree().scene_changed.emit()
	assert_bool(await pump_until(func(): return _events("game").any(func(m): return m.payload.name == "scene_changed"))).is_true()


func test_errors_warnings_and_prints_are_forwarded() -> void:
	await _ready_sdk()
	push_error("gs-test: something broke")
	push_warning("gs-test: something odd")
	print("gs-test: a plain line")
	assert_bool(await pump_until(func(): return _events("log").filter(func(m): return m.payload.message.contains("gs-test")).size() >= 3)).is_true()
	var levels := {}
	for m in _events("log"):
		if m.payload.message.contains("gs-test"):
			levels[m.payload.message.get_slice(": ", 1)] = m.payload.level
	assert_str(levels.get("something broke", "")).is_equal("error")
	assert_str(levels.get("something odd", "")).is_equal("warning")
	assert_str(levels.get("a plain line", "")).is_equal("info")


func test_script_errors_arrive_as_script_error_events() -> void:
	await _ready_sdk()
	# What Godot reports for a GDScript runtime error (a real one would fail this test run).
	var no_backtraces: Array[ScriptBacktrace] = []
	sdk.log_bridge()._log_error("_on_pickup", "res://player.gd", 42, "Invalid call. Nonexistent function 'boom'.", "", false, Logger.ERROR_TYPE_SCRIPT, no_backtraces)
	assert_bool(await pump_until(func(): return not _events("script_error").is_empty())).is_true()
	var e: Dictionary = _events("script_error")[0].payload
	assert_str(e.level).is_equal("error")
	assert_str(e.message).contains("Nonexistent function 'boom'")
	assert_str(e.data.file).is_equal("res://player.gd")
	assert_int(int(e.data.line)).is_equal(42)
	assert_str(e.data.function).is_equal("_on_pickup")


func test_a_log_flood_is_capped_and_the_overflow_reported() -> void:
	await _ready_sdk()
	for i in 3000:
		sdk.log_bridge()._log_message("gs-flood %d\n" % i, false)
	await pump_until(func(): return false, 500)
	var flood := _events("log").filter(func(m): return m.payload.message.begins_with("gs-flood"))
	assert_int(flood.size()).is_less(3000)
	assert_bool(_events("log").any(func(m): return m.payload.message.contains("log lines dropped"))).is_true()


func test_log_tail_fallback_reads_new_lines() -> void:
	var path := ProjectSettings.globalize_path("res://reports/tail-test.log")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("old line before the session\n")
	f.close()
	var tail := GlitchscoutSDK.LogTail.new(path)
	assert_array(tail.read_new()).is_empty() # starts at the end of the file
	f = FileAccess.open(path, FileAccess.READ_WRITE)
	f.seek_end()
	f.store_string("SCRIPT ERROR: Invalid get index 'x'.\nWARNING: deprecated thing\nhello\n")
	f.close()
	var lines := tail.read_new()
	assert_array(lines.map(func(l): return l.level)).contains_exactly(["error", "warning", "info"])
	assert_str(lines[0].kind).is_equal("script_error")


func test_reload_scene_uses_the_games_reset_handler_and_acks() -> void:
	var resets := [0]
	await _ready_sdk()
	sdk.set_reset_handler(func(): resets[0] += 1)
	var m := await request("STATE_CTRL", {"op": "RELOAD_SCENE"})
	assert_str(m.message_type).is_equal("ACK")
	assert_int(resets[0]).is_equal(1)
	var save := await request("STATE_CTRL", {"op": "SAVE", "slot": "a"})
	assert_str(save.payload.code).is_equal("unsupported_tier")


func test_fixture_reset_starts_the_level_afresh() -> void:
	var game: Node = load("res://fixture/main.tscn").instantiate()
	add_child(game)
	await _ready_sdk()
	sdk.set_reset_handler(game.reset)
	await request("COMMAND", {"name": "load_save", "args": {"slot": "intro"}})
	var before: Node = game.player()
	assert_float(before.global_position.x).is_equal_approx(3.0, 0.001)
	await request("STATE_CTRL", {"op": "RELOAD_SCENE"})
	assert_bool(game.flags.is_empty()).is_true()
	assert_bool(is_instance_valid(before) and not before.is_queued_for_deletion()).is_false()
	assert_float(game.player().global_position.x).is_equal_approx(0.0, 0.001)
	game.free()


func test_manifest_lists_events_and_reset_tiers() -> void:
	var declared: Variant = ProjectSettings.get_setting("glitchscout/events", null) # the project's own, put back after
	ProjectSettings.set_setting("glitchscout/events", ["dialogue_started", "player_died"])
	start_sdk()
	var hello := await wait_message("HELLO")
	ProjectSettings.set_setting("glitchscout/events", declared)
	var m: Dictionary = hello.payload.manifest
	assert_array(m.events).contains(["dialogue_started", "player_died", "scene_changed"])
	assert_array(m.supports.reset_tiers.map(func(t): return int(t))).contains_exactly([1]) # JSON numbers parse as floats


func test_the_sdk_switches_on_only_for_an_endpoint_in_a_debug_or_qa_build() -> void:
	assert_bool(GlitchscoutSDK.should_enable("ws://127.0.0.1:1/", true, false)).is_true()
	assert_bool(GlitchscoutSDK.should_enable("ws://127.0.0.1:1/", false, true)).is_true()
	assert_bool(GlitchscoutSDK.should_enable("ws://127.0.0.1:1/", false, false)).is_false() # a shipping build
	assert_bool(GlitchscoutSDK.should_enable("", true, true)).is_false()


func test_reload_scene_without_a_handler_has_the_fresh_scene_in_place_before_the_ack() -> void:
	await _ready_sdk()
	var tree := get_tree()
	var runner := tree.current_scene
	var level: Node = load("res://fixture/levels/flat.tscn").instantiate()
	tree.root.add_child(level)
	tree.current_scene = level
	level.set_meta("stale", true)
	sdk._on_state_ctrl({"id": "r-1", "message_type": "STATE_CTRL", "payload": {"op": "RELOAD_SCENE"}})
	var now := tree.current_scene # read before any frame passes: what an OBSERVE right after the ACK sees
	tree.current_scene = runner
	assert_bool(now != level and is_instance_valid(now) and not now.has_meta("stale")).is_true()
	assert_str(now.scene_file_path).is_equal("res://fixture/levels/flat.tscn")
	assert_bool(level.is_inside_tree()).is_false()
	if is_instance_valid(now) and now != level:
		now.queue_free()
	if is_instance_valid(level):
		level.queue_free()


func test_huge_log_lines_and_event_data_are_cut_to_fit_a_frame() -> void:
	await _ready_sdk()
	sdk.log_bridge()._log_message("gs-huge " + "x".repeat(600000) + "\n", false)
	sdk.event("gs_big", {"blob": "y".repeat(600000)})
	var huge := func(): return _events("log").filter(func(m): return m.payload.message.begins_with("gs-huge"))
	assert_bool(await pump_until(func(): return not huge.call().is_empty() and not _events("game").is_empty())).is_true()
	assert_int(huge.call()[0].payload.message.length()).is_less_equal(8300)
	var big: Dictionary = _events("game")[0].payload
	assert_bool(big.data.get("truncated", false)).is_true()
	assert_int(JSON.stringify(big).length()).is_less(GlitchscoutSDK.MAX_TEXT_FRAME_BYTES)


func test_log_tail_fallback_keeps_lines_over_the_per_frame_cap() -> void:
	await _ready_sdk()
	var path := ProjectSettings.globalize_path("res://reports/tail-flood.log")
	FileAccess.open(path, FileAccess.WRITE).close()
	OS.remove_logger(sdk.log_bridge())
	sdk._events._bridge = null
	sdk._events._tail = GlitchscoutSDK.LogTail.new(path)
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	f.seek_end()
	for i in 300:
		f.store_string("gs-tail %d\n" % i)
	f.close()
	var tail_lines := func(): return _events("log").filter(func(m): return m.payload.message.begins_with("gs-tail"))
	assert_bool(await pump_until(func(): return tail_lines.call().size() >= 300)).is_true()
