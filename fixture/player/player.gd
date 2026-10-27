extends CharacterBody3D
## Fixture player: walks with the move actions and jumps. Records what it did so tests can check it.

@export var speed := 5.0
@export var jump_velocity := 6.0
@export var health := 100.0
## Set by the god_mode command: damage does nothing.
var invulnerable := false
var damage_taken := 0.0

var max_height := 0.0
var jumps := 0
## Position after the latest physics frame. Tests read this, not global_position, because they may run on
## another thread, where node transforms can't be read.
var last_position := Vector3.ZERO


func _ready() -> void:
	add_to_group("player")


## What Glitchscout's observation adds for this node.
func glitchscout_observe() -> Dictionary:
	return {"health": health}


func hurt(amount: float) -> void:
	if invulnerable:
		return
	health -= amount
	damage_taken += amount


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
		jumps += 1
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := Vector3(input.x, 0, input.y)
	var cam := get_viewport().get_camera_3d()
	if cam:
		dir = dir.rotated(Vector3.UP, cam.global_rotation.y) # camera-relative: "forward" is where it looks
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if Input.is_action_just_pressed("interact"):
		_interact()
	move_and_slide()
	last_position = global_position
	max_height = maxf(max_height, global_position.y)


## Uses the nearest interactable in range.
func _interact() -> void:
	var best: Node3D = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("glitchscout_interactable"):
		if not n is Node3D or not n.has_method("interact"):
			continue
		var d: float = global_position.distance_to(n.global_position)
		var reach: float = n.get("interaction_range") if n.get("interaction_range") != null else 2.0
		if d <= reach and d < best_d:
			best = n
			best_d = d
	if best:
		best.interact(self)
