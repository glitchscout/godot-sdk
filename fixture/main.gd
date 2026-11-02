extends Node
## The fixture game's root: it opens on the main menu, and "new game" swaps the menu for the first level.
## It registers the standard Glitchscout debug commands for itself (set_flag, god_mode, give_item,
## set_time, save_game, load_save; teleport is the SDK's built-in), load_scene by level name, and fault
## commands that produce every result category a Glitchscout run can end in. Its flags and inventory are
## observed as the game_state entity, so a save that loses them can be caught.
##
##   crash_now {after_frames}, hang {after_frames}  the process crashes, or stops answering
##   log_error                                      a real GDScript error on the next frame
##   leak_memory {mb_per_second}                    allocates and keeps memory (0 releases it)
##   drop_connection {after_frames}                 closes the SDK's socket; the SDK reconnects and resumes
##   send_malformed                                 sends the orchestrator a message that breaks the protocol
##   slow_frames {ms}                               every frame takes at least ms (0 stops it)
##   softlock_door                                  the next door opened jams shut
##   corrupt_save {flag}                            the next save_game leaves out that flag
##   trap_focus                                     the menu's Options opens a panel focus can't leave

const MENU := preload("res://fixture/ui/main_menu.tscn")
const FIRST_LEVEL := "res://fixture/levels/flat.tscn"
const LEVELS := {"flat": FIRST_LEVEL, "course": "res://fixture/levels/course.tscn"}
const SAVE_SLOT := "res://fixture/saves/%s.json"
const USER_SLOT := "user://glitchscout_saves/%s.json" ## where save_game writes; load_save looks here second
const COMMANDS := [
	"set_flag", "god_mode", "give_item", "set_time", "save_game", "load_save", "load_scene",
	"crash_now", "hang", "log_error", "leak_memory", "drop_connection", "send_malformed", "slow_frames", "softlock_door",
	"corrupt_save", "trap_focus",
]

var state := "menu"
var flags := {}
var inventory := {}
var clock := 8.0 ## time of day, hours
var god_mode := false

var _level: Node
var _level_path := FIRST_LEVEL

# Faults.
var crash_in := -1 ## physics frames until crash_now fires
var hang_in := -1
var drop_in := -1
var slow_ms := 0
var jam_next_door := false
var drop_flag_on_save := "" ## corrupt_save: the flag the next save leaves out
var trap_focus := false
var leaked_bytes := 0
var _leak_per_second := 0
var _leaked: Array[PackedByteArray] = []
## Tests stand a fake socket in for the SDK's.
var socket_override: Variant = null


func _ready() -> void:
	add_to_group("fixture_game")
	add_to_group("glitchscout_observable")
	_show_menu()
	# Through the node, not the class, so a release build without the addon still runs.
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		gs.register_command("set_flag", _set_flag, "Sets a story flag", {"name": "string", "value": "any"})
		gs.register_command("god_mode", _god_mode, "Makes the player invulnerable", {"enabled": "bool"})
		gs.register_command("give_item", _give_item, "Adds items to the inventory", {"item": "string", "count": "int"})
		gs.register_command("set_time", _set_time, "Sets the time of day in hours", {"time": "number"})
		gs.register_command("save_game", _save_game, "Saves the game to a slot", {"slot": "string"})
		gs.register_command("load_save", _load_save, "Loads a save by slot or path", {"slot": "string", "path": "string"})
		gs.register_command("load_scene", _load_scene, "Loads a level by name: menu, flat or course", {"scene": "string"})
		gs.register_command("crash_now", _crash_now, "Fault: crash the process", {"after_frames": "int"})
		gs.register_command("hang", _hang, "Fault: stop answering", {"after_frames": "int"})
		gs.register_command("log_error", _log_error, "Fault: a GDScript error on the next frame")
		gs.register_command("leak_memory", _leak_memory, "Fault: keep allocating memory", {"mb_per_second": "number"})
		gs.register_command("drop_connection", _drop_connection, "Fault: drop the Glitchscout connection", {"after_frames": "int"})
		gs.register_command("send_malformed", _send_malformed, "Fault: send a message that breaks the protocol")
		gs.register_command("slow_frames", _slow_frames, "Fault: make every frame slow", {"ms": "int"})
		gs.register_command("softlock_door", _softlock_door, "Fault: the next door opened jams shut")
		gs.register_command("corrupt_save", _corrupt_save, "Fault: the next save leaves out a flag", {"flag": "string"})
		gs.register_command("trap_focus", _trap_focus, "Fault: the menu's Options opens a panel focus can't leave")
		gs.set_reset_handler(reset)


