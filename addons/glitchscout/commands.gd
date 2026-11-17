extends RefCounted
## COMMAND: the allowlisted debug-command registry.
##
## Only commands the game registered, plus the SDK's built-ins, can run; anything else is refused with
## unknown_command. The registry is class-level, so a game registers through the Glitchscout autoload:
##
##   var gs := get_node_or_null("/root/Glitchscout")  # null in a build without the addon
##   if gs: gs.register_command("give_item", _give_item, "Adds items", {"item": "string", "count": "int"})
##
## A handler takes the command's args Dictionary and returns null or true (done), a Dictionary (done; sent
## back as result.value) or a String (refused with that message as invalid_args).
##
## Built-ins, which a game registration of the same name replaces: load_scene {scene}, set_seed {seed},
## time_scale {scale}, teleport {position} (moves the player and stops it), scene_groups (the node groups
## in the tree with their sizes) and player_candidates (the nodes that look like the player). The last two
## are read-only: gscout doctor uses them to suggest what to mark, and nothing is marked by guessing.

const Observation := preload("observe.gd")
const BUILTINS := {
	"load_scene": {"description": "Changes to a scene (res:// path)", "params": {"scene": "string"}},
	"set_seed": {"description": "Seeds the global random number generator", "params": {"seed": "int"}},
	"time_scale": {"description": "Sets Engine.time_scale", "params": {"scale": "number"}},
	"teleport": {"description": "Moves the player to a position", "params": {"position": "vec3"}},
	"scene_groups": {"description": "Lists the node groups in the scene with their sizes"},
	"player_candidates": {"description": "Lists the nodes that look like the player, likeliest first"},
}
const MAX_PLAYER_CANDIDATES := 20

static var _registry := {} ## name -> {handler, description, params}

var sdk: Node


func _init(owner: Node) -> void:
	sdk = owner


static func register(name: String, handler: Callable, description := "", params := {}) -> void:
	_registry[name] = {"handler": handler, "description": description, "params": params}


static func unregister(name: String) -> void:
	_registry.erase(name)


## Names of the commands that can run now (registered handlers still alive, plus built-ins).
static func names() -> Array:
	var out: Array = BUILTINS.keys()
	for name in _registry:
		if _registry[name].handler.is_valid() and not name in out:
			out.append(name)
	return out


## The manifest's commands list.
static func descriptors() -> Array:
	var out := []
	for name in names():
		var entry: Dictionary = _registry[name] if _registry.has(name) and _registry[name].handler.is_valid() else BUILTINS[name]
		var d := {"name": name}
		if not str(entry.get("description", "")).is_empty():
			d.description = entry.description
		if not entry.get("params", {}).is_empty():
			d.params = entry.params
		out.append(d)
	return out


func on_command(msg: Dictionary) -> void:
	var name := str(msg.payload.get("name", ""))
	var args: Dictionary = msg.payload.get("args", {}) if msg.payload.get("args") is Dictionary else {}
	var outcome: Variant
	if _registry.has(name) and _registry[name].handler.is_valid():
		outcome = _registry[name].handler.call(args)
	elif BUILTINS.has(name):
		outcome = call("_builtin_" + name, args)
	else:
		_registry.erase(name) # a freed handler
		sdk.reply_error(msg, "unknown_command", "no command '%s' (registered: %s)" % [name, ", ".join(names())])
		return
	if outcome is String:
		sdk.reply_error(msg, "invalid_args", outcome)
	elif outcome is Dictionary:
		# Game data: make it JSON-safe (vectors, non-finite numbers) before it goes on the wire.
		sdk.reply(msg, "ACK", {"result": {"value": Observation._clean(outcome), "tick_frame": sdk.tick}})
	else:
		sdk.reply(msg, "ACK", {"result": {"tick_frame": sdk.tick}})


func _builtin_load_scene(args: Dictionary) -> Variant:
	var scene := str(args.get("scene", ""))
	if not scene.begins_with("res://") or not ResourceLoader.exists(scene, "PackedScene"):
		return "no scene at '%s'" % scene
	return null if sdk.change_scene_now(scene) else "can't change to %s" % scene


func _builtin_set_seed(args: Dictionary) -> Variant:
	if not (args.get("seed") is float or args.get("seed") is int):
		return "set_seed needs a numeric seed"
	seed(int(args.seed))
	return null


func _builtin_time_scale(args: Dictionary) -> Variant:
	var scale: Variant = args.get("scale")
	if not (scale is float or scale is int) or float(scale) < 0.0:
		return "time_scale needs a scale >= 0"
	if sdk.time_mode == "step" and not is_equal_approx(float(scale), 1.0):
		return "time_scale would break step mode's one physics tick per frame; it needs --glitchscout-time=realtime"
	Engine.time_scale = float(scale)
	return null


func _builtin_scene_groups(_args: Dictionary) -> Variant:
	var counts := {}
	var pending: Array[Node] = [sdk.get_tree().root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		for g in node.get_groups():
			var name := str(g)
			if not name.begins_with("_"): # Godot's own
				counts[name] = int(counts.get(name, 0)) + 1
		pending.append_array(node.get_children())
	var names := counts.keys()
	names.sort()
	return {"groups": names.map(func(n): return {"name": n, "count": counts[n]})}


## The nodes a game would most likely put in the "player" group: 2D and 3D nodes called "player" (in the node's
## name or its script's path, "multiplayer" aside), then CharacterBody nodes, in tree order within each. Engine nodes
## that only have "player" in their class (AudioStreamPlayer2D) aren't candidates. Each is {path, class, script?}, and
## the list stops at MAX_PLAYER_CANDIDATES.
func _builtin_player_candidates(_args: Dictionary) -> Variant:
	var ranked := [[], [], []] # called player and a body, called player, a body
	var pending: Array[Node] = [sdk.get_tree().root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		var children := node.get_children()
		children.reverse() # so the stack gives them back in tree order
		pending.append_array(children)
		if not (node is Node2D or node is Node3D) or node.get_class().containsn("player"):
			continue
		var script: Script = node.get_script()
		var script_path := script.resource_path if script else ""
		var named := _says_player(str(node.name)) or _says_player(script_path)
		var body := node is CharacterBody2D or node is CharacterBody3D
		if not (named or body):
			continue
		var candidate := {"path": str(node.get_path()), "class": node.get_class()}
		if not script_path.is_empty():
			candidate.script = script_path
		ranked[0 if named and body else 1 if named else 2].append(candidate)
	return {"candidates": (ranked[0] + ranked[1] + ranked[2]).slice(0, MAX_PLAYER_CANDIDATES)}


## Whether a node name or script path has "player" in it, other than as part of "multiplayer".
static func _says_player(text: String) -> bool:
	return text.to_lower().replace("multiplayer", "").contains("player")


func _builtin_teleport(args: Dictionary) -> Variant:
	var pos: Variant = args.get("position")
	if not pos is Dictionary:
		return "teleport needs a position"
	var players := sdk.get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return "there is no player (group 'player') to teleport"
	var p: Node = players[0]
	var v := Vector3(float(pos.get("x", 0)), float(pos.get("y", 0)), float(pos.get("z", 0)))
	if p is Node3D:
		p.global_position = v
	elif p is Node2D:
		p.global_position = Vector2(v.x, v.y)
	else:
		return "the player isn't a Node2D or Node3D"
	if "velocity" in p:
		p.velocity = Vector3.ZERO if p is Node3D else Vector2.ZERO
	if "linear_velocity" in p:
		p.linear_velocity = Vector3.ZERO if p is Node3D else Vector2.ZERO
	return null
