extends Node
## A game that crashes or hangs once its session is open: the orchestrator's real-Godot launcher tests
## start tests/scenes/crash_after_handshake.tscn or hang_after_handshake.tscn with
## --glitchscout-time=realtime and check how the session ends.

enum Fault { CRASH, HANG }

@export var fault := Fault.CRASH


func _ready() -> void:
	var gs := get_node_or_null("/root/Glitchscout")
	if gs == null:
		push_error("misbehave_after_handshake: no Glitchscout autoload")
		return
	gs.state_changed.connect(_on_state)


func _on_state(state: int) -> void:
	if state != GlitchscoutSDK.State.READY:
		return
	# Let the HELLO_ACK's frame finish (and a heartbeat go out) before misbehaving.
	await get_tree().create_timer(0.5).timeout
	match fault:
		Fault.CRASH:
			OS.crash("crash_after_handshake: crashing on purpose")
		Fault.HANG:
			print("hang_after_handshake: hanging on purpose")
			while true:
				OS.delay_msec(100)
