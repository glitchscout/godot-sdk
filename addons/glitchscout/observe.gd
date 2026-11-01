extends RefCounted
## OBSERVE / OBSERVATION and the STATE_UPDATE stream, with interest management.
##
## What the game exposes (plan §5.1):
## - the player: the first node in group "player";
## - interactables: group "glitchscout_interactable";
##   an interactable also in "glitchscout_collectible" or "glitchscout_pushable" has affordance collect or push;
## - threats: group "glitchscout_threat";
## - hazards: group "glitchscout_hazard" (glitchscout_observe() must give a radius; damage is optional);
## - other observable entities: group "glitchscout_observable".
## Each node may define glitchscout_observe() -> Dictionary with its fields ("id" overrides the node path).
## The SDK computes distances from the player, sorts by distance, filters by radius, type and max_n, and
## truncates by distance to fit the text-frame cap (default 256 KB), flagging truncated: true.
##
## After an interaction (an injected press of an action some interactable requires, "interact" or ui_accept),
## interactables and entities whose state, enabled or collision then changes stay in view at any distance
## for glitchscout/interaction_delta_ticks ticks (default 120), so what a lever opened far away is seen.

const DEFAULT_RADIUS := 500.0
const DEFAULT_MAX_N := 10000
const DEFAULT_INTERACTION_TICKS := 120
const GROUPS := {
	"interactables": "glitchscout_interactable",
	"threats": "glitchscout_threat",
	"hazards": "glitchscout_hazard",
	"entities": "glitchscout_observable",
}
const AFFORDANCE_GROUPS := {"glitchscout_collectible": "collect", "glitchscout_pushable": "push"}
const AFFORDANCES := ["interact", "collect", "push"]
const INTERACTABLE_KEYS := ["type", "state", "enabled", "required_action", "interaction_range", "requires"]
const THREAT_KEYS := ["type", "health", "attack_range", "state"]
const SECTIONS := ["player", "interactables", "camera", "threats", "hazards", "ui_elements", "entities"]
const WATCHED := ["state", "enabled", "collision"] ## facts an interaction can change
const WATCHED_SECTIONS := ["interactables", "entities"]

var sdk: Node

var _stream_hz := 0.0
var _stream_filter := {}
var _stream_due := 0
var _streamed := false
var _last_states := {} ## interactable id -> state at the last STATE_UPDATE
var _last_hazards := {} ## hazard ids at the last STATE_UPDATE
var _warned_too_large := false
var _warned_hazard := false
var _window_until := -1 ## last tick of the post-interaction window
var _window_facts := {} ## section -> {id -> watched facts} when the window opened
var _effects := {} ## ids of the entities the last observe() found changed in the window
var _last_effects := {} ## those ids at the last STATE_UPDATE
var _actions := {} ## the actions interactables require, as of _actions_tick
var _actions_tick := -1


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
	var text := _fit("OBSERVATION", p, msg.get("id"), "")
	if text.is_empty():
		sdk.reply_error(msg, "observation_too_large", "the observation doesn't fit in %d bytes even with every entity cut; narrow sections or raise max_bytes" % int(p.get("max_bytes", sdk.MAX_TEXT_FRAME_BYTES)))
		return
	sdk.send_text(text)


## Called at the start of every game frame: sends a STATE_UPDATE when one is due.
func frame_start() -> void:
	if _stream_hz <= 0.0 or sdk.tick < _stream_due:
		return
	var text := _fit("STATE_UPDATE", _stream_filter, null, "delta" if _streamed else "full")
	if text.is_empty():
		if not _warned_too_large:
			_warned_too_large = true
			push_warning("Glitchscout: a STATE_UPDATE didn't fit the text-frame cap and was skipped")
	else:
		sdk.send_text(text)
	_streamed = true
	_stream_due = sdk.tick + maxi(1, roundi(Engine.physics_ticks_per_second / _stream_hz))


## Called for every press the SDK injects: one that interacts opens (or extends) the post-interaction window.
func note_press(action: String) -> void:
	if not _interacts(action):
		return
	if sdk.tick > _window_until:
		_window_facts = {}
		for section in WATCHED_SECTIONS:
			_window_facts[section] = {}
			for node in sdk.get_tree().get_nodes_in_group(GROUPS[section]):
				var info := _info(node)
				_window_facts[section][_id(node, info)] = _facts(info)
	var ticks := int(ProjectSettings.get_setting("glitchscout/interaction_delta_ticks", DEFAULT_INTERACTION_TICKS))
	_window_until = sdk.tick + maxi(0, ticks)


