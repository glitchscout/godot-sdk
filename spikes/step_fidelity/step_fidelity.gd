extends Node
## Step-fidelity spike (GSC-23). Runs one probe scene under hold mode or pause mode and reports how
## faithfully each kind of game-time machinery follows the stepped frames. See README.md.
##
##   godot --path . --fixed-fps 60 [--headless] [--audio-driver Dummy] res://spikes/step_fidelity/step_fidelity.tscn \
##       -- --mode=hold|pause [--steps=600] [--hold-ms=20] [--out=PATH]

const FPS := 60.0
const TIMER_S := 0.25
const ANIM_S := 1.0
const TWEEN_S := 10.0
const PARTICLE_LIFETIME_S := 0.5


## Counts what a pausable game node sees.
class Probe:
	extends Node

	var idle := 0
	var physics := 0
	var paused_notes := 0
	var anim_value := 0.0
	var tween_value := 0.0
	var max_wall_jump_ms := 0
	var _last_wall_ms := -1

	func _process(_delta: float) -> void:
		idle += 1
		var now := Time.get_ticks_msec()
		if _last_wall_ms >= 0:
			max_wall_jump_ms = maxi(max_wall_jump_ms, now - _last_wall_ms)
		_last_wall_ms = now

	func _physics_process(_delta: float) -> void:
		physics += 1

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PAUSED:
			paused_notes += 1


## A node that keeps processing while the tree is paused (menus, UI animation).
class AlwaysProbe:
	extends Node

	var idle := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		idle += 1


var mode := "hold"
var steps := 600
var hold_ms := 20
var out_path := ""

var _stepped := 0
var _pause_until_us := 0
var _max_pump_gap_us := 0
var _pumps := 0
var _game: Node
var _probe: Probe
var _always: AlwaysProbe
var _timer_idle_hits := 0
var _timer_physics_hits := 0
var _particles_done_at := -1
var _audio: AudioStreamGeneratorPlayback
var _started_us := 0
var _tween_half := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1_000_000 # first in every frame, like the SDK node
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			mode = a.trim_prefix("--mode=")
		elif a.begins_with("--steps="):
			steps = int(a.trim_prefix("--steps="))
		elif a.begins_with("--hold-ms="):
			hold_ms = int(a.trim_prefix("--hold-ms="))
		elif a.begins_with("--out="):
			out_path = a.trim_prefix("--out=")
	assert(mode in ["hold", "pause"], "--mode must be hold or pause")
	_build_game()
	_started_us = Time.get_ticks_usec()


func _build_game() -> void:
	_game = Node.new()
	_game.name = "Game"
	# Explicitly pausable: under this ALWAYS node it would otherwise inherit ALWAYS. (In a real game the
	# SDK autoload is a sibling of the game, not its parent.)
	_game.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_game)
	_probe = Probe.new()
	_game.add_child(_probe)
	_always = AlwaysProbe.new()
	add_child(_always)

	for callback in [Timer.TIMER_PROCESS_IDLE, Timer.TIMER_PROCESS_PHYSICS]:
		var t := Timer.new()
		t.wait_time = TIMER_S
		t.process_callback = callback
		t.autostart = true
		t.timeout.connect(_on_timer.bind(callback))
		_game.add_child(t)

	var anim := Animation.new()
	anim.length = ANIM_S
	anim.loop_mode = Animation.LOOP_LINEAR
	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, NodePath("Game/Probe:anim_value"))
	anim.track_insert_key(track, 0.0, 0.0)
	anim.track_insert_key(track, ANIM_S, 1.0)
	var lib := AnimationLibrary.new()
	lib.add_animation("ramp", anim)
	var player := AnimationPlayer.new()
	_game.add_child(player)
	player.root_node = player.get_path_to(self)
	player.add_animation_library("", lib)
	player.play("ramp")

	_probe.name = "Probe"
	_probe.create_tween().tween_property(_probe, "tween_value", TWEEN_S, TWEEN_S)

	var particles := CPUParticles2D.new()
	particles.one_shot = true
	particles.lifetime = PARTICLE_LIFETIME_S
	particles.amount = 8
	particles.explosiveness = 1.0 # all particles at once, so they all die after exactly one lifetime
	particles.finished.connect(func(): _particles_done_at = _stepped)
	_game.add_child(particles)
	particles.emitting = true

	var gen := AudioStreamGenerator.new()
	gen.mix_rate = 44100.0
	gen.buffer_length = 0.1
	var audio := AudioStreamPlayer.new()
	audio.stream = gen
	_game.add_child(audio)
	audio.play()
	_audio = audio.get_stream_playback() as AudioStreamGeneratorPlayback


