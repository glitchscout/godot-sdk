extends SdkTestCase
## COMMAND teleport {to}: the player is put by a named entity, in reach of it, or at a named marker.

var game: Node
var _autoload: Node
var _extra: Array[Node] = []


func after_test() -> void:
	super.after_test()
	for n in _extra:
		if is_instance_valid(n):
			n.free()
	_extra.clear()
	if is_instance_valid(game):
		game.free()
	if _autoload:
		get_tree().root.add_child(_autoload)
		_autoload = null


## The fixture talks to the SDK at /root/Glitchscout, so the test's SDK stands in for the autoload there.
func _start(level: String) -> void:
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
	assert_str((await _cmd("load_scene", {"scene": level})).message_type).is_equal("ACK")
	for i in 3:
		await get_tree().physics_frame


func _cmd(name: String, args := {}) -> Dictionary:
	return await request("COMMAND", {"name": name, "args": args})


func _press_interact() -> void:
	await get_tree().physics_frame
	await request("ACTION_INJECT", {"digital_buttons": [{"action": "interact", "op": "press", "hold_ticks": 1}]})
	for i in 4:
		await get_tree().physics_frame


func _game_events(name: String) -> Array:
	await pump_until(func(): return false, 100) # collect what the SDK has sent
	return orch.messages("EVENT").filter(func(m): return m.payload.get("name") == name)


func _thing(id: String) -> Node3D:
	for n in get_tree().get_nodes_in_group("glitchscout_interactable"):
		if n.get("id") == id:
			return n
	return null


func _marker(name: String, at: Vector3) -> Marker3D:
	var m := Marker3D.new()
	m.name = name
	m.add_to_group("glitchscout_marker")
	game.add_child(m)
	m.global_position = at
	_extra.append(m)
	return m


func test_the_player_lands_in_reach_of_a_door_and_can_open_it() -> void:
	await _start("course")
	await _cmd("give_item", {"item": "keycard_red"})
	var t := await _cmd("teleport", {"to": "door_red"})
	assert_str(t.message_type).is_equal("ACK")
	var p: Vector3 = game.player().global_position
	var door := _thing("door_red")
	assert_float(p.distance_to(door.global_position)).override_failure_message("player at %s" % p).is_less_equal(door.interaction_range)
	assert_float(p.z).override_failure_message("player at %s is not on the side it came from" % p).is_greater(door.global_position.z + 0.5)
	assert_float(p.y).override_failure_message("player at %s is not standing on the floor" % p).is_between(0.95, 1.2)
	await _press_interact()
	assert_int((await _game_events("door_opened")).size()).is_equal(1)


func test_the_player_stands_beside_a_thing_and_not_in_it() -> void:
	await _start("course")
	game.player().velocity = Vector3(3, 0, 0)
	assert_str((await _cmd("teleport", {"to": "elder"})).message_type).is_equal("ACK")
	var p: Vector3 = game.player().global_position
	var elder := _thing("elder")
	var d := Vector2(p.x, p.z).distance_to(Vector2(elder.global_position.x, elder.global_position.z))
	assert_float(d).override_failure_message("player at %s" % p).is_between(1.0, elder.interaction_range)
	assert_float(game.player().velocity.length()).is_equal(0.0)
	await _press_interact()
	assert_int((await _game_events("dialogue_started")).size()).is_equal(1)


func test_a_marker_names_a_spot_with_nothing_there() -> void:
	await _start("course")
	_marker("card_corner", Vector3(-2, 0, 2)) # on the floor: the player stands there, it isn't sunk to its middle
	assert_str((await _cmd("teleport", {"to": "card_corner"})).message_type).is_equal("ACK")
	var p: Vector3 = game.player().global_position
	assert_float(Vector2(p.x, p.z).distance_to(Vector2(-2, 2))).override_failure_message("player at %s" % p).is_less(0.01)
	assert_float(p.y).override_failure_message("player at %s is not standing on the floor" % p).is_between(0.95, 1.2)


func test_a_marker_takes_its_name_from_glitchscout_id_and_wins_over_an_entity_of_that_name() -> void:
	await _start("course")
	var m := _marker("Spot", Vector3(-1, 1, 2))
	m.set_meta("glitchscout_id", "elder") # where to stand for the elder, said by the game
	assert_str((await _cmd("teleport", {"to": "elder"})).message_type).is_equal("ACK")
	var p: Vector3 = game.player().global_position
	assert_float(Vector2(p.x, p.z).distance_to(Vector2(-1, 2))).override_failure_message("player at %s" % p).is_less(0.01)
	assert_str((await _cmd("teleport", {"to": "Spot"})).payload.code).is_equal("invalid_args")


func test_an_unknown_name_is_refused_by_name() -> void:
	await _start("course")
	var before: Vector3 = game.player().global_position
	var bad := await _cmd("teleport", {"to": "vault_dor"})
	assert_str(bad.payload.code).is_equal("invalid_args")
	assert_str(bad.payload.message).contains("vault_dor").contains("glitchscout_marker")
	assert_bool(game.player().global_position.is_equal_approx(before)).is_true()


