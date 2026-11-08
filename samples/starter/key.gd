extends Area3D
## A pickup: interact with it to put its item in the inventory.

@export var id := "vault_key"
@export var item := "vault_key"
@export var interaction_range := 2.0


func _ready() -> void:
	add_to_group("glitchscout_interactable")
	add_to_group("glitchscout_collectible")


func glitchscout_observe() -> Dictionary:
	return {"id": id, "type": "pickup", "required_action": "interact", "interaction_range": interaction_range}


func interact() -> void:
	var game: Node = owner
	game.inventory[item] = int(game.inventory.get(item, 0)) + 1
	game.send_event("item_collected", {"item": item})
	queue_free()
