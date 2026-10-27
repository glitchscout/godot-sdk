extends Area3D
## The end of the course: reaching it completes the level.

var _done := false


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if _done or not body.is_in_group("player"):
		return
	_done = true
	var gs := get_node_or_null("/root/Glitchscout")
	if gs:
		gs.event("level_complete", {})