func test_a_level_with_no_navmesh_still_places_the_player_in_reach() -> void:
	await _start("flat")
	var chest := _chest(Vector3(6, 1, -3))
	assert_str((await _cmd("teleport", {"to": "chest"})).message_type).is_equal("ACK")
	var p: Vector3 = game.player().global_position
	var d := Vector2(p.x, p.z).distance_to(Vector2(6, -3))
	assert_float(d).override_failure_message("player at %s" % p).is_between(1.0, chest.interaction_range)
	assert_float(p.y).override_failure_message("player at %s is not standing on the floor" % p).is_between(0.95, 1.2)
	await _press_interact()
	assert_int((await _game_events("dialogue_started")).size()).is_equal(1)


func test_a_2d_game_is_placed_on_its_plane() -> void:
	start_sdk()
	await handshake()
	var player := CharacterBody2D.new()
	player.add_to_group("player")
	add_child(player)
	player.global_position = Vector2(100, 400)
	var lever := Node2D.new()
	lever.add_to_group("glitchscout_interactable")
	lever.set_script(_observed({"id": "lever", "interaction_range": 48.0}))
	add_child(lever)
	lever.global_position = Vector2(500, 400)
	var spot := Marker2D.new()
	spot.name = "ledge"
	spot.add_to_group("glitchscout_marker")
	add_child(spot)
	spot.global_position = Vector2(-40, 12)
	_extra.append_array([player, lever, spot])
	assert_str((await _cmd("teleport", {"to": "lever"})).message_type).is_equal("ACK")
	var d := player.global_position.distance_to(lever.global_position)
	assert_float(d).override_failure_message("player at %s" % player.global_position).is_between(10.0, 48.0)
	assert_str((await _cmd("teleport", {"to": "ledge"})).message_type).is_equal("ACK")
	assert_bool(player.global_position.is_equal_approx(Vector2(-40, 12))).is_true()


func test_the_manifest_says_teleport_takes_a_name() -> void:
	start_sdk()
	var hello := await wait_message("HELLO")
	var teleport: Dictionary = hello.payload.manifest.commands.filter(func(c): return c.name == "teleport")[0]
	assert_dict(teleport.params).contains_keys(["position", "to"])


## A script whose glitchscout_observe() returns info.
func _observed(info: Dictionary) -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node2D\nfunc glitchscout_observe() -> Dictionary:\n\treturn %s\n" % var_to_str(info)
	s.reload()
	return s


## A held game gets its setup commands back to back: the level is one a command loaded in the same frame, and neither
## a physics tick nor a navigation sync has happened in it yet.
func test_a_level_loaded_in_the_same_frame_already_places_the_player() -> void:
	await _start("flat")
	sdk._commands.on_command({"id": "5c1e0c3a-2b4d-4e6f-8a9b-0c1d2e3f4a5b", "message_type": "COMMAND", "payload": {"name": "load_scene", "args": {"scene": "course"}}})
	sdk._commands.on_command({"id": "6d2f1d4b-3c5e-4f70-9bac-1d2e3f4a5b6c", "message_type": "COMMAND", "payload": {"name": "teleport", "args": {"to": "door_red"}}})
	var p: Vector3 = game.player().global_position # read before any frame passes
	var door := _thing("door_red")
	assert_float(p.distance_to(door.global_position)).override_failure_message("player at %s" % p).is_less_equal(door.interaction_range)
	assert_float(p.z).override_failure_message("player at %s is not on the side it came from" % p).is_greater(door.global_position.z + 0.5)
	assert_float(p.y).override_failure_message("player at %s is not standing on the floor" % p).is_between(0.95, 1.2)
	assert_bool(await pump_until(func(): return orch.messages("ACK").any(func(m): return m.reply_to == "6d2f1d4b-3c5e-4f70-9bac-1d2e3f4a5b6c"))).is_true()


func _chest(at: Vector3) -> StaticBody3D:
	var chest: StaticBody3D = load("res://fixture/course/interactable.gd").new()
	chest.id = "chest"
	chest.kind = "npc"
	game.add_child(chest)
	chest.global_position = at
	_extra.append(chest)
	return chest


func test_the_player_isnt_put_inside_a_wall_on_the_way() -> void:
	await _start("course")
	var chest := _chest(Vector3(0, 1, 4.4)) # behind the course's invisible wall (z 2.75 to 3.25, x -2 to 2)
	assert_str((await _cmd("teleport", {"to": "chest"})).message_type).is_equal("ACK")
	var p: Vector3 = game.player().global_position
	assert_float(Vector2(p.x, p.z).distance_to(Vector2(0, 4.4))).override_failure_message("player at %s" % p).is_less_equal(chest.interaction_range)
	assert_float(p.z).override_failure_message("player at %s is in the wall, or on the far side of it" % p).is_greater_equal(3.75)


