extends StaticBody3D
## A fixture interactable, by kind: an NPC to talk to, a pickup, a door that needs an item, or the broken
## lever (the seeded bug: pulling it does nothing but raise a script error).

@export var id := ""
@export_enum("npc", "pickup", "door", "lever") var kind := "npc"
@export var state := ""
## pickup: the item it gives; door: the item it needs.
@export var item := ""
@export var interaction_range := 2.0

## The lever's script error; tests switch it off, since a real one fails a GdUnit test.
var raise_errors := true
var errors := 0


func _ready() -> void:
	add_to_group("glitchscout_interactable")


func glitchscout_observe() -> Dictionary:
	var info := {
		"id": id, "type": kind, "state": state, "enabled": state != "jammed",
		"required_action": "interact", "interaction_range": interaction_range,
	}
	if kind == "door" and not item.is_empty():
		info.requires = [item]
	return info


func interact(_player: Node) -> void:
	var game := get_tree().get_first_node_in_group("fixture_game")
	match kind:
		"npc":
			state = "talking"
			_event("dialogue_started", {"npc_id": id})
		"pickup":
			if game:
				game.inventory[item] = 1
			_event("item_collected", {"item": item})
			queue_free()
		"door":
			if state != "locked":
				return
			if game == null or not game.inventory.has(item):
				_event("interaction_failed", {"target": id, "needs": item})
				return
			if game.jam_next_door:
				game.jam_next_door = false
				state = "jammed" # the softlock: it never opens, and nothing says why
				return
			state = "open"
			for c in get_children():
				if c is CollisionShape3D:
					c.set_deferred("disabled", true)
			visible = false
			_event("door_opened", {"door": id})
		"lever":
			errors += 1
			if raise_errors:
				_pull_mechanism.call_deferred()


func _pull_mechanism() -> void:
	var mechanism: Variant = self
	mechanism.connect_bridge_gears() # was never written: a real GDScript error, on purpose


func _event(name: String, data: Dictionary) -> void:
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		gs.event(name, data)
