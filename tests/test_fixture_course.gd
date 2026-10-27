extends SdkTestCase
## The fixture game's course level and its fault commands, driven through the SDK (realtime mode).

const FAULTS := ["crash_now", "hang", "log_error", "leak_memory", "drop_connection", "send_malformed", "slow_frames", "softlock_door"]

var game: Node
var _autoload: Node


func after_test() -> void:
	super.after_test()
	if is_instance_valid(game):
		game.free()
	if _autoload:
		get_tree().root.add_child(_autoload)
		_autoload = null


## The fixture talks to the SDK at /root/Glitchscout, so the test's SDK stands in for the autoload there.
func _start() -> void:
	_autoload = get_tree().root.get_node_or_null("Glitchscout")
	if _autoload:
		get_tree().root.remove_child(_autoload)
	sdk = GlitchscoutSDK.new()
	sdk.name = "Glitchscout"
	sdk.quit_on_goodbye = false
	sdk.reconnect_interval_ms = 50
	sdk.time_mode = "realtime"
	sdk.configure(orch.endpoint(), "tok")
	get_tree().root.add_child(sdk)
	game = load("res://fixture/main.tscn").instantiate()
	add_child(game)
	await handshake()


func _cmd(name: String, args := {}) -> Dictionary:
	return await request("COMMAND", {"name": name, "args": args})


func _course() -> void:
	await _start()
	var m := await _cmd("load_scene", {"scene": "course"})
	assert_str(m.message_type).is_equal("ACK")
	for i in 3:
		await get_tree().physics_frame


func _press_at(pos: Vector3) -> void:
	await _cmd("teleport", {"position": {"x": pos.x, "y": pos.y, "z": pos.z}})
	await get_tree().physics_frame
	await request("ACTION_INJECT", {"digital_buttons": [{"action": "interact", "op": "press", "hold_ticks": 1}]})
	for i in 4:
		await get_tree().physics_frame


func _game_events(name: String) -> Array:
	await pump_until(func(): return false, 100) # collect what the SDK has sent
	return orch.messages("EVENT").filter(func(m): return m.payload.get("name") == name)


func _interactable(id: String) -> Dictionary:
	var obs := await request("OBSERVE", {"sections": ["interactables"]})
	for i in obs.payload.get("interactables", []):
		if i.id == id:
			return i
	return {}


func test_load_scene_takes_level_names_and_the_player_reports_its_level() -> void:
	await _course()
	assert_str(game.level_name()).is_equal("course")
	var obs := await request("OBSERVE", {"sections": ["player"]})
	assert_str(obs.payload.player.scene).is_equal("res://fixture/levels/course.tscn")
	assert_str((await _cmd("load_scene", {"scene": "nowhere"})).payload.code).is_equal("invalid_args")
	assert_str((await _cmd("load_scene", {"scene": "flat"})).message_type).is_equal("ACK")
	assert_str(game.level_name()).is_equal("flat")


func test_talking_to_the_elder_starts_the_dialogue() -> void:
	await _course()
	await _press_at(Vector3(2, 1, 0))
	var started := await _game_events("dialogue_started")
	assert_int(started.size()).is_equal(1)
	assert_str(started[0].payload.data.npc_id).is_equal("elder")
	assert_str((await _interactable("elder")).get("state", "")).is_equal("talking")


func test_the_keycard_door_needs_the_card() -> void:
	await _course()
	await _press_at(Vector3(0, 1, -4.5))
	assert_int((await _game_events("interaction_failed")).size()).is_equal(1)
	assert_str((await _interactable("door_red")).get("state", "")).is_equal("locked")
	await _press_at(Vector3(-2, 1, 0))
	assert_int((await _game_events("item_collected")).size()).is_equal(1)
	assert_bool(game.inventory.has("keycard_red")).is_true()
	await _press_at(Vector3(0, 1, -4.5))
	assert_int((await _game_events("door_opened")).size()).is_equal(1)
	assert_str((await _interactable("door_red")).get("state", "")).is_equal("open")


func test_the_broken_lever_does_nothing_but_raise_an_error() -> void:
	await _course()
	var lever: Node = game.find_child("BrokenLever", true, false)
	lever.raise_errors = false # a real script error would fail this test; the orchestrator's tests see it
	await _press_at(Vector3(5, 1, 0))
	assert_int(lever.errors).is_equal(1)
	assert_str((await _interactable("lever_bridge")).get("state", "")).is_equal("off")


func test_softlock_door_jams_the_next_door_opened() -> void:
	await _course()
	await _cmd("softlock_door")
	game.inventory["keycard_red"] = 1
	await _press_at(Vector3(0, 1, -4.5))
	assert_str((await _interactable("door_red")).get("state", "")).is_equal("jammed")
	assert_int((await _game_events("door_opened")).size()).is_equal(0)


func test_the_course_reports_threats_and_moving_parts() -> void:
	await _course()
	var obs := await request("OBSERVE", {})
	assert_array(obs.payload.get("threats", []).map(func(t): return t.id)).contains(["patroller"])
	var p1: Vector3 = game.find_child("MovingPlatform", true, false).global_position
	for i in 20:
		await get_tree().physics_frame
	assert_bool(game.find_child("MovingPlatform", true, false).global_position.is_equal_approx(p1)).is_false()


func test_fault_commands_are_registered() -> void:
	await _start()
	var names: Array = orch.messages("HELLO")[0].payload.manifest.commands.map(func(c): return c.name)
	assert_array(names).contains(FAULTS)


func test_slow_frames_and_leak_memory_arm_and_disarm() -> void:
	await _start()
	await _cmd("slow_frames", {"ms": 40})
	var t := Time.get_ticks_msec()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_int(Time.get_ticks_msec() - t).is_greater_equal(40)
	await _cmd("slow_frames", {"ms": 0})
	await _cmd("leak_memory", {"mb_per_second": 60})
	var before: int = game.leaked_bytes
	for i in 10:
		await get_tree().physics_frame
	assert_int(game.leaked_bytes).is_greater(before)
	await _cmd("leak_memory", {"mb_per_second": 0})
	assert_int(game.leaked_bytes).is_equal(0) # released


func test_connection_faults_use_the_sdks_socket() -> void:
	await _start()
	var peer := FakePeer.new()
	game.socket_override = peer
	await _cmd("send_malformed")
	await _cmd("drop_connection")
	assert_array(peer.sent).has_size(1)
	assert_bool(JSON.parse_string(peer.sent[0]) == null or not (JSON.parse_string(peer.sent[0]) is Dictionary and JSON.parse_string(peer.sent[0]).has("id"))).is_true()
	assert_bool(peer.closed).is_true()


func test_crash_and_hang_arm_for_later_frames() -> void:
	await _start()
	await _cmd("crash_now", {"after_frames": 100000})
	await _cmd("hang", {"after_frames": 100000})
	assert_int(game.crash_in).is_greater(0)
	assert_int(game.hang_in).is_greater(0)
	game.crash_in = -1 # disarm before the test ends
	game.hang_in = -1


class FakePeer:
	extends RefCounted

	var sent: Array = []
	var closed := false

	func send_text(t: String) -> int:
		sent.append(t)
		return OK

	func close(_code := 1000, _reason := "") -> void:
		closed = true
