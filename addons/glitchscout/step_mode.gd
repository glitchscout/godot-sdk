extends RefCounted
## Step mode (ADR: hold mode by default). The SDK node runs first in every frame and calls
## [method frame_start]; when the granted ticks are used up the game waits there until the next STEP.
##
## Hold: block the main loop, servicing the connection and pumping OS events, so nothing in the game
## runs and nothing notices the wait. Pause: pause the scene tree and keep frames running, for games
## where blocking the main loop doesn't work. Either way a STEP of N ticks runs exactly N physics and N
## idle game frames before its ACK.

var sdk: Node
var method := "hold"
var budget := 0 ## game frames still granted by the current STEP

var _pending: Dictionary = {} ## the STEP waiting for its ACK
var _pending_ticks := 0
var _hold_started_ms := 0
var _engaged := false ## holding (or pausing) the game for a session
## Pause mode: whether the tree is paused by us between steps, and the game's own pause state to put back.
var sdk_paused := false
var _game_paused := false


func _init(owner: Node) -> void:
	sdk = owner


func on_step(msg: Dictionary) -> void:
	var ticks := int(msg.payload.get("ticks", 0))
	if ticks < 1:
		sdk.reply_error(msg, "bad_request", "STEP needs ticks >= 1")
		return
	if not _pending.is_empty():
		sdk.reply_error(msg, "step_in_progress", "the previous STEP of %d ticks hasn't finished" % _pending_ticks, true)
		return
	_pending = msg
	_pending_ticks = ticks
	budget += ticks


## Called at the start of every frame, before any game node runs (and before this frame's requests).
func frame_start() -> void:
	if not _should_wait():
		if _engaged: # the session ended: let the game go, once (never fight the game's own pause later)
			_engaged = false
			_release()
		# Realtime mode: a STEP still waits its N frames before the ACK.
		if budget > 0:
			budget -= 1
		else:
			_finish_step()
		return
	_engaged = true
	if budget == 0:
		_finish_step()
		if method == "pause":
			_pause()
			return # frames keep running; game nodes don't
		_hold()
		if budget == 0:
			return # released without a step (session over, or the safety valve)
	if method == "pause":
		_unpause()
	budget -= 1 # the rest of this frame belongs to the game


## Lets the game run freely again (the SDK is going away).
func release() -> void:
	budget = 0
	_pending = {}
	if _engaged:
		_engaged = false
		_release()


func _should_wait() -> bool:
	return sdk.time_mode == "step" and sdk.state in [sdk.State.READY, sdk.State.RECONNECTING]


func _finish_step() -> void:
	if _pending.is_empty():
		return
	sdk.reply(_pending, "ACK", {"result": {"tick_frame": sdk.tick, "frames": _pending_ticks}})
	_pending = {}


func _hold() -> void:
	_hold_started_ms = Time.get_ticks_msec()
	while budget == 0 and _should_wait():
		sdk.poll()
		DisplayServer.process_events() # keep a headed window responsive
		if sdk.max_hold_ms > 0 and Time.get_ticks_msec() - _hold_started_ms > sdk.max_hold_ms:
			push_error("Glitchscout: no STEP for %d ms; switching to realtime" % sdk.max_hold_ms)
			sdk.time_mode = "realtime"
			return
		OS.delay_usec(500)


func _release() -> void:
	if sdk.is_inside_tree():
		_unpause()


## Pauses the tree between steps, remembering whether the game had paused it itself.
func _pause() -> void:
	var tree := sdk.get_tree()
	if not sdk_paused:
		_game_paused = tree.paused
		sdk_paused = true
	tree.paused = true


## Gives the tree back to the game in the state it chose: a game that paused itself stays paused.
func _unpause() -> void:
	if sdk_paused:
		sdk.get_tree().paused = _game_paused
		sdk_paused = false
