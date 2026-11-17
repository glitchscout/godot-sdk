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


func test_builtin_load_scene_has_the_new_scene_in_place_before_the_ack() -> void:
	# A held game reaches the end of the frame only after the next STEP, so a scene swapped there would still be
	# missing for the setup commands that follow (a give_item the new level registers in _ready).
	await _ready_sdk()
	var tree := get_tree()
	var runner := tree.current_scene
	var old := Node3D.new()
	tree.root.add_child(old)
	tree.current_scene = old
	sdk._commands.on_command({"id": "5c1e0c3a-2b4d-4e6f-8a9b-0c1d2e3f4a5b", "message_type": "COMMAND", "payload": {"name": "load_scene", "args": {"scene": "res://fixture/levels/flat.tscn"}}})
	var now := tree.current_scene # read before any frame passes: what the next command sees
	tree.current_scene = runner
	assert_bool(now != old and is_instance_valid(now) and now.is_inside_tree()).is_true()
	assert_str(now.scene_file_path).is_equal("res://fixture/levels/flat.tscn")
	assert_bool(old.is_inside_tree()).is_false()
	assert_bool(await pump_until(func(): return orch.messages("ACK").any(func(m): return m.reply_to == "5c1e0c3a-2b4d-4e6f-8a9b-0c1d2e3f4a5b"))).is_true()
	if is_instance_valid(now) and now != old:
		now.queue_free()
	if is_instance_valid(old):
		old.queue_free()


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
	assert_array(names).contains(["teleport", "set_flag", "god_mode", "save_game", "load_save", "give_item", "set_time", "load_scene", "set_seed", "time_scale", "corrupt_save", "trap_focus", "missing_texture"])
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


func test_handler_results_are_made_json_safe() -> void:
	GlitchscoutSDK.register_command("echo", func(_args: Dictionary): return {"where": Vector3(1, 2, 3), "hp": INF})
	await _ready_sdk()
	var m := await _cmd("echo")
	assert_str(m.message_type).is_equal("ACK")
	assert_float(m.payload.result.value.where.y).is_equal(2.0)
	assert_that(m.payload.result.value.hp).is_null()


## A node with a script at a path (no file behind it), for what player_candidates reads from script paths.
func _scripted(node: Node, path: String) -> Node:
	var script := GDScript.new()
	script.source_code = "extends %s\n" % node.get_class()
	script.reload()
	script.take_over_path(path)
	node.set_script(script)
	return node


func _named(node: Node, name: String, parent: Node) -> Node:
	node.name = name
	parent.add_child(node)
	return node


## The candidates under a node, in the order the command gave them.
func _candidates_under(parent: Node) -> Array:
	var m := await _cmd("player_candidates")
	assert_str(m.message_type).is_equal("ACK")
	var prefix := str(parent.get_path()) + "/"
	return m.payload.result.value.candidates.filter(func(c): return str(c.path).begins_with(prefix))


func test_player_candidates_lists_bodies_and_nodes_called_player_likeliest_first() -> void:
	var world: Node = auto_free(Node2D.new())
	_named(world, "World", self)
	var hero := _named(_scripted(CharacterBody2D.new(), "res://tests/tmp/hero.gd"), "Hero", world)
	var enemy := _named(CharacterBody3D.new(), "Enemy", world)
	var avatar := _named(_scripted(Node2D.new(), "res://tests/tmp/player_avatar.gd"), "Avatar", world)
	var player := _named(CharacterBody2D.new(), "Player", world)
	var spawn := _named(Marker2D.new(), "PlayerSpawn", world)
	_named(RigidBody2D.new(), "Crate", world)
	# "player" only in an engine class name, or on a node with no place in the world, isn't a candidate.
	_named(AnimationPlayer.new(), "AnimationPlayer", world)
	_named(AudioStreamPlayer2D.new(), "PlayerFootsteps", world)
	_named(Control.new(), "PlayerHud", world)
	start_sdk()
	var hello := await handshake()
	assert_array(hello.payload.manifest.commands.map(func(c): return c.name)).contains(["player_candidates"])
	var found := await _candidates_under(world)
	assert_array(found.map(func(c): return c.path)).is_equal(
		[player, avatar, spawn, hero, enemy].map(func(n): return str(n.get_path())))
	assert_dict(found[0]).is_equal({"path": str(player.get_path()), "class": "CharacterBody2D"})
	assert_dict(found[1]).is_equal({"path": str(avatar.get_path()), "class": "Node2D", "script": "res://tests/tmp/player_avatar.gd"})
	assert_dict(found[3]).is_equal({"path": str(hero.get_path()), "class": "CharacterBody2D", "script": "res://tests/tmp/hero.gd"})
	assert_dict(found[4]).is_equal({"path": str(enemy.get_path()), "class": "CharacterBody3D"})


