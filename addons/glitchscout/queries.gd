extends RefCounted
## QUERY / QUERY_REPLY: navigation, physics and entity queries.
##
## Navigation uses the NavigationServer (3D, else 2D). A path point of type LINK starts a traversal of a
## NavigationLink2D/3D; its link_type comes from the link's "glitchscout_link_type" metadata (walk, jump,
## drop, ladder, teleport), else "drop" for a fall of more than one unit, else "jump". A game without a
## navmesh can register an AStarGrid2D with Glitchscout.use_nav_grid(); without either, navigation queries
## fail with no_navmesh.

const LINK_TYPE_META := "glitchscout_link_type"
const REACH_TOLERANCE := 0.5 ## a path counts as reaching its target if it ends this close
const MAX_SAMPLE_POINTS := 10000
const DEFAULT_FIND_MAX_N := 100

var sdk: Node
var grid: AStarGrid2D = null


func _init(owner: Node) -> void:
	sdk = owner


func on_query(msg: Dictionary) -> void:
	var kind := str(msg.payload.get("kind", ""))
	var p: Dictionary = msg.payload.get("params", {})
	var r: Dictionary
	match kind:
		"nav_path":
			r = _nav_path(_v3(p.get("from")), _v3(p.get("to")))
		"next_waypoint":
			r = _next_waypoint(_v3(p.get("from")), _v3(p.get("to")))
		"nav_sample":
			r = _nav_sample(p)
		"raycast":
			r = _raycast(p)
		"line_of_sight":
			r = _line_of_sight(_v3(p.get("from")), _v3(p.get("to")))
		"find_entities":
			r = _find_entities(p)
		"is_on_screen":
			r = _is_on_screen(p)
		_:
			r = _error("bad_request", "unknown query kind '%s'" % kind)
	if r.has("_error"):
		sdk.reply_error(msg, r._error, r.message, r.get("retryable", false))
	else:
		sdk.reply(msg, "QUERY_REPLY", {"kind": kind, "result": r})


func has_navmesh() -> bool:
	return grid != null or _mode() != ""


func has_nav_links() -> bool:
	var tree := sdk.get_tree()
	if tree == null or tree.root == null:
		return false
	return not NavigationServer3D.map_get_links(_map3d()).is_empty() or not NavigationServer2D.map_get_links(_map2d()).is_empty()


# --- Navigation ------------------------------------------------------------------------------------

## "3d", "2d" or "" for the navigation server that has regions.
func _mode() -> String:
	var tree := sdk.get_tree()
	if tree == null or tree.root == null:
		return ""
	if not NavigationServer3D.map_get_regions(_map3d()).is_empty():
		return "3d"
	if not NavigationServer2D.map_get_regions(_map2d()).is_empty():
		return "2d"
	return ""


func _map3d() -> RID:
	return sdk.get_viewport().world_3d.navigation_map


func _map2d() -> RID:
	return sdk.get_viewport().world_2d.navigation_map


## {points: Array[Vector3], links: Array (owner Object or null, per point)} or an error.
func _path(from: Vector3, to: Vector3) -> Dictionary:
	match _mode():
		"3d":
			if NavigationServer3D.map_get_iteration_id(_map3d()) == 0:
				return _error("navmesh_not_ready", "the navigation map hasn't synchronised yet", true)
			var q := NavigationPathQueryParameters3D.new()
			q.map = _map3d()
			q.start_position = from
			q.target_position = to
			q.metadata_flags = NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_ALL
			var res := NavigationPathQueryResult3D.new()
			NavigationServer3D.query_path(q, res)
			return {"points": Array(res.path), "links": _links(res.path_types, res.path_owner_ids, NavigationPathQueryResult3D.PATH_SEGMENT_TYPE_LINK)}
		"2d":
			if NavigationServer2D.map_get_iteration_id(_map2d()) == 0:
				return _error("navmesh_not_ready", "the navigation map hasn't synchronised yet", true)
			var q := NavigationPathQueryParameters2D.new()
			q.map = _map2d()
			q.start_position = Vector2(from.x, from.y)
			q.target_position = Vector2(to.x, to.y)
			q.metadata_flags = NavigationPathQueryParameters2D.PATH_METADATA_INCLUDE_ALL
			var res := NavigationPathQueryResult2D.new()
			NavigationServer2D.query_path(q, res)
			var pts := Array(res.path).map(func(v: Vector2): return Vector3(v.x, v.y, 0))
			return {"points": pts, "links": _links(res.path_types, res.path_owner_ids, NavigationPathQueryResult2D.PATH_SEGMENT_TYPE_LINK)}
	if grid != null:
		var a := _cell(from)
		var b := _cell(to)
		if not grid.is_in_boundsv(a) or not grid.is_in_boundsv(b):
			return {"points": [], "links": []}
		var half := grid.cell_size / 2.0
		var pts := Array(grid.get_point_path(a, b, true)).map(func(v: Vector2): return Vector3(v.x + half.x, v.y + half.y, 0))
		var links := []
		links.resize(pts.size())
		return {"points": pts, "links": links}
	return _error("no_navmesh", "the game has no navigation regions and registered no Glitchscout.use_nav_grid() grid")


