extends Node3D
## The level, and the game state: what the player carries. It registers give_item, a debug command scenarios
## use to set up a test, and shows the inventory to Glitchscout as the game_state entity.

var inventory: Dictionary = {}


func _ready() -> void:
	add_to_group("glitchscout_observable")
	# Through the node, not the class name, so a build without the addon still runs.
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		gs.register_command("give_item", _give_item, "Adds items to the inventory", {"item": "string", "count": "int"})


func _exit_tree() -> void:
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		gs.unregister_command("give_item")


func glitchscout_observe() -> Dictionary:
	return {"id": "game_state", "type": "game_state", "inventory": inventory.duplicate()}


func _give_item(args: Dictionary) -> Variant:
	var item := str(args.get("item", ""))
	if item.is_empty():
		return "give_item needs an item" # a String refuses the command with that message
	inventory[item] = int(inventory.get(item, 0)) + int(args.get("count", 1))
	return null


## Sends a game event that scenarios can wait for, such as `Then the event "door_opened" should occur`.
func send_event(event_name: String, data: Dictionary) -> void:
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		gs.event(event_name, data)
