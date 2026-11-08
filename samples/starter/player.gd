extends CharacterBody3D
## Walks with the move actions, jumps, and uses the nearest thing in reach with interact. Glitchscout reads its
## position and velocity on its own, because it's in the player group.

@export var speed := 5.0
@export var jump_velocity := 6.0


func _ready() -> void:
	add_to_group("player")


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := Vector3(input.x, 0, input.y)
	var cam := get_viewport().get_camera_3d()
	if cam:
		dir = dir.rotated(Vector3.UP, cam.global_rotation.y) # "forward" is where the camera looks
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if Input.is_action_just_pressed("interact"):
		_interact()
	move_and_slide()


func _interact() -> void:
	var best: Node3D = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("glitchscout_interactable"):
		if not n is Node3D or not n.has_method("interact"):
			continue
		var d: float = global_position.distance_to(n.global_position)
		if d <= n.interaction_range and d < best_d:
			best = n
			best_d = d
	if best:
		best.interact()
