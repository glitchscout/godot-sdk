extends RefCounted
## Where the player stands for teleport {to}: at a named marker, or beside a named entity.
##
## A marker is a Marker3D or Marker2D (any Node3D or Node2D) in group "glitchscout_marker", named by its
## glitchscout_id metadata, else its node name. The player is put there; in 3D, on the ground under it when there is
## any. A marker with an entity's name says where to stand for that entity.
##
## An entity gets a spot in reach of it (its interaction_range, else DEFAULT_REACH metres) and not on top of it:
## STANDOFFS of the reach away, on the side the player is on if that works, else turned around the entity. Spots on
## the entity itself, or off the navigation mesh or grid when there is one, are left out. Of the rest, the best has
## ground under it (3D), room for the player's collision shapes, and nothing between it and the entity, in that order
## of weight. A hazard's radius is kept out of.
##
## Physics answers in the frame a scene loads; the navigation map doesn't until it has synchronised, and isn't asked
## before then.

const MARKER_GROUP := "glitchscout_marker"
const DEFAULT_REACH := 2.0 ## metres
const STANDOFFS: Array[float] = [0.6, 0.3]
const TURNS: Array[float] = [0.0, 45.0, -45.0, 90.0, -90.0, 135.0, -135.0, 180.0]
const HAZARD_MARGIN := 0.5 ## how far outside a hazard's radius to stand, in metres
const UNITS_PER_METER_2D := 32.0 ## what a 2D game's metre is taken to be when it doesn't say (a 3D game's is 1 unit)
const GROUND_PROBE := 4.0 ## how far under a spot the ground is looked for
const GROUND_HEADROOM := 0.5 ## and how far above it the look starts
const GROUND_CLEARANCE := 0.02 ## the player is put this much above where it stands, not in the floor
const FIT_LIFT := 0.1 ## how far above a spot the player's shapes are tried for room (3D)

var sdk: Node


func _init(owner: Node) -> void:
	sdk = owner


## The position to give the player (a Vector3; z is 0 in 2D), or a String saying why there is none.
func spot(name: String, player: Node) -> Variant:
	var three_d := player is Node3D
	var marker := _marker(name)
	if marker != null:
		var at := _position(marker)
		return _standing(at, at, player) if three_d and not _ground(at, at, player).is_empty() else at
	var entity: Dictionary = sdk.entity_named(name)
	if entity.is_empty():
		return "nothing in the scene is called '%s': it isn't an entity's id, or a marker (a node in group '%s', named by its node name or glitchscout_id)" % [name, MARKER_GROUP]
	if not (entity.node is Node3D or entity.node is Node2D):
		return "'%s' is nowhere to stand by: it isn't a Node2D or Node3D" % name
	var target := _position(entity.node)
	var metre := _metre(three_d)
	var reach := _number(entity.info.get("interaction_range"))
	if reach <= 0.0:
		reach = DEFAULT_REACH * metre
	var keep_out := 0.0
	var radius := _number(entity.info.get("radius"))
	if radius > 0.0:
		keep_out = radius + HAZARD_MARGIN * metre
		reach = maxf(reach, keep_out + HAZARD_MARGIN * metre)
	var toward := _flat(_position(player) - target, three_d)
	if toward.is_zero_approx():
		toward = Vector3.BACK if three_d else Vector3.RIGHT
	toward = toward.normalized()
	var best: Variant = null
	var best_rank := -1
	for share in STANDOFFS:
		var away := maxf(reach * share, keep_out)
		for turn in TURNS:
			var dir := toward.rotated(Vector3.UP if three_d else Vector3.BACK, deg_to_rad(turn))
			var c := _candidate(target + dir * away, target, player, entity.node)
			if c.is_empty():
				continue
			# Ground first, then room for the player, then a clear view of the entity.
			var rank := (4 if c.grounded else 0) + (2 if _fits(c.at, player) else 0) + (1 if _clear(c.at, target, player, entity.node) else 0)
			if rank == 7:
				return c.at
			if rank > best_rank:
				best = c.at
				best_rank = rank
	if best != null:
		return best
	return "found nowhere to stand in reach of '%s': add a marker called '%s' (group '%s') where the player should stand" % [name, name, MARKER_GROUP]


## A metre in the game's units: glitchscout/physics/units_per_meter, else 1 in 3D and UNITS_PER_METER_2D in 2D.
func _metre(three_d: bool) -> float:
	var set := _number(ProjectSettings.get_setting("glitchscout/physics/units_per_meter", 0.0))
	if set > 0.0:
		return set
	return 1.0 if three_d else UNITS_PER_METER_2D


func _marker(name: String) -> Node:
	for node in sdk.get_tree().get_nodes_in_group(MARKER_GROUP):
		if not (node is Node3D or node is Node2D):
			continue
		var id := str(node.get_meta("glitchscout_id")) if node.has_meta("glitchscout_id") else str(node.name)
		if id == name:
			return node
	return null


