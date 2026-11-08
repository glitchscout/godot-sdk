extends StaticBody3D
## A door that opens only for a player carrying its item. Glitchscout sees its state and what it requires.

@export var id := "vault_door"
@export var item := "vault_key"
@export var interaction_range := 2.5

var state := "locked"


func _ready() -> void:
	add_to_group("glitchscout_interactable")


func glitchscout_observe() -> Dictionary:
	return {
		"id": id, "type": "door", "state": state, "required_action": "interact",
		"interaction_range": interaction_range, "requires": [item],
	}


func interact() -> void:
	var game: Node = owner
	if state != "locked" or not game.inventory.has(item):
		return
	state = "open"
	$Collision.set_deferred("disabled", true)
	visible = false
	game.send_event("door_opened", {"door": id})
