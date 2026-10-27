extends AnimatableBody3D
## A platform that moves back and forth across a gap.

@export var offset := Vector3(0, 0, -4)
@export var period := 3.0

var _start := Vector3.ZERO
var _t := 0.0


func _ready() -> void:
	_start = position


func _physics_process(delta: float) -> void:
	_t += delta
	position = _start + offset * (0.5 - 0.5 * cos(_t * TAU / period))