## A place to stand at `at` as {at, grounded}, or {} for none: on the entity itself, or off the navigation mesh.
## grounded says there is ground under it (always, in 2D).
func _candidate(at: Vector3, target: Vector3, player: Node, entity: Node) -> Dictionary:
	if not player is Node3D:
		return {"at": at, "grounded": true} if sdk.is_walkable(at) else {}
	var ground := _ground(at, target, player)
	if ground.is_empty():
		return {"at": _standing(at, target, player), "grounded": false} if sdk.is_walkable(at) else {}
	if _is_part(ground.collider, entity) or not sdk.is_walkable(ground.position):
		return {}
	return {"at": _standing(at, target, player), "grounded": true}


## `at` with the player's height above the ground under it. Where no ground is found, the player's own height is kept
## if it is near the target's, else the target's is used.
func _standing(at: Vector3, target: Vector3, player: Node) -> Vector3:
	var ground := _ground(at, target, player)
	if ground.is_empty():
		var here: float = _position(player).y
		return Vector3(at.x, here if absf(here - target.y) <= GROUND_PROBE / 2.0 else target.y, at.z)
	return Vector3(at.x, ground.position.y + _stand_height(player) + GROUND_CLEARANCE, at.z)


## What is under `at`, looking from a little above it and the target down to GROUND_PROBE below them.
func _ground(at: Vector3, target: Vector3, player: Node) -> Dictionary:
	var top := maxf(at.y, target.y) + GROUND_HEADROOM
	var bottom := minf(at.y, target.y) - GROUND_PROBE
	return _hit(Vector3(at.x, top, at.z), Vector3(at.x, bottom, at.z), player)


## How far the player's origin is above what it stands on (0 with nothing under it).
func _stand_height(player: Node) -> float:
	var here := _position(player)
	var under := _hit(here, here + Vector3.DOWN * GROUND_PROBE, player)
	return 0.0 if under.is_empty() else here.y - under.position.y


## Whether nothing but the entity is between a spot and it.
func _clear(at: Vector3, target: Vector3, player: Node, entity: Node) -> bool:
	var hit := _hit(at, at.lerp(target, 0.95), player) # short of the target, which may sit on a surface
	return hit.is_empty() or _is_part(hit.collider, entity)


func _is_part(collider: Variant, entity: Node) -> bool:
	return collider is Node and (collider == entity or entity.is_ancestor_of(collider))


## Whether the player's collision shapes, a little above the spot, touch nothing there. The lift keeps the floor it
## stands on from counting, though steep ground still can.
func _fits(at: Vector3, player: Node) -> bool:
	if player is CollisionObject3D:
		var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
		var q := PhysicsShapeQueryParameters3D.new()
		q.exclude = [player.get_rid()]
		q.collision_mask = player.collision_mask
		for owner_id in player.get_shape_owners():
			if player.is_shape_owner_disabled(owner_id):
				continue
			var local: Transform3D = player.shape_owner_get_transform(owner_id)
			for i in player.shape_owner_get_shape_count(owner_id):
				q.shape = player.shape_owner_get_shape(owner_id, i)
				q.transform = Transform3D(player.global_transform.basis, at + Vector3.UP * FIT_LIFT) * local
				if not space.intersect_shape(q, 1).is_empty():
					return false
	elif player is CollisionObject2D:
		var space2: PhysicsDirectSpaceState2D = player.get_world_2d().direct_space_state
		var q2 := PhysicsShapeQueryParameters2D.new()
		q2.exclude = [player.get_rid()]
		q2.collision_mask = player.collision_mask
		for owner_id in player.get_shape_owners():
			if player.is_shape_owner_disabled(owner_id):
				continue
			var local2: Transform2D = player.shape_owner_get_transform(owner_id)
			for i in player.shape_owner_get_shape_count(owner_id):
				q2.shape = player.shape_owner_get_shape(owner_id, i)
				q2.transform = Transform2D(player.global_rotation, player.global_scale, player.global_skew, Vector2(at.x, at.y)) * local2
				if not space2.intersect_shape(q2, 1).is_empty():
					return false
	return true


## The first thing a ray meets, the player aside: {position, collider}, or {}.
func _hit(from: Vector3, to: Vector3, player: Node) -> Dictionary:
	var skip: Array[RID] = []
	if player is CollisionObject3D or player is CollisionObject2D:
		skip.append(player.get_rid())
	if player is Node2D:
		var q := PhysicsRayQueryParameters2D.create(Vector2(from.x, from.y), Vector2(to.x, to.y))
		q.exclude = skip
		var hit: Dictionary = player.get_world_2d().direct_space_state.intersect_ray(q)
		return {} if hit.is_empty() else {"position": Vector3(hit.position.x, hit.position.y, 0), "collider": hit.collider}
	var q3 := PhysicsRayQueryParameters3D.create(from, to)
	q3.exclude = skip
	var hit3: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q3)
	return {} if hit3.is_empty() else {"position": hit3.position, "collider": hit3.collider}


func _position(node: Node) -> Vector3:
	if node is Node3D:
		return node.global_position
	if node is Node2D:
		return Vector3(node.global_position.x, node.global_position.y, 0)
	return Vector3.ZERO


## A vector's part along the ground: everything but its height in 3D, all of it in 2D.
func _flat(v: Vector3, three_d: bool) -> Vector3:
	return Vector3(v.x, 0, v.z) if three_d else Vector3(v.x, v.y, 0)


func _number(v: Variant) -> float:
	return float(v) if (v is float or v is int) and is_finite(float(v)) else 0.0
