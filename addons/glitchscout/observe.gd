extends RefCounted
## OBSERVE / OBSERVATION and the STATE_UPDATE stream, with interest management.
##
## What the game exposes (plan §5.1):
## - the player: the first node in group "player";
## - interactables: group "glitchscout_interactable";
## - threats: group "glitchscout_threat";
## - other observable entities: group "glitchscout_observable".
## Each node may define glitchscout_observe() -> Dictionary with its fields ("id" overrides the node path).
## The SDK computes distances from the player, sorts by distance, filters by radius, type and max_n, and
## truncates by distance to fit the text-frame cap (default 256 KB), flagging truncated: true.

const DEFAULT_RADIUS := 500.0
const DEFAULT_MAX_N := 10000
const GROUPS := {
	"interactables": "glitchscout_interactable",
	"threats": "glitchscout_threat",
	"entities": "glitchscout_observable",
}
const INTERACTABLE_KEYS := ["type", "state", "enabled", "required_action", "interaction_range", "requires"]
const THREAT_KEYS := ["type", "health", "attack_range", "state"]
const SECTIONS := ["player", "interactables", "camera", "threats", "entities"]

var sdk: Node

var _stream_hz := 0.0
var _stream_filter := {}
var _stream_due := 0
var _streamed := false
var _last_states := {} ## interactable id -> state at the last STATE_UPDATE


func _init(owner: Node) -> void:
	sdk = owner


func on_observe(msg: Dictionary) -> void:
	var p: Dictionary = msg.payload
	if p.has("stream_hz"):
		_stream_hz = float(p.stream_hz)
		_stream_filter = p
		_streamed = false
		_stream_due = sdk.tick + 1
		sdk.reply(msg, "ACK", {})
		return
	sdk.send_text(_fit("OBSERVATION", p, msg.get("id"), ""))


## Called at the start of every game frame: sends a STATE_UPDATE when one is due.
func frame_start() -> void:
	if _stream_hz <= 0.0 or sdk.tick < _stream_due:
		return
	sdk.send_text(_fit("STATE_UPDATE", _stream_filter, null, "delta" if _streamed else "full"))
	_streamed = true
	_stream_due = sdk.tick + maxi(1, roundi(Engine.physics_ticks_per_second / _stream_hz))


## Entity types present in the scene now, for the manifest.
func entity_types() -> Array[String]:
	var seen: Array[String] = []
	for section in GROUPS:
		for node in sdk.get_tree().get_nodes_in_group(GROUPS[section]):
			var t := str(_info(node).get("type", ""))
			if not t.is_empty() and not t in seen:
				seen.append(t)
	return seen


## Encodes an OBSERVATION or STATE_UPDATE, dropping the farthest entities, then interactables, then threats
## until it fits the cap.
func _fit(message_type: String, filter: Dictionary, reply_to: Variant, mode: String) -> String:
	var cap := int(filter.get("max_bytes", sdk.MAX_TEXT_FRAME_BYTES))
	var present := observe(filter)
	var obs := present.duplicate()
	var saved := _last_states.duplicate()
	var build := func() -> String:
		if mode.is_empty():
			return sdk.encode(message_type, obs, reply_to)
		_last_states = saved.duplicate() # each attempt diffs against the last update, not the last attempt
		return sdk.encode(message_type, _state_payload(obs, present, mode), reply_to)
	var text: String = build.call()
	while text.to_utf8_buffer().size() > cap:
		obs.truncated = true
		var cut := false
		for section in ["entities", "interactables", "threats"]:
			var arr: Array = obs.get(section, [])
			if not arr.is_empty():
				obs[section] = arr.slice(0, arr.size() * 9 / 10)
				cut = true
				break
		if not cut:
			break
		text = build.call()
	return text


## A STATE_UPDATE: full sends everything; delta sends the player, camera and threats (they move), the
## interactables that are new or changed state, and the ids removed since the last update.
func _state_payload(obs: Dictionary, present: Dictionary, mode: String) -> Dictionary:
	var current := {}
	for it in present.get("interactables", []):
		current[it.id] = it.get("state", "")
	var p := {"mode": mode}
	for k in ["player", "camera", "threats", "truncated"]:
		if obs.has(k):
			p[k] = obs[k]
	if mode == "full":
		for k in ["interactables", "entities"]:
			if obs.has(k):
				p[k] = obs[k]
	else:
		var removed: Array = _last_states.keys().filter(func(id): return not current.has(id))
		removed.sort()
		if not removed.is_empty():
			p.removed = {"interactables": removed}
		var changed: Array = obs.get("interactables", []).filter(
			func(it): return not _last_states.has(it.id) or _last_states[it.id] != current[it.id])
		if not changed.is_empty():
			p.interactables = changed
	_last_states = current
	return p


