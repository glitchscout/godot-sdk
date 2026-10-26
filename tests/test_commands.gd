extends SdkTestCase
## COMMAND: the allowlisted registry, the SDK's built-ins and the fixture's standard set.

var game: Node


func after_test() -> void:
	super.after_test()
	if is_instance_valid(game):
		game.free()
	GlitchscoutSDK.unregister_command("echo")
	GlitchscoutSDK.unregister_command("fails")
	Engine.time_scale = 1.0


func _start_game() -> void:
	game = load("res://fixture/main.tscn").instantiate()
	add_child(game)


func _ready_sdk() -> void:
	start_sdk()
	await handshake()


func _cmd(name: String, args := {}) -> Dictionary:
	return await request("COMMAND", {"name": name, "args": args})


func test_unknown_commands_are_rejected() -> void:
	await _ready_sdk()
	var m := await _cmd("drop_database")
	assert_str(m.message_type).is_equal("ERROR")
	assert_str(m.payload.code).is_equal("unknown_command")


func test_registered_commands_get_their_args_and_return_values_or_errors() -> void:
	GlitchscoutSDK.register_command("echo", func(args: Dictionary): return {"said": args.get("text", "")}, "Echoes text")
	GlitchscoutSDK.register_command("fails", func(_args: Dictionary): return "the moon is in the wrong phase")
	await _ready_sdk()
	var ok := await _cmd("echo", {"text": "hi"})
	assert_str(ok.message_type).is_equal("ACK")
	assert_str(ok.payload.result.value.said).is_equal("hi")
	var bad := await _cmd("fails")
	assert_str(bad.payload.code).is_equal("invalid_args")
	assert_str(bad.payload.message).contains("wrong phase")


func test_builtin_teleport_set_seed_time_scale_and_load_scene() -> void:
	_start_game()
	await _ready_sdk()
	await _cmd("load_save", {"slot": "intro"}) # starts the level
	var p: CharacterBody3D = game.player()
	p.velocity = Vector3(3, 0, 0)
	var t := await _cmd("teleport", {"position": {"x": 7, "y": 1, "z": 2}})
	assert_str(t.message_type).is_equal("ACK")
	assert_float(p.global_position.x).is_equal_approx(7.0, 0.001)
	assert_float(p.velocity.length()).is_equal(0.0)
	assert_str((await _cmd("teleport", {})).payload.code).is_equal("invalid_args")
	await _cmd("set_seed", {"seed": 42})
	var a := randi()
	seed(42)
	assert_int(a).is_equal(randi())
	await _cmd("time_scale", {"scale": 0.5})
	assert_float(Engine.time_scale).is_equal(0.5)
	assert_str((await _cmd("load_scene", {"scene": "res://no/such/scene.tscn"})).payload.code).is_equal("invalid_args")


func test_the_standard_set_works_on_the_fixture() -> void:
	_start_game()
	await _ready_sdk()
	assert_str((await _cmd("set_flag", {"name": "door_open", "value": true})).message_type).is_equal("ACK")
	assert_bool(game.flags.door_open).is_true()
	assert_str((await _cmd("set_flag", {})).payload.code).is_equal("invalid_args")
	var given := await _cmd("give_item", {"item": "coin", "count": 3})
	assert_int(int(given.payload.result.value.count)).is_equal(3)
	await _cmd("set_time", {"time": 22.5})
	assert_float(game.clock).is_equal(22.5)
	var loaded := await _cmd("load_save", {"slot": "intro"})
	assert_str(loaded.message_type).is_equal("ACK")
	assert_str(game.state).is_equal("playing")
	assert_bool(game.flags.tutorial_skipped).is_true()
	assert_bool(game.flags.has("door_open")).is_false() # a save replaces state
	assert_float(game.player().global_position.x).is_equal_approx(3.0, 0.001)
	await _cmd("god_mode", {"enabled": true})
	assert_bool(game.player().invulnerable).is_true()
	assert_str((await _cmd("load_save", {"slot": "missing"})).payload.code).is_equal("invalid_args")


func test_manifest_lists_commands_and_the_capabilities_they_bring() -> void:
	_start_game()
	start_sdk()
	var hello := await wait_message("HELLO")
	var m: Dictionary = hello.payload.manifest
	var names: Array = m.commands.map(func(c): return c.name)
	assert_array(names).contains(["teleport", "set_flag", "god_mode", "load_save", "give_item", "set_time", "load_scene", "set_seed", "time_scale"])
	var set_flag: Dictionary = m.commands.filter(func(c): return c.name == "set_flag")[0]
	assert_str(set_flag.description).is_not_empty()
	assert_bool(m.supports.god_mode).is_true()
	assert_bool(m.supports.save_fixtures).is_true()
	assert_bool(m.supports.seed).is_true()


func test_commands_go_away_with_the_game() -> void:
	_start_game()
	await _ready_sdk()
	game.free()
	assert_str((await _cmd("set_flag", {"name": "x"})).payload.code).is_equal("unknown_command")
