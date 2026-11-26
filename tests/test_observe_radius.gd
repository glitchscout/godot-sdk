extends SdkTestCase
## The default observation radius is 500 m in the game's units: glitchscout/physics/units_per_meter when the project
## sets it, else 1 unit a metre in a 3D game and 32 in a 2D one (its player is a Node2D). The manifest says what it is.

const UNITS := "glitchscout/physics/units_per_meter"


class Thing3D:
	extends Node3D

	func glitchscout_observe() -> Dictionary:
		return {"id": name, "type": "marker"}


class Thing2D:
	extends Node2D

	func glitchscout_observe() -> Dictionary:
		return {"id": name, "type": "marker"}


var world: Node


func before_test() -> void:
	super.before_test()
	ProjectSettings.set_setting(UNITS, null)


func after_test() -> void:
	super.after_test()
	ProjectSettings.set_setting(UNITS, null)
	if is_instance_valid(world):
		world.free()


## A world with its player at the origin and a marker this far along x.
func _world(two_d: bool, markers := {}) -> void:
	world = Node2D.new() if two_d else Node3D.new()
	add_child(world)
	var player: Node = Node2D.new() if two_d else Node3D.new()
	player.add_to_group("player")
	world.add_child(player)
	for id in markers:
		var m: Node = Thing2D.new() if two_d else Thing3D.new()
		m.name = id
		m.add_to_group("glitchscout_observable")
		world.add_child(m)
		if two_d:
			(m as Node2D).position = Vector2(markers[id], 0)
		else:
			(m as Node3D).position = Vector3(markers[id], 0, 0)


func _default_radius() -> float:
	start_sdk()
	var hello := await wait_message("HELLO")
	return float(hello.payload.manifest.limits.observe_defaults.radius)


func _seen(payload := {}) -> Array:
	start_sdk()
	await handshake()
	await get_tree().physics_frame
	var m := await request("OBSERVE", payload)
	return m.payload.get("entities", []).map(func(e): return e.id)


func test_a_project_that_sets_units_per_meter_gets_500_of_its_metres() -> void:
	ProjectSettings.set_setting(UNITS, 100.0)
	_world(true)
	assert_float(await _default_radius()).is_equal(50000.0)


func test_a_3d_game_that_sets_none_gets_500_units() -> void:
	_world(false)
	assert_float(await _default_radius()).is_equal(500.0)


func test_a_2d_game_that_sets_none_gets_500_metres_of_32_pixels() -> void:
	_world(true)
	assert_float(await _default_radius()).is_equal(16000.0)


func test_a_2d_observation_with_no_radius_sees_500_metres() -> void:
	_world(true, {"near": 10000.0, "far": 17000.0})
	var seen := await _seen({"sections": ["entities"]})
	assert_array(seen).contains(["near"])
	assert_array(seen).not_contains(["far"])


func test_a_3d_observation_with_no_radius_sees_500_units() -> void:
	_world(false, {"near": 400.0, "far": 600.0})
	var seen := await _seen({"sections": ["entities"]})
	assert_array(seen).contains(["near"])
	assert_array(seen).not_contains(["far"])


func test_a_request_that_names_a_radius_gets_it() -> void:
	_world(true, {"near": 10000.0})
	var seen := await _seen({"sections": ["entities"], "radius": 100.0})
	assert_array(seen).not_contains(["near"])