func _interacts(action: String) -> bool:
	if action in ["interact", "ui_accept"]:
		return true
	if _actions_tick != sdk.tick: # once per tick: movement presses arrive on most ticks
		_actions_tick = sdk.tick
		_actions = {}
		for node in sdk.get_tree().get_nodes_in_group(GROUPS.interactables):
			_actions[str(_info(node).get("required_action", ""))] = true
	return _actions.has(action)


static func _facts(info: Dictionary) -> Dictionary:
	var out := {}
	for k in WATCHED:
		if info.has(k):
			out[k] = str(info[k])
	return out


## Whether a node changed a watched fact since the window opened (false outside the window).
func _changed_in_window(section: String, node: Node) -> bool:
	if sdk.tick > _window_until:
		return false
	var info := _info(node)
	var before: Variant = _window_facts.get(section, {}).get(_id(node, info))
	return before != null and before != _facts(info)


## Entity types present in the scene now, for the manifest.
func entity_types() -> Array[String]:
	var seen: Array[String] = []
	for section in GROUPS:
		for node in sdk.get_tree().get_nodes_in_group(GROUPS[section]):
			var t := str(_info(node).get("type", ""))
			if not t.is_empty() and not t in seen:
				seen.append(t)
	return seen


## Encodes an OBSERVATION or STATE_UPDATE, dropping the farthest entities, then interactables, then threats,
## then (in tree order) UI elements, until it fits the cap. Returns "" when even that isn't enough (never an oversized frame).
func _fit(message_type: String, filter: Dictionary, reply_to: Variant, mode: String) -> String:
	var cap := int(filter.get("max_bytes", sdk.MAX_TEXT_FRAME_BYTES))
	var present := observe(filter)
	var obs := present.duplicate()
	var saved := [_last_states.duplicate(), _last_hazards.duplicate(), _last_effects.duplicate()]
	var build := func() -> String:
		if mode.is_empty():
			return sdk.encode(message_type, obs, reply_to)
		# each attempt diffs against the last update, not the last attempt
		_last_states = saved[0].duplicate()
		_last_hazards = saved[1].duplicate()
		_last_effects = saved[2].duplicate()
		return sdk.encode(message_type, _state_payload(obs, present, mode), reply_to)
	var text: String = build.call()
	while text.to_utf8_buffer().size() > cap:
		obs.truncated = true
		var cut := false
		for section in ["entities", "interactables", "hazards", "threats", "ui_elements"]: # UI last: it's not by distance
			var arr: Array = obs.get(section, [])
			if not arr.is_empty():
				obs[section] = arr.slice(0, arr.size() * 9 / 10)
				cut = true
				break
		if not cut:
			return ""
		text = build.call()
	return text