func _exit_tree() -> void:
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		for name in COMMANDS:
			gs.unregister_command(name)
		gs.set_reset_handler(Callable())


## The game state Glitchscout sees: flags and inventory, as the game_state entity.
func glitchscout_observe() -> Dictionary:
	return {"id": "game_state", "type": "game_state", "flags": flags.duplicate(), "inventory": inventory.duplicate()}


func player() -> Node3D:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if not players.is_empty() and is_ancestor_of(players[0]) else null


func _show_menu() -> void:
	var menu := MENU.instantiate()
	menu.new_game.connect(_start_new_game)
	menu.trap_focus = trap_focus
	add_child(menu)
	state = "menu"


func _start_new_game() -> void:
	if state != "menu":
		return
	_enter_level(FIRST_LEVEL)


func level_name() -> String:
	if state == "menu":
		return "menu"
	for level in LEVELS:
		if LEVELS[level] == _level_path:
			return level
	return _level_path


## Replaces the menu or the current level with a fresh copy of the level at path.
func _enter_level(path: String) -> void:
	var menu := get_node_or_null("MainMenu")
	if menu:
		remove_child(menu)
		menu.queue_free()
	if _level:
		remove_child(_level)
		_level.queue_free()
	_level_path = path
	_level = load(path).instantiate()
	add_child(_level)
	state = "playing"
	_apply_god_mode()


## Reset tier 1: a fresh copy of the current level, cleared game state and no faults armed (what
## RELOAD_SCENE does here, since this root node outlives its levels).
func reset() -> void:
	flags.clear()
	inventory.clear()
	clock = 8.0
	_disarm_faults()
	if _level:
		_enter_level(_level_path)
	elif state == "menu":
		var menu := get_node_or_null("MainMenu")
		if menu:
			remove_child(menu)
			menu.queue_free()
		_show_menu()


func _set_flag(args: Dictionary) -> Variant:
	if str(args.get("name", "")).is_empty():
		return "set_flag needs a name"
	flags[str(args.name)] = args.get("value", true)
	return null


func _god_mode(args: Dictionary) -> Variant:
	god_mode = bool(args.get("enabled", true))
	_apply_god_mode()
	return null


func _apply_god_mode() -> void:
	var p := player()
	if p:
		p.invulnerable = god_mode


func _give_item(args: Dictionary) -> Variant:
	var item := str(args.get("item", ""))
	if item.is_empty():
		return "give_item needs an item"
	inventory[item] = int(inventory.get(item, 0)) + int(args.get("count", 1))
	return {"count": inventory[item]}


func _set_time(args: Dictionary) -> Variant:
	if not (args.get("time") is float or args.get("time") is int):
		return "set_time needs a numeric time (hours)"
	clock = fposmod(float(args.time), 24.0)
	return null


## Saves what the game keeps: flags, inventory, the level, each interactable's state and the player's
## position and health.
func _save_game(args: Dictionary) -> Variant:
	var slot := str(args.get("slot", ""))
	if slot.is_empty() or not slot.is_valid_filename():
		return "save_game needs a slot (a plain file name)"
	if FileAccess.file_exists(SAVE_SLOT % slot):
		return "%s is a bundled save fixture; save to another slot" % slot
	var saved_flags := flags.duplicate()
	if not drop_flag_on_save.is_empty():
		saved_flags.erase(drop_flag_on_save)
		drop_flag_on_save = ""
	var data := {"flags": saved_flags, "inventory": inventory.duplicate(), "level": level_name(), "interactables": {}}
	for it in _interactables():
		data.interactables[it.id] = it.state
	if player():
		var p := player().global_position
		data.player_position = [p.x, p.y, p.z]
		data.player_health = player().health
	DirAccess.make_dir_recursive_absolute(USER_SLOT.get_base_dir())
	var f := FileAccess.open(USER_SLOT % slot, FileAccess.WRITE)
	if f == null:
		return "can't write %s: %s" % [USER_SLOT % slot, error_string(FileAccess.get_open_error())]
	f.store_string(JSON.stringify(data))
	return {"saved": USER_SLOT % slot}


func _load_save(args: Dictionary) -> Variant:
	var slot := str(args.get("slot", ""))
	# A bundled fixture wins over a slot save_game wrote, so a stray save can't shadow it.
	var path := str(args.get("path", SAVE_SLOT % slot if FileAccess.file_exists(SAVE_SLOT % slot) else USER_SLOT % slot))
	if not FileAccess.file_exists(path):
		return "no save at %s" % path
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		return "%s is not a valid save" % path
	_start_new_game()
	var level := str(data.get("level", ""))
	if LEVELS.has(level) and LEVELS[level] != _level_path:
		_enter_level(LEVELS[level])
	flags = data.get("flags", {}).duplicate()
	inventory = data.get("inventory", {}).duplicate()
	var states: Variant = data.get("interactables", {})
	if states is Dictionary:
		for it in _interactables():
			if states.has(it.id):
				it.state = str(states[it.id])
	var pos: Variant = data.get("player_position")
	if pos is Array and pos.size() == 3 and player():
		player().global_position = Vector3(pos[0], pos[1], pos[2])
	if data.has("player_health") and player():
		player().health = float(data.player_health)
	return {"loaded": path}