## The full observation for a filter (no size cap).
func observe(filter: Dictionary) -> Dictionary:
	var sections: Array = filter.get("sections", SECTIONS)
	var radius := float(filter.get("radius", DEFAULT_RADIUS))
	var max_n := int(filter.get("max_n", DEFAULT_MAX_N))
	var types: Array = filter.get("entity_types", [])
	var player := _player_node()
	var origin := _position(player) if player else _camera_position()
	var obs := {}
	if "player" in sections and player:
		obs.player = _player(player)
	if "camera" in sections:
		var cam := _camera()
		if not cam.is_empty():
			obs.camera = cam
	for section in GROUPS:
		if not section in sections:
			continue
		var items := []
		for node in sdk.get_tree().get_nodes_in_group(GROUPS[section]):
			if node == player:
				continue
			var item := _item(section, node, origin)
			if item.distance <= radius and (types.is_empty() or item.get("type", "") in types):
				items.append(item)
		items.sort_custom(func(a, b): return a.distance < b.distance)
		obs[section] = items.slice(0, max_n)
	return obs


func _player_node() -> Node:
	var players := sdk.get_tree().get_nodes_in_group("player")
	return players[0] if not players.is_empty() else null


func _player(node: Node) -> Dictionary:
	var info := _info(node)
	var flags: Array = []
	if (node is CharacterBody3D or node is CharacterBody2D) and node.is_on_floor():
		flags.append("is_grounded")
	for f in info.get("state_flags", []):
		if not str(f) in flags:
			flags.append(str(f))
	var p := {"position": _vec(_position(node)), "velocity": _vec(_velocity(node)), "state_flags": flags}
	if info.has("health"):
		p.health = float(info.health)
	var scene := _scene_of(node)
	if not scene.is_empty():
		p.scene = scene
	return p


## The scene file the player is in: the current scene, else the scene that owns the player node.
func _scene_of(node: Node) -> String:
	var current := sdk.get_tree().current_scene
	if current and current.is_ancestor_of(node) and not current.scene_file_path.is_empty():
		return current.scene_file_path
	if node.owner and not node.owner.scene_file_path.is_empty():
		return node.owner.scene_file_path
	return ""


func _item(section: String, node: Node, origin: Vector3) -> Dictionary:
	var info := _info(node)
	var pos := _position(node)
	var item := {"id": _id(node, info), "position": _vec(pos), "distance": snappedf(pos.distance_to(origin), 0.001)}
	match section:
		"interactables":
			item.type = str(info.get("type", "interactable"))
			for k in INTERACTABLE_KEYS.slice(1):
				if info.has(k):
					item[k] = info[k]
		"threats":
			for k in THREAT_KEYS:
				if info.has(k):
					item[k] = info[k]
		"entities":
			item.type = str(info.get("type", node.get_class().to_lower()))
			var props := info.duplicate()
			props.erase("id")
			props.erase("type")
			item.properties = props
	return item


func _info(node: Node) -> Dictionary:
	if node.has_method("glitchscout_observe"):
		var v: Variant = node.call("glitchscout_observe")
		if v is Dictionary:
			return v
	return {}


func _id(node: Node, info: Dictionary) -> String:
	if info.has("id"):
		return str(info.id)
	var scene := sdk.get_tree().current_scene
	return str(scene.get_path_to(node)) if scene and scene.is_ancestor_of(node) else str(node.get_path())


func _camera() -> Dictionary:
	var vp := sdk.get_viewport()
	var mode := str(ProjectSettings.get_setting("glitchscout/camera_mode", "third_person"))
	var cam3 := vp.get_camera_3d()
	if cam3:
		mode = str(_info(cam3).get("mode", mode))
		var r := cam3.global_rotation_degrees
		return {"position": _vec(cam3.global_position), "yaw": snappedf(r.y, 0.001), "pitch": snappedf(r.x, 0.001), "mode": mode}
	var cam2 := vp.get_camera_2d()
	if cam2:
		return {"position": _vec(Vector3(cam2.global_position.x, cam2.global_position.y, 0)), "yaw": 0.0, "pitch": 0.0, "mode": "2d"}
	return {}


func _camera_position() -> Vector3:
	var cam3 := sdk.get_viewport().get_camera_3d()
	return cam3.global_position if cam3 else Vector3.ZERO


func _position(node: Node) -> Vector3:
	if node is Node3D:
		return node.global_position
	if node is Node2D:
		return Vector3(node.global_position.x, node.global_position.y, 0)
	return Vector3.ZERO


func _velocity(node: Node) -> Vector3:
	if node is CharacterBody3D:
		return node.velocity
	if node is RigidBody3D:
		return node.linear_velocity
	if node is CharacterBody2D:
		return Vector3(node.velocity.x, node.velocity.y, 0)
	if node is RigidBody2D:
		return Vector3(node.linear_velocity.x, node.linear_velocity.y, 0)
	var v: Variant = _info(node).get("velocity")
	return v if v is Vector3 else Vector3.ZERO


func _vec(v: Vector3) -> Dictionary:
	return {"x": snappedf(v.x, 0.0001), "y": snappedf(v.y, 0.0001), "z": snappedf(v.z, 0.0001)}
