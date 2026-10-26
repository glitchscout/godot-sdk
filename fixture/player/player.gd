extends CharacterBody3D
## Fixture player: walks with the move actions and jumps. Records what it did so tests can check it.

@export var speed := 5.0
@export var jump_velocity := 6.0
@export var health := 100.0
## Set by the god_mode command: damage does nothing.
var invulnerable := false

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


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
		jumps += 1
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	velocity.x = input.x * speed
	velocity.z = input.y * speed
	move_and_slide()
	last_position = global_position
	max_height = maxf(max_height, global_position.y)