func test_player_candidates_marks_nothing_and_leaves_the_addon_out() -> void:
	var world: Node = auto_free(Node2D.new())
	_named(world, "World", self)
	var player := _named(CharacterBody2D.new(), "Player", world)
	await _ready_sdk()
	var m := await _cmd("player_candidates")
	assert_array(m.payload.result.value.candidates.map(func(c): return c.path)).contains([str(player.get_path())])
	assert_array(m.payload.result.value.candidates.filter(func(c): return str(c.get("script", "")).begins_with("res://addons/glitchscout/"))).is_empty()
	assert_array(player.get_groups()).is_empty()
	assert_array(get_tree().get_nodes_in_group("player")).is_empty()


func test_player_candidates_keeps_the_likeliest_of_a_crowd() -> void:
	var world: Node = auto_free(Node2D.new())
	_named(world, "World", self)
	for i in 30:
		_named(CharacterBody2D.new(), "Enemy%d" % i, world)
	var player := _named(Node2D.new(), "player", world)
	await _ready_sdk()
	var m := await _cmd("player_candidates")
	var all: Array = m.payload.result.value.candidates
	assert_int(all.size()).is_equal(20)
	assert_str(all[0].path).is_equal(str(player.get_path()))


func test_time_scale_is_refused_in_step_mode() -> void:
	# Called directly: a live step-mode session would hold the main loop, and this main-thread mock with it.
	var s := auto_free(GlitchscoutSDK.new()) as GlitchscoutSDK
	s.time_mode = "step"
	var refusal: Variant = s._commands._builtin_time_scale({"scale": 0.5})
	assert_bool(refusal is String).is_true()
	assert_float(Engine.time_scale).is_equal(1.0)
	s.time_mode = "realtime"
	assert_that(s._commands._builtin_time_scale({"scale": 0.5})).is_null()
	assert_float(Engine.time_scale).is_equal(0.5)


func test_manifest_lists_each_command_once() -> void:
	GlitchscoutSDK.register_command("echo", func(_args: Dictionary): return null, "Echoes")
	start_sdk()
	sdk.commands.append({"name": "echo"})
	var hello := await wait_message("HELLO")
	var names: Array = hello.payload.manifest.commands.map(func(c): return c.name)
	assert_int(names.count("echo")).is_equal(1)


func test_save_game_round_trips_through_load_save() -> void:
	_start_game()
	await _ready_sdk()
	await _cmd("load_save", {"slot": "intro"})
	await _cmd("set_flag", {"name": "door_open", "value": true})
	await _cmd("give_item", {"item": "coin", "count": 2})
	var saved := await _cmd("save_game", {"slot": "gs_test_roundtrip"})
	assert_str(saved.message_type).is_equal("ACK")
	var at: Vector3 = game.player().global_position
	game.reset()
	assert_bool(game.flags.has("door_open")).is_false()
	var loaded := await _cmd("load_save", {"slot": "gs_test_roundtrip"})
	assert_str(loaded.message_type).is_equal("ACK")
	assert_bool(game.flags.door_open).is_true()
	assert_int(int(game.inventory.coin)).is_equal(2)
	assert_float(game.player().global_position.distance_to(at)).is_less(0.01)
	assert_str((await _cmd("save_game", {})).payload.code).is_equal("invalid_args")


func test_save_game_writes_a_save_fixture_to_a_path() -> void:
	_start_game()
	await _ready_sdk()
	await _cmd("load_save", {"slot": "intro"})
	await _cmd("set_flag", {"name": "door_open", "value": true})
	var path := ProjectSettings.globalize_path("user://gs_test_fixture_capture.sav")
	DirAccess.remove_absolute(path)
	var saved := await _cmd("save_game", {"path": path})
	assert_str(saved.message_type).is_equal("ACK")
	assert_bool(FileAccess.file_exists(path)).is_true()
	game.reset()
	var loaded := await _cmd("load_save", {"path": path})
	assert_str(loaded.message_type).is_equal("ACK")
	assert_bool(game.flags.door_open).is_true()
	DirAccess.remove_absolute(path)
	assert_str((await _cmd("save_game", {"path": "res://fixture/saves/intro.json"})).payload.code).is_equal("invalid_args")


func test_corrupt_save_drops_a_flag_from_the_next_save_only() -> void:
	_start_game()
	await _ready_sdk()
	await _cmd("load_save", {"slot": "intro"})
	await _cmd("set_flag", {"name": "door_open", "value": true})
	await _cmd("set_flag", {"name": "lever_pulled", "value": true})
	assert_str((await _cmd("corrupt_save", {"flag": "door_open"})).message_type).is_equal("ACK")
	await _cmd("save_game", {"slot": "gs_test_corrupt"})
	await _cmd("save_game", {"slot": "gs_test_clean"}) # the fault fires once
	game.reset()
	await _cmd("load_save", {"slot": "gs_test_corrupt"})
	assert_bool(game.flags.has("door_open")).is_false()
	assert_bool(game.flags.lever_pulled).is_true()
	game.reset()
	await _cmd("load_save", {"slot": "gs_test_clean"})
	assert_bool(game.flags.door_open).is_true()