func _on_timer(callback: int) -> void:
	if callback == Timer.TIMER_PROCESS_IDLE:
		_timer_idle_hits += 1
	else:
		_timer_physics_hits += 1


func _process(_delta: float) -> void:
	if mode == "hold":
		if _stepped > 0:
			_hold() # the orchestrator is thinking: nothing in the game runs meanwhile
		_step()
	else:
		var tree := get_tree()
		if not tree.paused:
			if _stepped > 0:
				# The game had its frame (this frame's physics already ran unpaused too): pause again.
				tree.paused = true
				_pause_until_us = Time.get_ticks_usec() + hold_ms * 1000
				return
		elif Time.get_ticks_usec() < _pause_until_us:
			return # the engine keeps running frames meanwhile; only ALWAYS nodes see them
		# Unpause for exactly one frame: the rest of this frame belongs to the game.
		tree.paused = false
		_step()
	_feed_audio()


## One stepped frame: the frame now running belongs to the game.
func _step() -> void:
	_stepped += 1
	if _stepped == steps / 2 + 1:
		_tween_half = _probe.tween_value # mid-run, before the 10 s tween could saturate
	if _stepped > steps:
		_finish()


## How many frames an animated value is off from game time, on a loop of length period.
func _frames_off(expected_s: float, actual_s: float, period: float) -> int:
	var d := fposmod(expected_s - actual_s + period / 2.0, period) - period / 2.0
	return roundi(d * FPS)


func _hold() -> void:
	var end := Time.get_ticks_usec() + hold_ms * 1000
	var last := Time.get_ticks_usec()
	while Time.get_ticks_usec() < end:
		DisplayServer.process_events() # keep the OS from marking the window unresponsive
		_pumps += 1
		var now := Time.get_ticks_usec()
		_max_pump_gap_us = maxi(_max_pump_gap_us, now - last)
		last = now
		OS.delay_usec(1000)


func _feed_audio() -> void:
	if _audio == null:
		return
	var frames := _audio.get_frames_available()
	for i in frames:
		_audio.push_frame(Vector2.ZERO)


func _finish() -> void:
	var n := float(steps)
	var game_s := n / FPS
	var result := {
		"mode": mode,
		"headless": DisplayServer.get_name() == "headless",
		"audio_driver": AudioServer.get_driver_name(),
		"steps": steps,
		"hold_ms": hold_ms,
		"wall_s": snappedf((Time.get_ticks_usec() - _started_us) / 1e6, 0.01),
		"physics_per_step": snappedf(_probe.physics / n, 0.001),
		"idle_per_step": snappedf(_probe.idle / n, 0.001),
		"always_node_idle_per_step": snappedf(_always.idle / n, 0.001),
		"timer_idle_hits": _timer_idle_hits,
		"timer_physics_hits": _timer_physics_hits,
		"timer_expected_hits": int(game_s / TIMER_S),
		"anim_frames_off": _frames_off(fmod(game_s, ANIM_S), _probe.anim_value * ANIM_S, ANIM_S),
		"tween_frames_off": _frames_off(minf(game_s * 0.5, TWEEN_S), _tween_half, TWEEN_S),
		"particles_finished_at_step": _particles_done_at,
		"particles_expected_step": int(PARTICLE_LIFETIME_S * FPS),
		"paused_notifications": _probe.paused_notes,
		"audio_underruns": _audio.get_skips() if _audio else -1,
		"max_wall_jump_ms_seen_by_game": _probe.max_wall_jump_ms,
		"event_pumps": _pumps,
		"max_event_pump_gap_ms": snappedf(_max_pump_gap_us / 1000.0, 0.01),
	}
	var text := JSON.stringify(result, "  ", false)
	print(text)
	if not out_path.is_empty():
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(text + "\n")
	get_tree().quit()
