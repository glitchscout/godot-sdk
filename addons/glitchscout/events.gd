extends RefCounted
## EVENT: game events (Glitchscout.event), scene changes and forwarded logs and errors.
##
## Events and logs raised before the session opens are kept (up to a cap) and sent in order once it does.
## Log forwarding uses a Logger (Godot 4.5+) or, without one, follows the log file. At most
## MAX_LOGS_PER_FRAME log lines go out per frame; a flood beyond the backlog is reported as one line.

const Observation := preload("observe.gd")
const LogTail := preload("log_tail.gd")
const MAX_PENDING := 1000
const MAX_LOGS_PER_FRAME := 200
const MAX_TAIL_BACKLOG := 2000
## Longest log message sent; longer ones are cut (frames must stay under the manifest's max_text_frame_bytes).
const MAX_MESSAGE_CHARS := 8192
## Largest game event data, as JSON; bigger data is replaced by {"truncated": true, "bytes": n}.
const MAX_DATA_BYTES := 65536

var sdk: Node

var _pending: Array = []
var _emitted := {}
var _bridge: Object = null
var _tail: LogTail = null
var _tail_backlog: Array = []
var _tail_dropped := 0


func _init(owner: Node) -> void:
	sdk = owner


## Starts log forwarding and scene-change reporting (the SDK switched itself on).
func start() -> void:
	if ClassDB.class_exists("Logger"):
		_bridge = load("res://addons/glitchscout/log_bridge.gd").new()
		OS.add_logger(_bridge)
	else:
		var path := str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))
		_tail = LogTail.new(ProjectSettings.globalize_path(path))
	if not sdk.get_tree().scene_changed.is_connected(_on_scene_changed):
		sdk.get_tree().scene_changed.connect(_on_scene_changed)


func stop() -> void:
	if _bridge:
		OS.remove_logger(_bridge)
		_bridge = null
	if sdk.is_inside_tree() and sdk.get_tree().scene_changed.is_connected(_on_scene_changed):
		sdk.get_tree().scene_changed.disconnect(_on_scene_changed)


func bridge() -> Object:
	return _bridge


func event(name: String, data: Dictionary) -> void:
	if sdk.state == sdk.State.DISABLED:
		return
	_emitted[name] = true
	var payload := {"kind": "game", "name": name}
	if not data.is_empty():
		var clean: Variant = Observation._clean(data)
		var size := JSON.stringify(clean).length()
		payload.data = clean if size <= MAX_DATA_BYTES else {"truncated": true, "bytes": size}
	_queue(payload)


## Event names for the manifest: declared in glitchscout/events, raised so far, and scene_changed.
func names() -> Array:
	var out: Array = ["scene_changed"]
	var declared: Variant = ProjectSettings.get_setting("glitchscout/events", [])
	for n in (declared if declared is Array or declared is PackedStringArray else []):
		if not str(n) in out:
			out.append(str(n))
	for n in _emitted:
		if not n in out:
			out.append(n)
	return out


## Sends what's waiting. Called every frame while the session is open.
func flush() -> void:
	if sdk.state != sdk.State.READY:
		return
	for p in _pending:
		sdk.send("EVENT", p)
	_pending.clear()
	var entries: Array = []
	var dropped := 0
	if _bridge:
		var taken: Array = _bridge.take(MAX_LOGS_PER_FRAME)
		entries = taken[0]
		dropped = taken[1]
	elif _tail:
		_tail_backlog.append_array(_tail.read_new())
		if _tail_backlog.size() > MAX_TAIL_BACKLOG:
			_tail_dropped += _tail_backlog.size() - MAX_TAIL_BACKLOG
			_tail_backlog = _tail_backlog.slice(_tail_backlog.size() - MAX_TAIL_BACKLOG)
		entries = _tail_backlog.slice(0, MAX_LOGS_PER_FRAME)
		_tail_backlog = _tail_backlog.slice(MAX_LOGS_PER_FRAME)
		dropped = _tail_dropped
		_tail_dropped = 0
	for e in entries:
		sdk.send("EVENT", _fit(e))
	if dropped > 0:
		sdk.send("EVENT", {"kind": "log", "level": "warning", "message": "Glitchscout: %d log lines dropped (log flood)" % dropped})


## A log entry with its message cut to MAX_MESSAGE_CHARS.
static func _fit(entry: Dictionary) -> Dictionary:
	var message := str(entry.get("message", ""))
	if message.length() <= MAX_MESSAGE_CHARS:
		return entry
	var cut := entry.duplicate()
	cut.message = message.left(MAX_MESSAGE_CHARS) + " … (%d characters cut)" % (message.length() - MAX_MESSAGE_CHARS)
	return cut


func _queue(payload: Dictionary) -> void:
	if sdk.state == sdk.State.READY and _pending.is_empty():
		sdk.send("EVENT", payload)
	elif _pending.size() < MAX_PENDING:
		_pending.append(payload)


func _on_scene_changed() -> void:
	var scene := sdk.get_tree().current_scene
	event("scene_changed", {"scene": scene.scene_file_path if scene else ""})
