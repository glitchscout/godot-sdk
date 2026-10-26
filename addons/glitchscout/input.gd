extends RefCounted
## ACTION_INJECT: semantic input through the InputMap, as a player's device would produce it.
##
## Injected input is queued and applied at the start of the next game frame with InputEventActions, then
## flushed, so polling (Input.is_action_pressed) and event handlers (_input) both see it from exactly that
## frame. A press with hold_ticks N is released after exactly N physics and N idle frames.
##
## Virtual 2D axes come from the project setting glitchscout/axes, {name: [negative_x, positive_x,
## negative_y, positive_y]} in Input.get_vector order, so {action: "move", x, y} drives four actions.

const AXES_SETTING := "glitchscout/axes"

static var _axes_cache: Variant = null ## parsed glitchscout/axes; refreshed when project settings change
static var _warned := {} ## malformed axis names already warned about

var sdk: Node

var _queue: Array = [] ## [action, pressed, strength, hold_ticks], applied at the next game frame
var _release_at := {} ## action -> tick at which a hold_ticks press ends
var _held := {} ## actions the SDK is holding down


func _init(owner: Node) -> void:
	sdk = owner


## Virtual axes from the project setting, keeping only well-formed entries (parsed once, warned once).
static func axes() -> Dictionary:
	if _axes_cache == null:
		_axes_cache = _parse_axes()
		if not ProjectSettings.settings_changed.is_connected(_forget_axes):
			ProjectSettings.settings_changed.connect(_forget_axes)
	return _axes_cache


static func _forget_axes() -> void:
	_axes_cache = null


static func _parse_axes() -> Dictionary:
	var out := {}
	var setting: Variant = ProjectSettings.get_setting(AXES_SETTING, {})
	if not setting is Dictionary:
		return out
	for name in setting:
		var actions: Variant = setting[name]
		if actions is Array and actions.size() == 4 and actions.all(func(a): return InputMap.has_action(str(a))):
			out[str(name)] = actions.map(func(a): return str(a))
		elif not _warned.has(name):
			_warned[name] = true
			push_warning("Glitchscout: %s.%s needs four InputMap actions (negative x, positive x, negative y, positive y)" % [AXES_SETTING, name])
	return out


func on_inject(msg: Dictionary) -> void:
	var p: Dictionary = msg.payload
	var changes: Array = []
	for b in p.get("digital_buttons", []):
		var action := str(b.get("action", ""))
		if not InputMap.has_action(action):
			sdk.reply_error(msg, "unknown_action", "no InputMap action '%s'" % action)
			return
		match str(b.get("op", "")):
			"press":
				changes.append([action, true, 1.0, int(b.get("hold_ticks", 0))])
			"release":
				changes.append([action, false, 0.0, 0])
			var op:
				sdk.reply_error(msg, "bad_request", "unknown op '%s'" % op)
				return
	var virtual := axes()
	for a in p.get("analog_axes", []):
		var name := str(a.get("action", ""))
		var x := clampf(float(a.get("x", 0.0)), -1.0, 1.0)
		var y := clampf(float(a.get("y", 0.0)), -1.0, 1.0)
		if virtual.has(name):
			var four: Array = virtual[name]
			changes.append_array(_axis(four[0], four[1], x))
			changes.append_array(_axis(four[2], four[3], y))
		elif InputMap.has_action(name):
			changes.append([name, x != 0.0, absf(x), 0])
		else:
			sdk.reply_error(msg, "unknown_action", "no InputMap action or glitchscout/axes entry '%s'" % name)
			return
	_queue.append_array(changes)
	sdk.reply(msg, "ACK", {"result": {"tick_frame": sdk.tick}})


## Queues a press of action for exactly ticks game frames.
func queue_press(action: String, ticks: int) -> void:
	_queue.append([action, true, 1.0, ticks])


func _axis(negative: String, positive: String, v: float) -> Array:
	return [[negative, v < 0.0, maxf(-v, 0.0), 0], [positive, v > 0.0, maxf(v, 0.0), 0]]


## Called at the start of every game frame: ends finished holds, then applies queued input.
func frame_start() -> void:
	var changed := false
	for action in _release_at.keys():
		if sdk.tick >= _release_at[action]:
			_apply(action, false, 0.0, 0)
			changed = true
	for c in _queue:
		_apply(c[0], c[1], c[2], c[3])
		changed = true
	_queue.clear()
	if changed:
		Input.flush_buffered_events()


## Releases everything the SDK pressed (the session ended or the SDK is going away).
func release_all() -> void:
	_queue.clear()
	_release_at.clear()
	for action in _held.keys():
		_apply(action, false, 0.0, 0)
	Input.flush_buffered_events()


func _apply(action: String, pressed: bool, strength: float, hold_ticks: int) -> void:
	if not pressed and not _held.has(action):
		return # never send the game a release for something we didn't press
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = strength if pressed else 0.0
	Input.parse_input_event(ev)
	if pressed:
		_held[action] = true
		if hold_ticks > 0:
			_release_at[action] = sdk.tick + hold_ticks
		else:
			_release_at.erase(action)
	else:
		_held.erase(action)
		_release_at.erase(action)