func test_the_player_is_put_on_ground_when_some_spots_have_none() -> void:
	await _start("flat")
	var island := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	shape.shape.size = Vector3(2, 1, 2)
	island.add_child(shape)
	island.position = Vector3(200, 0, 0) # its top is at 0.5, far off the level's floor
	game.add_child(island)
	_extra.append(island)
	_chest(Vector3(200, 1.5, 0))
	assert_str((await _cmd("teleport", {"to": "chest"})).message_type).is_equal("ACK")
	var p: Vector3 = game.player().global_position
	assert_float(maxf(absf(p.x - 200), absf(p.z))).override_failure_message("player at %s is off the island" % p).is_less(1.0)
	assert_float(p.y).override_failure_message("player at %s is not standing on the island" % p).is_between(1.45, 1.7)


## A thing that gives no interaction_range is stood 2 metres' reach from, and a 2D game's metre is 32 pixels unless
## glitchscout/physics/units_per_meter says otherwise: 2 pixels would put the player on top of it.
func test_a_thing_with_no_range_gets_one_in_the_games_own_units() -> void:
	start_sdk()
	await handshake()
	var player := CharacterBody2D.new()
	player.add_to_group("player")
	add_child(player)
	player.global_position = Vector2(100, 400)
	var boss := Node2D.new()
	boss.add_to_group("glitchscout_threat")
	boss.set_script(_observed({"id": "boss"}))
	add_child(boss)
	boss.global_position = Vector2(500, 400)
	_extra.append_array([player, boss])
	assert_str((await _cmd("teleport", {"to": "boss"})).message_type).is_equal("ACK")
	var d := player.global_position.distance_to(boss.global_position)
	assert_float(d).override_failure_message("player at %s, %s from the boss" % [player.global_position, d]).is_between(32.0, 64.0)
	ProjectSettings.set_setting("glitchscout/physics/units_per_meter", 100.0)
	assert_str((await _cmd("teleport", {"to": "boss"})).message_type).is_equal("ACK")
	ProjectSettings.set_setting("glitchscout/physics/units_per_meter", null)
	d = player.global_position.distance_to(boss.global_position)
	assert_float(d).override_failure_message("player at %s, %s from the boss" % [player.global_position, d]).is_between(100.0, 200.0)


## A 3D game whose unit isn't a metre has its ground looked for, and its reach given, in its own units.
func test_a_3d_game_in_centimetres_is_measured_in_centimetres() -> void:
	start_sdk()
	await handshake()
	ProjectSettings.set_setting("glitchscout/physics/units_per_meter", 100.0)
	var world := Node3D.new()
	add_child(world)
	_extra.append(world)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	floor_shape.shape = BoxShape3D.new()
	floor_shape.shape.size = Vector3(4000, 100, 4000)
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -50, 0)
	world.add_child(floor_body)
	var player := CharacterBody3D.new()
	var body := CollisionShape3D.new()
	body.shape = CapsuleShape3D.new()
	body.shape.radius = 40.0
	body.shape.height = 180.0
	player.add_child(body)
	player.add_to_group("player")
	player.position = Vector3(0, 90, 0)
	world.add_child(player)
	var statue := Node3D.new()
	statue.add_to_group("glitchscout_observable")
	statue.set_script(_observed3d({"id": "statue"}))
	statue.position = Vector3(1000, 150, 0) # its middle is 150 cm up, more than 4 units above the floor
	world.add_child(statue)
	await get_tree().physics_frame
	var reply := await _cmd("teleport", {"to": "statue"})
	ProjectSettings.set_setting("glitchscout/physics/units_per_meter", null)
	assert_str(reply.message_type).is_equal("ACK")
	var p := player.global_position
	assert_float(Vector2(p.x, p.z).distance_to(Vector2(1000, 0))).override_failure_message("player at %s" % p).is_between(100.0, 200.0)
	assert_float(p.y).override_failure_message("player at %s is not standing on the floor" % p).is_between(88.0, 95.0)


## A hazard is stood beside, outside its radius.
func test_the_player_is_kept_out_of_a_hazards_radius() -> void:
	await _start("flat")
	var lava := Node3D.new()
	lava.add_to_group("glitchscout_hazard")
	lava.set_script(_observed3d({"id": "lava", "radius": 3.0}))
	lava.position = Vector3(10, 0, 0)
	game.add_child(lava)
	_extra.append(lava)
	assert_str((await _cmd("teleport", {"to": "lava"})).message_type).is_equal("ACK")
	var p: Vector3 = game.player().global_position
	assert_float(Vector2(p.x, p.z).distance_to(Vector2(10, 0))).override_failure_message("player at %s" % p).is_between(3.4, 4.1)


func _observed3d(info: Dictionary) -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node3D\nfunc glitchscout_observe() -> Dictionary:\n\treturn %s\n" % var_to_str(info)
	s.reload()
	return s
