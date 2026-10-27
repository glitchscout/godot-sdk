extends SdkTestCase
## OBSERVE / OBSERVATION / STATE_UPDATE. Realtime mode: observing needs no stepping. Every payload is
## also validated against the protocol schema by tools/schemacheck.


## An observable node: glitchscout_observe() returns info.
class Thing:
	extends Node3D

	var info := {}

	func glitchscout_observe() -> Dictionary:
		return info


var level: Node3D
var things: Node3D


func before_test() -> void:
	super.before_test()
	level = load("res://fixture/levels/flat.tscn").instantiate()
	add_child(level)
	things = Node3D.new()
	add_child(things)


func after_test() -> void:
	super.after_test()
	level.free()
	things.free()


func _thing(group: String, id: String, pos: Vector3, info := {}) -> Thing:
	var t := Thing.new()
	t.info = info.duplicate()
	t.info.id = id
	t.add_to_group(group)
	things.add_child(t)
	t.global_position = pos
	return t


func _observe(payload := {}) -> Dictionary:
	start_sdk()
	await handshake()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var m := await request("OBSERVE", payload)
	assert_str(m.get("message_type", "")).is_equal("OBSERVATION")
	return m.get("payload", {})


func _ids(arr: Array) -> Array:
	return arr.map(func(e): return e.id)


func test_player_position_velocity_flags_and_health() -> void:
	var player: CharacterBody3D = level.get_node("Player")
	player.health = 73.0
	var obs := await _observe({"sections": ["player"]})
	var p: Dictionary = obs.player
	assert_float(p.position.y).is_between(0.9, 1.1)
	assert_dict(p.velocity).contains_keys(["x", "y", "z"])
	assert_float(p.health).is_equal(73.0)
	assert_array(p.state_flags).contains(["is_grounded"])
	assert_str(p.scene).is_not_empty()
	assert_array(obs.keys()).contains_exactly(["player"])



## A player inside a sub-scene of a level (a spawn scene, say) is in the level, not the sub-scene.
func test_a_player_in_a_sub_scene_reports_the_outermost_scene() -> void:
	var player: CharacterBody3D = level.get_node("Player")
	var spawn := Node3D.new()
	spawn.scene_file_path = "res://fixture/levels/spawn.tscn"
	level.add_child(spawn)
	spawn.owner = level
	level.remove_child(player)
	spawn.add_child(player)
	player.owner = spawn
	var obs := await _observe({"sections": ["player"]})
	assert_str(obs.player.scene).is_equal("res://fixture/levels/flat.tscn")

func test_interactables_sorted_by_sdk_distance_with_their_fields() -> void:
	_thing("glitchscout_interactable", "door_far", Vector3(0, 1, 9), {"type": "door", "state": "closed", "requires": ["keycard_red"]})
	_thing("glitchscout_interactable", "lever_near", Vector3(3, 1, 0), {"type": "lever", "state": "off", "enabled": true, "required_action": "interact", "interaction_range": 2.0, "ignored_key": 1})
	var obs := await _observe({"sections": ["interactables"]})
	var items: Array = obs.interactables
	assert_array(_ids(items)).contains_exactly(["lever_near", "door_far"])
	assert_float(items[0].distance).is_between(2.9, 3.1)
	assert_float(items[1].distance).is_between(8.9, 9.1)
	assert_str(items[0].required_action).is_equal("interact")
	assert_bool(items[0].has("ignored_key")).is_false()
	assert_array(items[1].requires).contains_exactly(["keycard_red"])


func test_radius_max_n_and_type_filters() -> void:
	for i in 10:
		_thing("glitchscout_interactable", "crate_%d" % i, Vector3(i + 1, 1, 0), {"type": "crate"})
	_thing("glitchscout_interactable", "door", Vector3(2.5, 1, 0), {"type": "door"})
	var obs := await _observe({"sections": ["interactables"], "radius": 5.5, "max_n": 3, "entity_types": ["crate"]})
	assert_array(_ids(obs.interactables)).contains_exactly(["crate_0", "crate_1", "crate_2"])


func test_threats_and_generic_entities() -> void:
	_thing("glitchscout_threat", "robot", Vector3(0, 1, 6), {"type": "enemy", "health": 40, "attack_range": 3, "state": "patrol"})
	_thing("glitchscout_observable", "coin", Vector3(1, 1, 0), {"type": "coin", "value": 5})
	var obs := await _observe({"sections": ["threats", "entities"]})
	assert_str(obs.threats[0].id).is_equal("robot")
	assert_float(obs.threats[0].distance).is_between(5.9, 6.1)
	assert_float(obs.threats[0].attack_range).is_equal(3.0)
	assert_str(obs.entities[0].type).is_equal("coin")
	assert_float(obs.entities[0].properties.value).is_equal(5.0)


func test_camera_position_yaw_and_pitch() -> void:
	var cam := Camera3D.new()
	things.add_child(cam)
	cam.global_position = Vector3(2, 3, 4)
	cam.rotation_degrees = Vector3(-15, 42, 0)
	cam.make_current()
	var obs := await _observe({"sections": ["camera"]})
	assert_float(obs.camera.position.y).is_equal_approx(3.0, 0.001)
	assert_float(obs.camera.yaw).is_equal_approx(42.0, 0.01)
	assert_float(obs.camera.pitch).is_equal_approx(-15.0, 0.01)
	assert_str(obs.camera.mode).is_not_empty()


func test_all_sections_by_default() -> void:
	var obs := await _observe()
	assert_array(obs.keys()).contains(["player", "interactables", "threats", "entities"])