func _links(types: PackedInt32Array, owners: PackedInt64Array, link_type_value: int) -> Array:
	var out := []
	for i in types.size():
		out.append(instance_from_id(owners[i]) if types[i] == link_type_value and owners[i] != 0 else null)
	return out


func _cell(v: Vector3) -> Vector2i:
	var local := (Vector2(v.x, v.y) - grid.offset) / grid.cell_size
	return Vector2i(floori(local.x), floori(local.y))


func _segments(path: Dictionary) -> Array:
	var pts: Array = path.points
	var segs := []
	for i in pts.size() - 1:
		var kind := "walk"
		var owner: Variant = path.links[i]
		if owner != null:
			kind = _link_type(owner, pts[i], pts[i + 1])
		segs.append({"from": _vec(pts[i]), "to": _vec(pts[i + 1]), "link_type": kind})
	return segs


func _link_type(owner: Object, a: Vector3, b: Vector3) -> String:
	if owner.has_meta(LINK_TYPE_META):
		return str(owner.get_meta(LINK_TYPE_META))
	var fall := a.y - b.y if _mode() != "2d" else b.y - a.y # 2D y points down
	return "drop" if fall > 1.0 else "jump"


func _reaches(pts: Array, to: Vector3) -> bool:
	return not pts.is_empty() and pts.back().distance_to(to) <= REACH_TOLERANCE


func _nav_path(from: Vector3, to: Vector3) -> Dictionary:
	var path := _path(from, to)
	if path.has("_error"):
		return path
	var length := 0.0
	for i in path.points.size() - 1:
		length += path.points[i].distance_to(path.points[i + 1])
	return {"reachable": _reaches(path.points, to), "length": snappedf(length, 0.001), "segments": _segments(path)}


func _next_waypoint(from: Vector3, to: Vector3) -> Dictionary:
	var path := _path(from, to)
	if path.has("_error"):
		return path
	if path.points.size() < 2 or not _reaches(path.points, to):
		return {"reachable": false}
	var seg: Dictionary = _segments(path)[0]
	return {"reachable": true, "waypoint": seg.to, "link_type": seg.link_type}


func _nav_sample(p: Dictionary) -> Dictionary:
	var lo := _v3(p.bounds.min)
	var hi := _v3(p.bounds.max)
	var spacing := float(p.spacing)
	var three_d := _mode() == "3d"
	# 3D samples the ground plane (x, z) at the bounds' lower y; 2D and grids sample (x, y).
	var u_range := [lo.x, hi.x]
	var v_range := [lo.z, hi.z] if three_d else [lo.y, hi.y]
	var count := (floori((u_range[1] - u_range[0]) / spacing) + 1) * (floori((v_range[1] - v_range[0]) / spacing) + 1)
	if count > MAX_SAMPLE_POINTS:
		return _error("invalid_args", "%d sample points is over the %d limit; widen spacing" % [count, MAX_SAMPLE_POINTS])
	var origin := _player_position()
	var points := []
	var u: float = u_range[0]
	while u <= u_range[1] + 0.0001:
		var v: float = v_range[0]
		while v <= v_range[1] + 0.0001:
			var pos := Vector3(u, lo.y, v) if three_d else Vector3(u, v, 0)
			var target := pos
			var on_mesh := true
			if three_d:
				# The ground may sit above or below the sampled plane: snap to the navmesh, judge horizontally.
				target = NavigationServer3D.map_get_closest_point(_map3d(), pos)
				on_mesh = Vector2(target.x, target.z).distance_to(Vector2(pos.x, pos.z)) <= REACH_TOLERANCE
			var path := _path(origin, target)
			if path.has("_error"):
				return path
			points.append({"position": _vec(pos), "reachable": on_mesh and _reaches(path.points, target)})
			v += spacing
		u += spacing
	return {"points": points}


# --- Physics ---------------------------------------------------------------------------------------

func _uses_2d() -> bool:
	var players := sdk.get_tree().get_nodes_in_group("player")
	return not players.is_empty() and players[0] is Node2D


func _ray(from: Vector3, to: Vector3, mask: int) -> Dictionary:
	if _uses_2d():
		var space := sdk.get_viewport().world_2d.direct_space_state
		var hit := space.intersect_ray(PhysicsRayQueryParameters2D.create(Vector2(from.x, from.y), Vector2(to.x, to.y), mask))
		if hit.is_empty():
			return {}
		return {"position": Vector3(hit.position.x, hit.position.y, 0), "normal": Vector3(hit.normal.x, hit.normal.y, 0), "collider": hit.collider}
	var space3 := sdk.get_viewport().world_3d.direct_space_state
	var hit3 := space3.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, mask))
	if hit3.is_empty():
		return {}
	return {"position": hit3.position, "normal": hit3.normal, "collider": hit3.collider}


