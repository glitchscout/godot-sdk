extends SdkTestCase
## QUERY / QUERY_REPLY. Realtime mode with the main-thread mock.
##
## The world: the player at (1, 0, 0) on region A (x 0..10, y 0); a gap; region B (x 14..24, y -1)
## reached over a NavigationLink3D from (9.5, 0, 0) to (14.5, -1, 0) marked as a jump; a wall
## (glitchscout_id "wall_1") across x = 5 at head height; a camera at (0, 1, 0) looking along +x.


class Thing:
	extends Node3D

	var info := {}

	func glitchscout_observe() -> Dictionary:
		return info


var world: Node3D
var link: NavigationLink3D


func before_test() -> void:
	super.before_test()
	world = Node3D.new()
	add_child(world)


func after_test() -> void:
	super.after_test()
	world.free()
	ProjectSettings.set_setting("layer_names/3d_physics/layer_2", null)


func _quad(x0: float, x1: float, y: float) -> NavigationRegion3D:
	var nm := NavigationMesh.new()
	nm.vertices = PackedVector3Array([Vector3(x0, y, -2), Vector3(x1, y, -2), Vector3(x1, y, 2), Vector3(x0, y, 2)])
	nm.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	var r := NavigationRegion3D.new()
	r.navigation_mesh = nm
	world.add_child(r)
	return r


func _thing(group: String, id: String, pos: Vector3, info := {}) -> Thing:
	var t := Thing.new()
	t.info = info.duplicate()
	t.info.id = id
	t.add_to_group(group)
	world.add_child(t)
	t.global_position = pos
	return t


func _build(with_link := true, link_type := "jump", b_height := -1.0) -> void:
	_thing("player", "player", Vector3(1, 0, 0))
	_quad(0, 10, 0)
	_quad(14, 24, b_height)
	if with_link:
		link = NavigationLink3D.new()
		link.start_position = Vector3(9.5, 0, 0)
		link.end_position = Vector3(14.5, b_height, 0)
		if not link_type.is_empty():
			link.set_meta("glitchscout_link_type", link_type)
		world.add_child(link)
	var wall := StaticBody3D.new()
	wall.set_meta("glitchscout_id", "wall_1")
	wall.collision_layer = 2
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1, 2, 4)
	shape.shape = box
	wall.add_child(shape)
	world.add_child(wall)
	wall.global_position = Vector3(5, 1, 0)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 1, 0), Vector3(10, 1, 0))
	cam.make_current()
	# Navigation maps need a couple of synchronisations before regions show up in queries.
	var map := world.get_world_3d().navigation_map
	for i in 120:
		await get_tree().physics_frame
		if not NavigationServer3D.map_get_path(map, Vector3(1, 0, 0), Vector3(5, 0, 0), true).is_empty():
			break
	start_sdk()
	await handshake()


func _query(kind: String, params: Dictionary) -> Dictionary:
	var m := await request("QUERY", {"kind": kind, "params": params})
	return m


func _v(x: float, y: float, z: float) -> Dictionary:
	return {"x": x, "y": y, "z": z}


func test_nav_path_segments_carry_link_types() -> void:
	await _build()
	var m := await _query("nav_path", {"from": _v(1, 0, 0), "to": _v(20, -1, 0)})
	assert_str(m.message_type).is_equal("QUERY_REPLY")
	var r: Dictionary = m.payload.result
	assert_bool(r.reachable).is_true()
	assert_array(r.segments.map(func(s): return s.link_type)).contains_exactly(["walk", "jump", "walk"])
	assert_float(r.length).is_greater(19.0)


func test_a_link_without_metadata_is_a_drop_when_it_falls() -> void:
	await _build(true, "", -3.0)
	var r: Dictionary = (await _query("nav_path", {"from": _v(1, 0, 0), "to": _v(20, -3, 0)})).payload.result
	assert_array(r.segments.map(func(s): return s.link_type)).contains(["drop"])


func test_unreachable_targets_and_next_waypoint() -> void:
	await _build(false)
	var r: Dictionary = (await _query("nav_path", {"from": _v(1, 0, 0), "to": _v(20, -1, 0)})).payload.result
	assert_bool(r.reachable).is_false()
	var w: Dictionary = (await _query("next_waypoint", {"from": _v(1, 0, 0), "to": _v(8, 0, 1)})).payload.result
	assert_bool(w.reachable).is_true()
	assert_float(w.waypoint.x).is_equal_approx(8.0, 0.01)
	assert_str(w.link_type).is_equal("walk")


func test_nav_sample_marks_the_gap_unreachable() -> void:
	await _build()
	var r: Dictionary = (await _query("nav_sample", {"bounds": {"min": _v(1, 0, 0), "max": _v(21, 0, 0)}, "spacing": 4})).payload.result
	var by_x := {}
	for p in r.points:
		by_x[int(p.position.x)] = p.reachable
	assert_dict(by_x).is_equal({1: true, 5: true, 9: true, 13: false, 17: true, 21: true})