## The current level's interactables (not those of a level on its way out).
func _interactables() -> Array:
	if not _level:
		return []
	return get_tree().get_nodes_in_group("glitchscout_interactable").filter(func(n): return _level.is_ancestor_of(n))


func _load_scene(args: Dictionary) -> Variant:
	var level := str(args.get("scene", ""))
	if level == "menu":
		if state != "menu":
			if _level:
				remove_child(_level)
				_level.queue_free()
				_level = null
			_show_menu()
		return null
	if not LEVELS.has(level):
		return "no level %s (menu, %s)" % [level, ", ".join(LEVELS.keys())]
	_enter_level(LEVELS[level])
	return null


# --- faults ----------------------------------------------------------------------------------------------

func _disarm_faults() -> void:
	crash_in = -1
	hang_in = -1
	drop_in = -1
	slow_ms = 0
	jam_next_door = false
	drop_flag_on_save = ""
	trap_focus = false
	_leak_per_second = 0
	_leaked.clear()
	leaked_bytes = 0


func _frames(args: Dictionary) -> int:
	return maxi(1, int(args.get("after_frames", 0))) # at least one frame, so the ACK goes out first


func _crash_now(args: Dictionary) -> Variant:
	crash_in = _frames(args)
	return null


func _hang(args: Dictionary) -> Variant:
	hang_in = _frames(args)
	return null


func _log_error(_args: Dictionary) -> Variant:
	_broken.call_deferred()
	return null


func _broken() -> void:
	var nothing: Variant = null
	nothing.explode() # a real GDScript error, on purpose


func _leak_memory(args: Dictionary) -> Variant:
	_leak_per_second = int(float(args.get("mb_per_second", 0)) * 1024 * 1024)
	if _leak_per_second <= 0:
		_leaked.clear()
		leaked_bytes = 0
	return null


func _drop_connection(args: Dictionary) -> Variant:
	drop_in = _frames(args) if args.has("after_frames") else 30
	if socket_override != null:
		drop_in = -1
		_socket().close()
	return null


func _send_malformed(_args: Dictionary) -> Variant:
	var peer: Variant = _socket()
	if peer == null:
		return "there is no Glitchscout connection"
	# Valid JSON, but no id, session or payload: the orchestrator must drop it and carry on.
	peer.send_text('{"protocol": "glitchscout/1", "message_type": "EVENT", "garbage": true}')
	return null


func _slow_frames(args: Dictionary) -> Variant:
	slow_ms = maxi(0, int(args.get("ms", 0)))
	return null


func _softlock_door(_args: Dictionary) -> Variant:
	jam_next_door = true
	return null


func _corrupt_save(args: Dictionary) -> Variant:
	drop_flag_on_save = str(args.get("flag", ""))
	if drop_flag_on_save.is_empty():
		return "corrupt_save needs the flag to leave out"
	return null


func _trap_focus(_args: Dictionary) -> Variant:
	trap_focus = true
	var menu := get_node_or_null("MainMenu")
	if menu:
		menu.trap_focus = true
	return null


## The SDK's WebSocket (its private _peer: the fixture reaches in on purpose, to break it).
func _socket() -> Variant:
	if socket_override != null:
		return socket_override
	var gs := get_node_or_null("/root/Glitchscout")
	return gs.get("_peer") if gs else null


func _process(_delta: float) -> void:
	if slow_ms > 0:
		OS.delay_msec(slow_ms)


func _physics_process(delta: float) -> void:
	if crash_in > 0:
		crash_in -= 1
		if crash_in == 0:
			OS.crash("fixture: crash_now")
	if hang_in > 0:
		hang_in -= 1
		if hang_in == 0:
			print("fixture: hang")
			while true:
				OS.delay_msec(100)
	if drop_in > 0:
		drop_in -= 1
		if drop_in == 0:
			var peer: Variant = _socket()
			if peer:
				peer.close(1001, "fixture: drop_connection")
	if _leak_per_second > 0:
		var chunk := PackedByteArray()
		chunk.resize(maxi(1, int(_leak_per_second * delta)))
		_leaked.append(chunk)
		leaked_bytes += chunk.size()