## A STATE_UPDATE: full sends everything; delta sends the player, camera, threats and hazards (they move),
## the interactables that are new or changed state, the entities an interaction changed, and the ids
## removed since the last update.
func _state_payload(obs: Dictionary, present: Dictionary, mode: String) -> Dictionary:
	var current := {}
	for it in present.get("interactables", []):
		current[it.id] = it.get("state", "")
	var hazards := {}
	for h in present.get("hazards", []):
		hazards[h.id] = true
	var p := {"mode": mode}
	for k in ["player", "camera", "threats", "hazards", "ui_elements", "truncated"]:
		if obs.has(k):
			p[k] = obs[k]
	if mode == "full":
		for k in ["interactables", "entities"]:
			if obs.has(k):
				p[k] = obs[k]
	else:
		var removed := {}
		var gone: Array = _last_states.keys().filter(func(id): return not current.has(id))
		if not gone.is_empty():
			gone.sort()
			removed.interactables = gone
		var gone_hazards: Array = _last_hazards.keys().filter(func(id): return not hazards.has(id))
		if not gone_hazards.is_empty():
			gone_hazards.sort()
			removed.hazards = gone_hazards
		var in_view := {}
		for e in present.get("entities", []):
			in_view[e.id] = true
		var gone_effects: Array = _last_effects.keys().filter(func(id): return not in_view.has(id))
		if not gone_effects.is_empty():
			gone_effects.sort()
			removed.entities = gone_effects
		if not removed.is_empty():
			p.removed = removed
		var changed: Array = obs.get("interactables", []).filter(
			func(it): return not _last_states.has(it.id) or _last_states[it.id] != current[it.id])
		if not changed.is_empty():
			p.interactables = changed
		var effects: Array = obs.get("entities", []).filter(func(e): return _effects.has(e.id))
		if not effects.is_empty():
			p.entities = effects
	_last_states = current
	_last_hazards = hazards
	_last_effects = _effects.duplicate()
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
		obs.player = _player(player, _info(player))
	if "camera" in sections:
		var cam := _camera()
		if not cam.is_empty():
			obs.camera = cam
	if "ui_elements" in sections:
		obs.ui_elements = sdk.ui_elements()
	_effects = {}
	for section in GROUPS:
		if not section in sections:
			continue
		var items := []
		var effects := [] # changed by an interaction: in view at any distance
		for node in sdk.get_tree().get_nodes_in_group(GROUPS[section]):
			if node == player:
				continue
			var item := _item(section, node, origin)
			if item.is_empty() or not (types.is_empty() or item.get("type", "") in types):
				continue
			var changed: bool = section in WATCHED_SECTIONS and _changed_in_window(section, node)
			if changed and section == "entities":
				_effects[item.id] = true
			if item.distance <= radius:
				items.append(item)
			if changed:
				effects.append(item)
		items.sort_custom(func(a, b): return a.distance < b.distance)
		items = items.slice(0, max_n)
		effects = effects.filter(func(e): return not items.has(e)) # the ones the radius or max_n cut
		if not effects.is_empty():
			effects.sort_custom(func(a, b): return a.distance < b.distance)
			items.append_array(effects)
		if section == "hazards": # sorted by it, but the protocol's hazard has no distance
			for item in items:
				item.erase("distance")
		obs[section] = items
	return obs


## A node's glitchscout id: its own (metadata glitchscout_id, glitchscout_observe().id) or that of its
## nearest ancestor in an observation group, else its node path.
func entity_id(node: Node) -> String:
	var n := node
	while n != null:
		if n.has_meta("glitchscout_id"):
			return str(n.get_meta("glitchscout_id"))
		var info := _info(n)
		if info.has("id"):
			return str(info.id)
		if n.is_in_group("player") or GROUPS.values().any(func(g): return n.is_in_group(g)):
			return _id(n, info)
		n = n.get_parent()
	return _id(node, {})


## Every observable entity as {id, type, position} (no filters).
func all_entities() -> Array:
	var out := []
	var defaults := {"interactables": "interactable", "threats": "threat"}
	for section in GROUPS:
		for node in sdk.get_tree().get_nodes_in_group(GROUPS[section]):
			var info := _info(node)
			var fallback: String = defaults.get(section, node.get_class().to_lower()) # as OBSERVE reports them
			out.append({"id": _id(node, info), "type": _text(info.get("type"), fallback), "position": _vec(_position(node))})
	return out


func _player_node() -> Node:
	var players := sdk.get_tree().get_nodes_in_group("player")
	return players[0] if not players.is_empty() else null


func _player(node: Node, info: Dictionary) -> Dictionary:
	var flags: Array = []
	if (node is CharacterBody3D or node is CharacterBody2D) and node.is_on_floor():
		flags.append("is_grounded")
	for f in info.get("state_flags", []):
		if not str(f) in flags:
			flags.append(str(f))
	var p := {"position": _vec(_position(node)), "velocity": _vec(_velocity(node, info)), "state_flags": flags}
	var health: Variant = _num(info.get("health"))
	if health != null:
		p.health = health
	var scene := _scene_of(node)
	if not scene.is_empty():
		p.scene = scene
	return p


## The scene file the player is in: the outermost scene that owns the player node (so a level loaded under
## a persistent root reports itself, and a player inside a sub-scene of a level reports the level), else
## the current scene.
func _scene_of(node: Node) -> String:
	var path := ""
	var o := node.owner
	while o:
		if not o.scene_file_path.is_empty():
			path = o.scene_file_path
		o = o.owner
	if not path.is_empty():
		return path
	var current := sdk.get_tree().current_scene
	if current and current.is_ancestor_of(node) and not current.scene_file_path.is_empty():
		return current.scene_file_path
	return ""