func _raycast(p: Dictionary) -> Dictionary:
	var mask := _mask(p.get("mask", []))
	if mask < 0:
		return _error("invalid_args", "unknown physics layer name in mask %s" % [p.mask])
	var origin := _v3(p.origin)
	var dir := _v3(p.direction).normalized()
	var hit := _ray(origin, origin + dir * float(p.max_distance), mask)
	if hit.is_empty():
		return {"hit": false}
	var r := {"hit": true, "point": _vec(hit.position), "normal": _vec(hit.normal), "distance": snappedf(origin.distance_to(hit.position), 0.001)}
	if hit.collider is Node:
		r.entity_id = sdk.entity_id(hit.collider)
	return r


func _line_of_sight(from: Vector3, to: Vector3) -> Dictionary:
	var hit := _ray(from, to, 0xFFFFFFFF)
	if hit.is_empty():
		return {"visible": true}
	var r := {"visible": false}
	if hit.collider is Node:
		r.blocker_id = sdk.entity_id(hit.collider)
	return r


## Physics layer names to a bit mask (all layers for none; -1 for an unknown name).
func _mask(names: Array) -> int:
	if names.is_empty():
		return 0xFFFFFFFF
	var prefix := "layer_names/2d_physics/layer_%d" if _uses_2d() else "layer_names/3d_physics/layer_%d"
	var mask := 0
	for n in names:
		var found := false
		for i in range(1, 33):
			if str(ProjectSettings.get_setting(prefix % i, "")) == str(n):
				mask |= 1 << (i - 1)
				found = true
				break
		if not found:
			return -1
	return mask


# --- Entities and screen ---------------------------------------------------------------------------

func _find_entities(p: Dictionary) -> Dictionary:
	var types: Array = p.get("types", [])
	var ids: Array = p.get("ids", [])
	var within: Variant = p.get("within")
	var center := _v3(within.center) if within is Dictionary else _player_position()
	var radius := float(within.radius) if within is Dictionary else INF
	var max_n := int(p.get("max_n", DEFAULT_FIND_MAX_N))
	var found := []
	for e in sdk.all_entities():
		var pos := _v3(e.position)
		var d := pos.distance_to(center)
		if d > radius or (not types.is_empty() and not e.type in types) or (not ids.is_empty() and not e.id in ids):
			continue
		e.distance = snappedf(d, 0.001)
		found.append(e)
	found.sort_custom(func(a, b): return a.distance < b.distance)
	var r := {"entities": found.slice(0, max_n)}
	if found.size() > max_n:
		r.truncated = true
	return r


func _is_on_screen(p: Dictionary) -> Dictionary:
	var pos: Vector3
	if p.has("entity_id"):
		var matching: Array = sdk.all_entities().filter(func(e): return e.id == str(p.entity_id))
		if matching.is_empty():
			return _error("unknown_entity", "no observable entity '%s'" % p.entity_id)
		pos = _v3(matching[0].position)
	else:
		pos = _v3(p.position)
	var vp := sdk.get_viewport()
	var rect := vp.get_visible_rect()
	var cam := vp.get_camera_3d()
	if cam and not _uses_2d():
		if not cam.is_position_in_frustum(pos):
			return {"on_screen": false}
		var sp := cam.unproject_position(pos)
		return {"on_screen": rect.has_point(sp), "screen_position": [snappedf(sp.x, 0.1), snappedf(sp.y, 0.1)]}
	var sp2 := vp.get_canvas_transform() * Vector2(pos.x, pos.y)
	return {"on_screen": rect.has_point(sp2), "screen_position": [snappedf(sp2.x, 0.1), snappedf(sp2.y, 0.1)]}


func _player_position() -> Vector3:
	var players := sdk.get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return Vector3.ZERO
	var n: Node = players[0]
	if n is Node3D:
		return n.global_position
	if n is Node2D:
		return Vector3(n.global_position.x, n.global_position.y, 0)
	return Vector3.ZERO


# --- Helpers ---------------------------------------------------------------------------------------

func _error(code: String, message: String, retryable := false) -> Dictionary:
	return {"_error": code, "message": message, "retryable": retryable}


func _v3(d: Variant) -> Vector3:
	if d is Dictionary:
		return Vector3(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)))
	return Vector3.ZERO


func _vec(v: Vector3) -> Dictionary:
	return {"x": snappedf(v.x, 0.0001), "y": snappedf(v.y, 0.0001), "z": snappedf(v.z, 0.0001)}