func test_the_game_state_is_observed_for_persistence_checks() -> void:
	_start_game()
	await _ready_sdk()
	await _cmd("load_save", {"slot": "intro"})
	await _cmd("give_item", {"item": "coin", "count": 3})
	var obs := await request("OBSERVE", {"sections": ["entities"]})
	var state: Array = obs.payload.entities.filter(func(e): return e.id == "game_state")
	assert_int(state.size()).is_equal(1)
	assert_bool(state[0].properties.flags.tutorial_skipped).is_true()
	assert_float(state[0].properties.inventory.coin).is_equal(3.0)


func test_a_save_keeps_interactable_states_and_health() -> void:
	_start_game()
	await _ready_sdk()
	await _cmd("load_scene", {"scene": "course"})
	var door: Node = get_tree().get_nodes_in_group("glitchscout_interactable").filter(func(n): return n.kind == "door")[0]
	door.state = "open"
	game.player().health = 64.0
	await _cmd("save_game", {"slot": "gs_test_states"})
	game.reset()
	var fresh: Node = get_tree().get_nodes_in_group("glitchscout_interactable").filter(func(n): return n.kind == "door" and is_instance_valid(n) and not n.is_queued_for_deletion())[0]
	assert_str(fresh.state).is_not_equal("open")
	await _cmd("load_save", {"slot": "gs_test_states"})
	fresh = get_tree().get_nodes_in_group("glitchscout_interactable").filter(func(n): return n.kind == "door" and not n.is_queued_for_deletion())[0]
	assert_str(fresh.state).is_equal("open")
	assert_float(game.player().health).is_equal(64.0)


func test_save_game_never_overwrites_a_bundled_fixture() -> void:
	_start_game()
	await _ready_sdk()
	var refused := await _cmd("save_game", {"slot": "intro"})
	assert_str(refused.payload.code).is_equal("invalid_args")
	assert_str(refused.payload.message).contains("intro")


func test_a_bundled_fixture_wins_over_a_stray_save_of_the_same_name() -> void:
	DirAccess.make_dir_recursive_absolute("user://glitchscout_saves")
	var f := FileAccess.open("user://glitchscout_saves/intro.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"flags": {"stale": true}}))
	f = null
	_start_game()
	await _ready_sdk()
	await _cmd("load_save", {"slot": "intro"})
	DirAccess.remove_absolute("user://glitchscout_saves/intro.json")
	assert_bool(game.flags.has("stale")).is_false()
	assert_bool(game.flags.tutorial_skipped).is_true()


func test_missing_texture_shows_a_magenta_mesh_in_the_level() -> void:
	_start_game()
	await _ready_sdk()
	assert_str((await _cmd("load_scene", {"scene": "course"})).message_type).is_equal("ACK")
	assert_str((await _cmd("missing_texture")).message_type).is_equal("ACK")
	var mesh: MeshInstance3D = game.find_child("MissingTexture", true, false)
	assert_object(mesh).is_not_null()
	var material: StandardMaterial3D = mesh.material_override
	assert_int(material.shading_mode).is_equal(BaseMaterial3D.SHADING_MODE_UNSHADED)
	assert_object(material.albedo_color).is_equal(Color.MAGENTA)


func test_missing_texture_needs_a_level() -> void:
	_start_game()
	await _ready_sdk()
	assert_str((await _cmd("missing_texture")).message_type).is_equal("ERROR")


func test_trap_focus_makes_options_a_menu_focus_cannot_leave() -> void:
	_start_game()
	await _ready_sdk()
	assert_str((await _cmd("trap_focus")).message_type).is_equal("ACK")
	var menu: Node = game.get_node("MainMenu")
	menu.get_node("Buttons/Options").pressed.emit()
	await get_tree().process_frame
	var trap: Control = menu.get_node("Trap")
	assert_bool(trap.visible).is_true()
	assert_bool(menu.get_node("Buttons").visible).is_false()
	var buttons := trap.get_children()
	assert_int(buttons.size()).is_equal(3)
	assert_bool(buttons[0].has_focus()).is_true()
	assert_str(buttons[0].get_meta("glitchscout_id")).is_equal("settings_trap/sound")
	for b: Button in buttons:
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			var next := b.find_valid_focus_neighbor(side)
			assert_bool(trap.is_ancestor_of(next)).is_true()
		b.pressed.emit()
	assert_bool(trap.visible).is_true() # its buttons do nothing


func test_a_reset_on_the_menu_gives_a_fresh_menu_and_disarms_the_trap() -> void:
	_start_game()
	await _ready_sdk()
	await _cmd("trap_focus")
	var menu: Node = game.get_node("MainMenu")
	menu.get_node("Buttons/Options").pressed.emit()
	game.reset()
	var fresh: Node = game.get_node("MainMenu")
	assert_object(fresh).is_not_same(menu)
	assert_bool(fresh.get_node("Buttons").visible).is_true()
	fresh.get_node("Buttons/Options").pressed.emit()
	assert_bool(fresh.get_node("Options").visible).is_true()
	assert_object(fresh.get_node_or_null("Trap")).is_null()