func test_large_scenes_are_truncated_under_the_cap_keeping_the_closest() -> void:
	for i in 5000:
		_thing("glitchscout_observable", "e%04d" % i, Vector3(0.1 * (i + 1), 1, 0), {"type": "rock", "note": "padding to make each entity a little bigger"})
	start_sdk()
	await handshake()
	var id := orch.send("OBSERVE", {"sections": ["entities"]})
	await pump_until(func(): return orch.received.any(func(m): return m is Dictionary and m.get("reply_to") == id), 10000)
	var reply: Dictionary = orch.received.filter(func(m): return m is Dictionary and m.get("reply_to") == id)[0]
	var size := JSON.stringify(reply).length()
	assert_bool(reply.payload.truncated).is_true()
	assert_int(size).is_less_equal(262144)
	assert_int(reply.payload.entities.size()).is_greater(100)
	assert_str(reply.payload.entities[0].id).is_equal("e0000")


func test_max_bytes_raises_the_cap() -> void:
	for i in 3000:
		_thing("glitchscout_observable", "e%04d" % i, Vector3(0.1 * (i + 1), 1, 0), {"type": "rock", "note": "padding to make each entity a little bigger"})
	start_sdk()
	await handshake()
	var small := await request("OBSERVE", {"sections": ["entities"]}, 10000)
	var big := await request("OBSERVE", {"sections": ["entities"], "max_bytes": 4194304}, 10000)
	assert_int(big.payload.entities.size()).is_equal(3000)
	assert_bool(big.payload.get("truncated", false)).is_false()
	assert_int(small.payload.entities.size()).is_less(3000)


func test_stream_sends_full_then_deltas_and_stops() -> void:
	var lever := _thing("glitchscout_interactable", "lever", Vector3(2, 1, 0), {"type": "lever", "state": "off"})
	var key := _thing("glitchscout_interactable", "keycard", Vector3(4, 1, 0), {"type": "keycard", "state": "on_floor"})
	_thing("glitchscout_interactable", "door", Vector3(6, 1, 0), {"type": "door", "state": "closed"})
	start_sdk()
	await handshake()
	var ack := await request("OBSERVE", {"sections": ["player", "interactables"], "stream_hz": 30})
	assert_str(ack.message_type).is_equal("ACK")
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= 2)).is_true()
	lever.info.state = "on"
	key.free() # picked up
	var before := orch.messages("STATE_UPDATE").size()
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= before + 2)).is_true()
	var updates := orch.messages("STATE_UPDATE")
	assert_str(updates[0].payload.mode).is_equal("full")
	assert_int(updates[0].payload.interactables.size()).is_equal(3)
	var changed := updates.slice(before).filter(func(u): return u.payload.has("removed") or u.payload.has("interactables"))
	assert_array(changed).is_not_empty()
	var d: Dictionary = changed[0].payload
	assert_str(d.mode).is_equal("delta")
	assert_array(_ids(d.get("interactables", []))).contains_exactly(["lever"])
	assert_array(d.removed.interactables).contains_exactly(["keycard"])
	assert_dict(d.player).contains_keys(["position", "velocity"])
	# about every 2 ticks at 30 Hz
	var ticks := updates.map(func(u): return int(u.tick_frame))
	assert_int(ticks[1] - ticks[0]).is_equal(2)
	var stop := await request("OBSERVE", {"stream_hz": 0})
	assert_str(stop.message_type).is_equal("ACK")
	var count := orch.messages("STATE_UPDATE").size()
	await pump_until(func(): return false, 300)
	assert_int(orch.messages("STATE_UPDATE").size()).is_less_equal(count + 1)


func test_manifest_lists_entity_types_and_observe_defaults() -> void:
	_thing("glitchscout_interactable", "door", Vector3(2, 1, 0), {"type": "door"})
	_thing("glitchscout_threat", "robot", Vector3(3, 1, 0), {"type": "enemy"})
	start_sdk()
	var hello := await wait_message("HELLO")
	var m: Dictionary = hello.payload.manifest
	assert_array(m.entity_types).contains(["door", "enemy"])
	assert_dict(m.limits.observe_defaults).contains_keys(["radius", "max_n"])


func test_game_values_are_coerced_to_valid_json_and_schema_types() -> void:
	_thing("glitchscout_interactable", "door", Vector3(2, 1, 0), {"type": "door", "state": 2, "enabled": "yes", "interaction_range": "3", "requires": ["k", 7]})
	_thing("glitchscout_threat", "robot", Vector3(3, 1, 0), {"type": "enemy", "health": INF, "attack_range": NAN})
	_thing("glitchscout_observable", "orb", Vector3(4, 1, 0), {"type": "orb", "charge": INF, "nested": {"x": NAN}})
	var obs := await _observe({"sections": ["interactables", "threats", "entities"]})
	var door: Dictionary = obs.interactables[0]
	assert_str(door.state).is_equal("2")
	assert_bool(door.enabled).is_true()
	assert_float(door.interaction_range).is_equal(3.0)
	assert_array(door.requires).contains_exactly(["k", "7"])
	assert_bool(obs.threats[0].has("health")).is_false() # not finite: left out
	assert_that(obs.entities[0].properties.charge).is_null()
	# tools/schemacheck validates the captured message too


func test_an_observation_that_cannot_fit_is_an_error_not_an_oversized_frame() -> void:
	level.get_node("Player").remove_from_group("player")
	_thing("player", "big", Vector3(0, 1, 0), {"state_flags": ["x".repeat(300000)]})
	start_sdk()
	await handshake()
	var m := await request("OBSERVE", {"sections": ["player"]})
	assert_str(m.message_type).is_equal("ERROR")
	assert_str(m.payload.code).is_equal("observation_too_large")
