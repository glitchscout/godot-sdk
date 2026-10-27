extends CharacterBody3D
## A patrolling enemy: walks between two points and hurts the player on contact.

@export var id := "patroller"
@export var from := Vector3(-3, 1, -15)
@export var to := Vector3(3, 1, -15)
@export var speed := 2.0
@export var damage := 10.0
@export var health := 30.0

var _forward := true
var _cooldown := 0.0


func _ready() -> void:
	add_to_group("glitchscout_threat")
	global_position = from


func glitchscout_observe() -> Dictionary:
	return {"id": id, "type": "enemy", "state": "patrol", "health": health, "attack_range": 1.0}


func _physics_process(delta: float) -> void:
	var target := to if _forward else from
	var d := target - global_position
	if d.length() < 0.1:
		_forward = not _forward
	else:
		global_position += d.normalized() * minf(speed * delta, d.length())
	_cooldown = maxf(0.0, _cooldown - delta)
	for p in get_tree().get_nodes_in_group("player"):
		if _cooldown == 0.0 and p is Node3D and p.global_position.distance_to(global_position) < 1.0 and p.has_method("hurt"):
			p.hurt(damage)
			_cooldown = 1.0