func test_raycast_hits_and_misses_with_entity_ids_and_masks() -> void:
	await _build()
	ProjectSettings.set_setting("layer_names/3d_physics/layer_2", "walls")
	var hit: Dictionary = (await _query("raycast", {"origin": _v(0, 1, 0), "direction": _v(1, 0, 0), "max_distance": 20})).payload.result
	assert_bool(hit.hit).is_true()
	assert_float(hit.distance).is_equal_approx(4.5, 0.05)
	assert_str(hit.entity_id).is_equal("wall_1")
	assert_float(hit.normal.x).is_equal_approx(-1.0, 0.01)
	var miss: Dictionary = (await _query("raycast", {"origin": _v(0, 1, 0), "direction": _v(-1, 0, 0), "max_distance": 20})).payload.result
	assert_bool(miss.hit).is_false()
	var masked: Dictionary = (await _query("raycast", {"origin": _v(0, 1, 0), "direction": _v(1, 0, 0), "max_distance": 20, "mask": ["walls"]})).payload.result
	assert_bool(masked.hit).is_true()
	var bad := await _query("raycast", {"origin": _v(0, 1, 0), "direction": _v(1, 0, 0), "max_distance": 20, "mask": ["no_such_layer"]})
	assert_str(bad.payload.code).is_equal("invalid_args")


func test_line_of_sight() -> void:
	await _build()
	var blocked: Dictionary = (await _query("line_of_sight", {"from": _v(0, 1, 0), "to": _v(9, 1, 0)})).payload.result
	assert_bool(blocked.visible).is_false()
	assert_str(blocked.blocker_id).is_equal("wall_1")
	var clear: Dictionary = (await _query("line_of_sight", {"from": _v(0, 1, 3), "to": _v(9, 1, 3)})).payload.result
	assert_bool(clear.visible).is_true()


func test_find_entities_filters() -> void:
	await _build()
	for i in 5:
		_thing("glitchscout_observable", "coin_%d" % i, Vector3(2 + i, 0, 0), {"type": "coin"})
	_thing("glitchscout_interactable", "door", Vector3(3, 0, 0), {"type": "door"})
	var r: Dictionary = (await _query("find_entities", {"types": ["coin"], "max_n": 2})).payload.result
	assert_array(r.entities.map(func(e): return e.id)).contains_exactly(["coin_0", "coin_1"])
	assert_bool(r.truncated).is_true()
	var near: Dictionary = (await _query("find_entities", {"within": {"center": _v(3, 0, 0), "radius": 0.5}})).payload.result
	assert_array(near.entities.map(func(e): return e.id)).contains_exactly_in_any_order(["coin_1", "door"])
	var ids: Dictionary = (await _query("find_entities", {"ids": ["door"]})).payload.result
	assert_str(ids.entities[0].type).is_equal("door")


func test_is_on_screen() -> void:
	await _build()
	_thing("glitchscout_observable", "ahead", Vector3(10, 1, 0), {"type": "marker"})
	var ahead: Dictionary = (await _query("is_on_screen", {"entity_id": "ahead"})).payload.result
	assert_bool(ahead.on_screen).is_true()
	assert_int(ahead.screen_position.size()).is_equal(2)
	var behind: Dictionary = (await _query("is_on_screen", {"position": _v(-10, 1, 0)})).payload.result
	assert_bool(behind.on_screen).is_false()
	var unknown := await _query("is_on_screen", {"entity_id": "nobody"})
	assert_str(unknown.payload.code).is_equal("unknown_entity")


func test_manifest_reports_navmesh_and_links() -> void:
	await _build()
	var supports: Dictionary = orch.messages("HELLO")[0].payload.manifest.supports
	assert_bool(supports.navmesh).is_true()
	assert_bool(supports.nav_links).is_true()


func test_without_a_navmesh_nav_queries_fail_clearly_or_use_a_registered_grid() -> void:
	for i in 10:
		await get_tree().physics_frame # let earlier tests' regions leave the map
	_thing("player", "player", Vector3(0.5, 0.5, 0))
	start_sdk()
	await handshake()
	assert_bool(orch.messages("HELLO")[0].payload.manifest.supports.navmesh).is_false()
	var none := await _query("nav_path", {"from": _v(0.5, 0.5, 0), "to": _v(8.5, 0.5, 0)})
	assert_str(none.payload.code).is_equal("no_navmesh")
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, 10, 10)
	grid.cell_size = Vector2(1, 1)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()
	for y in 9:
		grid.set_point_solid(Vector2i(4, y)) # a wall with a gap at the bottom row
	sdk.use_nav_grid(grid)
	var r: Dictionary = (await _query("nav_path", {"from": _v(0.5, 0.5, 0), "to": _v(8.5, 0.5, 0)})).payload.result
	assert_bool(r.reachable).is_true()
	assert_bool(r.segments.all(func(s): return s.link_type == "walk")).is_true()
	assert_bool(r.segments.any(func(s): return s.to.y >= 9.0)).is_true() # went round through the gap