func _item(section: String, node: Node, origin: Vector3) -> Dictionary:
	var info := _info(node)
	var pos := _position(node)
	var item := {"id": _id(node, info), "position": _vec(pos), "distance": snappedf(pos.distance_to(origin), 0.001)}
	# Game values are coerced to the schema's types: a game's own enums, strings and NaNs must not make the
	# message invalid (or not JSON at all).
	match section:
		"interactables":
			item.type = _text(info.get("type"), "interactable")
			_put_text(item, "state", info.get("state"))
			if info.has("enabled"):
				item.enabled = _truthy(info.enabled)
			_put_text(item, "required_action", info.get("required_action"))
			_put_num(item, "interaction_range", info.get("interaction_range"), true)
			if info.get("requires") is Array:
				item.requires = info.requires.map(func(r): return str(r)).filter(func(r): return not r.is_empty())
			var affordance := str(info.get("affordance", ""))
			if affordance.is_empty():
				for group in AFFORDANCE_GROUPS:
					if node.is_in_group(group):
						affordance = AFFORDANCE_GROUPS[group]
			if affordance in AFFORDANCES and affordance != "interact": # interact is the default
				item.affordance = affordance
		"hazards":
			var radius: Variant = _num(info.get("radius"))
			if radius == null or radius < 0.0:
				if not _warned_hazard:
					_warned_hazard = true
					push_warning("Glitchscout: hazard %s has no radius in glitchscout_observe(); it is left out" % item.id)
				return {}
			item.radius = radius
			_put_text(item, "type", info.get("type"))
			_put_num(item, "damage", info.get("damage"), true)
			var v := _velocity(node, info)
			if v != Vector3.ZERO:
				item.velocity = _vec(v)
		"threats":
			_put_text(item, "type", info.get("type"))
			_put_num(item, "health", info.get("health"), false)
			_put_num(item, "attack_range", info.get("attack_range"), true)
			_put_text(item, "state", info.get("state"))
		"entities":
			item.type = _text(info.get("type"), node.get_class().to_lower())
			var props := info.duplicate()
			props.erase("id")
			props.erase("type")
			item.properties = _clean(props)
	return item


static func _num(v: Variant) -> Variant:
	var f := NAN
	if v is int or v is float:
		f = float(v)
	elif v is String and v.is_valid_float():
		f = v.to_float()
	return f if is_finite(f) else null


static func _text(v: Variant, default: String) -> String:
	var s := str(v) if v != null else ""
	return s if not s.is_empty() else default


static func _truthy(v: Variant) -> bool:
	if v is String:
		return not v.to_lower() in ["", "false", "0", "no", "off"]
	return bool(v) if (v is bool or v is int or v is float) else v != null


static func _put_text(item: Dictionary, key: String, v: Variant) -> void:
	var s := _text(v, "")
	if not s.is_empty():
		item[key] = s


static func _put_num(item: Dictionary, key: String, v: Variant, non_negative: bool) -> void:
	var n: Variant = _num(v)
	if n != null and (not non_negative or n >= 0.0):
		item[key] = n


## Makes arbitrary game data JSON-safe: non-finite numbers become null, vectors become {x, y, z}, other
## objects become strings.
static func _clean(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return v if is_finite(v) else null
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[str(k)] = _clean(v[k])
			return out
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			return Array(v).map(func(e): return _clean(e))
		TYPE_VECTOR2:
			return {"x": _clean(v.x), "y": _clean(v.y)}
		TYPE_VECTOR3:
			return {"x": _clean(v.x), "y": _clean(v.y), "z": _clean(v.z)}
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
	return str(v)


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


func _velocity(node: Node, info: Dictionary) -> Vector3:
	if node is CharacterBody3D:
		return node.velocity
	if node is RigidBody3D:
		return node.linear_velocity
	if node is CharacterBody2D:
		return Vector3(node.velocity.x, node.velocity.y, 0)
	if node is RigidBody2D:
		return Vector3(node.linear_velocity.x, node.linear_velocity.y, 0)
	var v: Variant = info.get("velocity")
	return v if v is Vector3 else Vector3.ZERO


func _vec(v: Vector3) -> Dictionary:
	return {"x": snappedf(v.x, 0.0001), "y": snappedf(v.y, 0.0001), "z": snappedf(v.z, 0.0001)}
