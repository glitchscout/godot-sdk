extends Node
## The fixture game's root: it opens on the main menu, and "new game" swaps the menu for the first level.
## It registers the standard Glitchscout debug commands for itself (set_flag, god_mode, give_item,
## set_time, load_save; teleport is the SDK's built-in).

const MENU := preload("res://fixture/ui/main_menu.tscn")
const FIRST_LEVEL := "res://fixture/levels/flat.tscn"
const SAVE_SLOT := "res://fixture/saves/%s.json"
const COMMANDS := ["set_flag", "god_mode", "give_item", "set_time", "load_save"]

var state := "menu"
var flags := {}
var inventory := {}
var clock := 8.0 ## time of day, hours
var god_mode := false

var _level: Node


func _ready() -> void:
	var menu := MENU.instantiate()
	menu.new_game.connect(_start_new_game)
	add_child(menu)
	# Through the node, not the class, so a release build without the addon still runs.
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		gs.register_command("set_flag", _set_flag, "Sets a story flag", {"name": "string", "value": "any"})
		gs.register_command("god_mode", _god_mode, "Makes the player invulnerable", {"enabled": "bool"})
		gs.register_command("give_item", _give_item, "Adds items to the inventory", {"item": "string", "count": "int"})
		gs.register_command("set_time", _set_time, "Sets the time of day in hours", {"time": "number"})
		gs.register_command("load_save", _load_save, "Loads a save fixture by slot or path", {"slot": "string", "path": "string"})
		gs.set_reset_handler(reset)


func _exit_tree() -> void:
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		for name in COMMANDS:
			gs.unregister_command(name)
		gs.set_reset_handler(Callable())


func player() -> Node3D:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if not players.is_empty() and is_ancestor_of(players[0]) else null


func _start_new_game() -> void:
	if state != "menu":
		return
	get_node("MainMenu").queue_free()
	_level = load(FIRST_LEVEL).instantiate()
	add_child(_level)
	state = "playing"
	_apply_god_mode()


## Reset tier 1: a fresh copy of the current level and cleared game state (what RELOAD_SCENE does here,
## since this root node outlives its levels).
func reset() -> void:
	flags.clear()
	inventory.clear()
	clock = 8.0
	if _level:
		remove_child(_level)
		_level.queue_free()
		_level = load(FIRST_LEVEL).instantiate()
		add_child(_level)
	_apply_god_mode()


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


func _load_save(args: Dictionary) -> Variant:
	var path := str(args.get("path", SAVE_SLOT % str(args.get("slot", ""))))
	if not FileAccess.file_exists(path):
		return "no save at %s" % path
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		return "%s is not a valid save" % path
	_start_new_game()
	flags = data.get("flags", {}).duplicate()
	inventory = data.get("inventory", {}).duplicate()
	var pos: Variant = data.get("player_position")
	if pos is Array and pos.size() == 3 and player():
		player().global_position = Vector3(pos[0], pos[1], pos[2])
	return {"loaded": path}
