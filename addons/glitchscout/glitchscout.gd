class_name GlitchscoutSDK
extends Node
## The Glitchscout SDK runtime. It connects the game to the Glitchscout orchestrator over WebSocket and
## answers its requests. Installed as the [code]Glitchscout[/code] autoload, it stays inert unless the
## game was launched with [code]-- --glitchscout-endpoint=… --glitchscout-token=…[/code].
##
## Features register a handler per request type with [method register_handler] and switch on their
## entries in [member supports], which the capability manifest advertises.

signal state_changed(state: State)
## Emitted when the orchestrator says GOODBYE, just before the game quits (see [member quit_on_goodbye]).
signal quit_requested

enum State {
	DISABLED, ## no endpoint given: the SDK does nothing
	CONNECTING, ## opening the first connection
	HELLO_SENT, ## waiting for HELLO_ACK
	READY, ## session open
	RECONNECTING, ## the connection dropped; trying to resume the session
	REJECTED, ## the orchestrator refused the HELLO (see [member last_error])
	CLOSED, ## the session ended (GOODBYE, or no resume within [member resume_window_ms])
}

const StepMode := preload("step_mode.gd")
const InputInjection := preload("input.gd")
const Observation := preload("observe.gd")
const UI := preload("ui.gd")
const Queries := preload("queries.gd")
const Commands := preload("commands.gd")
const Events := preload("events.gd")
const Capture := preload("capture.gd")
const LogTail := preload("log_tail.gd")
const PROTOCOL := "glitchscout/1"
const SDK_VERSION := "0.1.0"
const MAX_TEXT_FRAME_BYTES := 262144
const MAX_BINARY_FRAME_BYTES := 4194304
## Room for one assembled binary frame plus its 64-byte header (Godot's default is 64 KiB).
const OUTBOUND_BUFFER_BYTES := MAX_BINARY_FRAME_BYTES + 64

var state: State = State.DISABLED
## Game frames so far: physics frames, minus those spent paused by pause-mode step mode. A pause the game
## sets itself doesn't stop it, so tick-based timing keeps working in pause menus. Every message carries
## it as tick_frame.
var tick := 0
## Session id from HELLO_ACK; kept across reconnects so the session can resume.
var session_id := ""
## The last error the orchestrator reported, as {code, message}.
var last_error := {}
## Quit the game when the orchestrator says GOODBYE (tests turn this off).
var quit_on_goodbye := true
var heartbeat_interval_ms := 1000
var reconnect_interval_ms := 500
## How long to keep trying to reconnect after a drop before giving up.
var resume_window_ms := 30000
## Capabilities advertised in the manifest. Each SDK feature switches its own on.
var supports := {
	"step_mode": true, "reset_tiers": [1], "navmesh": false, "nav_links": false, "ui_tree": true,
	"screenshots": false, "seed": false, "save_fixtures": false, "god_mode": false,
}
## Debug commands, events and entity types the game registered, for the manifest.
## "step" holds the game between STEPs; "realtime" lets it run (--glitchscout-time).
var time_mode := "step"
## How step mode holds the game: "hold" (block the main loop) or "pause" (pause the tree). Empty means
## the project setting glitchscout/step/method (default "hold"); --glitchscout-step-method overrides it.
var step_method := ""
## Stop holding after this long without a STEP (0 = never; a safety valve for tests).
var max_hold_ms := 0
var commands: Array[Dictionary] = []
var events: Array[String] = []
var entity_types: Array[String] = []

var _endpoint := ""
var _token := ""
var _configured := false
var _peer: WebSocketPeer
var _handlers := {}
var _hello_id := ""
var _started_ms := 0
var _next_heartbeat_ms := 0
var _next_connect_ms := 0
var _dropped_ms := 0
var _close_at_ms := -1
var _crypto := Crypto.new()
var _step: StepMode
var _injection: InputInjection
var _observation: Observation
var _ui: UI
var _queries: Queries
var _commands: Commands
var _events: Events
var _capture: Capture
## Where CAPTURE gets its image (a Callable returning an Image); unset, the viewport's last rendered frame.
var capture_source := Callable()
## The WebSocket send buffer asked for. Frames bigger than what the connection actually has are chunked.
var outbound_buffer_bytes := OUTBOUND_BUFFER_BYTES
## How long a queued frame may wait for room in the send buffer before it's dropped.
var frame_send_timeout_ms := 2000
var _outbox: Array[Dictionary] = [] ## messages waiting for room in the send buffer: {messages, binary, next, done, deadline}
var _reset_handler := Callable()


func _init() -> void:
	_step = StepMode.new(self)
	_injection = InputInjection.new(self)
	_observation = Observation.new(self)
	_ui = UI.new(self)
	_queries = Queries.new(self)
	_commands = Commands.new(self)
	_events = Events.new(self)
	_capture = Capture.new(self)
	register_handler("STATE_CTRL", _on_state_ctrl)
	register_handler("CAPTURE", _capture.on_capture)
	register_handler("COMMAND", _commands.on_command)
	register_handler("QUERY", _queries.on_query)
	register_handler("OBSERVE", _observation.on_observe)
	register_handler("UI_ACTION", _ui.on_ui_action)
	register_handler("STEP", _step.on_step)
	register_handler("ACTION_INJECT", _injection.on_inject)


## Reads the endpoint and token from the user arguments that follow [code]--[/code].
static func parse_args(args: PackedStringArray) -> Dictionary:
	var out := {"endpoint": "", "token": "", "time": "", "step_method": ""}
	for a in args:
		if a.begins_with("--glitchscout-endpoint="):
			out.endpoint = a.trim_prefix("--glitchscout-endpoint=")
		elif a.begins_with("--glitchscout-token="):
			out.token = a.trim_prefix("--glitchscout-token=")
		elif a.begins_with("--glitchscout-time="):
			out.time = a.trim_prefix("--glitchscout-time=")
		elif a.begins_with("--glitchscout-step-method="):
			out.step_method = a.trim_prefix("--glitchscout-step-method=")
	return out


## Sets the endpoint and token instead of reading them from the command line. Call before adding the node.
func configure(endpoint: String, token: String) -> void:
	_endpoint = endpoint
	_token = token
	_configured = true


func configure_from_args(args: PackedStringArray) -> void:
	var parsed := parse_args(args)
	configure(parsed.endpoint, parsed.token)
	if not parsed.time.is_empty():
		time_mode = parsed.time
	if not parsed.step_method.is_empty():
		step_method = parsed.step_method


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1_000_000 # run before the game's own nodes each frame
	if not _configured:
		configure_from_args(OS.get_cmdline_user_args())
	_started_ms = Time.get_ticks_msec()
	if step_method.is_empty():
		step_method = str(_setting("glitchscout/step/method", "hold"))
	if not step_method in ["hold", "pause"]:
		push_warning("Glitchscout: unknown step method '%s', using hold" % step_method)
		step_method = "hold"
	if not time_mode in ["step", "realtime"]:
		push_warning("Glitchscout: unknown time mode '%s', using step" % time_mode)
		time_mode = "step"
	_step.method = step_method
	if not should_enable(_endpoint, OS.is_debug_build(), OS.has_feature("qa")):
		return
	_dropped_ms = _started_ms
	_set_state(State.CONNECTING)
	_events.start()
	_open_socket()


func _process(_delta: float) -> void:
	if _step.frame_start(): # may hold right here until the next STEP
		_injection.frame_start()
		_observation.frame_start()
	poll()


func _physics_process(_delta: float) -> void:
	if not _step.sdk_paused:
		tick += 1


func _exit_tree() -> void:
	_step.release()
	_injection.release_all()
	_events.stop()
	if _peer == null:
		return
	# The game is going away: say so, so the session ends now instead of waiting out a resume window.
	goodbye("game_exit")
	_peer = null # freeing the peer drops the socket; an explicit close could lose the GOODBYE


## Services the connection: reads requests, sends HELLO and heartbeats, reconnects after a drop.
func poll() -> void:
	var now := Time.get_ticks_msec()
	if _peer == null:
		if state in [State.CONNECTING, State.RECONNECTING] and now >= _next_connect_ms:
			if now - _dropped_ms > resume_window_ms:
				_give_up()
			else:
				_open_socket()
		return
	_peer.poll()
	while _peer and _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		if _peer.was_string_packet():
			_on_text(packet.get_string_from_utf8())
	if _peer == null:
		return
	match _peer.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if state == State.CLOSED:
				if _close_at_ms >= 0 and now >= _close_at_ms:
					_peer.close(1000, "goodbye")
			elif state in [State.CONNECTING, State.RECONNECTING]:
				_send_hello()
			elif state == State.READY:
				if now >= _next_heartbeat_ms:
					_next_heartbeat_ms = now + heartbeat_interval_ms
					send("HEARTBEAT", {"uptime_ms": now - _started_ms})
				_events.flush()
				_flush_outbox()
		WebSocketPeer.STATE_CLOSED:
			_on_closed(now)


## Whether the SDK switches itself on: only with an orchestrator endpoint, and only in a debug build or a
## build exported with the "qa" feature tag. A shipping build never connects (and normally doesn't contain
## the SDK at all: the export plugin strips it).
static func should_enable(endpoint: String, debug: bool, qa: bool) -> bool:
	return not endpoint.is_empty() and (debug or qa)


## Sends a game event, e.g. gs.event("dialogue_started", {"npc_id": "elder"}) with
## gs = get_node_or_null("/root/Glitchscout"), so the game still runs in a build without the SDK.
func event(name: String, data := {}) -> void:
	_events.event(name, data)


## The Logger forwarding Godot's log output (null on Godot versions without one).
func log_bridge() -> Object:
	return _events.bridge()


## What RELOAD_SCENE (reset tier 1) does: handler(), or a fresh instance of the current scene when none is set.
## Games whose root node outlives levels set one that rebuilds the current level.
func set_reset_handler(handler: Callable) -> void:
	_reset_handler = handler


func _on_state_ctrl(msg: Dictionary) -> void:
	if str(msg.payload.get("op", "")) != "RELOAD_SCENE":
		reply_error(msg, "unsupported_tier", "SAVE/LOAD snapshots (reset tier 2) aren't supported by Glitchscout SDK %s; use RELOAD_SCENE" % SDK_VERSION)
		return
	if _reset_handler.is_valid():
		_reset_handler.call()
	elif not _reload_current_scene_now():
		reply_error(msg, "no_scene", "there is no current scene loaded from a file to reload; set a reset handler")
		return
	reply(msg, "ACK", {"result": {"tick_frame": tick}})


## Swaps the current scene for a fresh instance right away. reload_current_scene() waits for the end of the
## frame, which a held game only reaches after the next STEP, so an OBSERVE after the ACK would see the old one.
func _reload_current_scene_now() -> bool:
	var tree := get_tree()
	var old := tree.current_scene
	if old == null or old.scene_file_path.is_empty():
		return false
	var packed := load(old.scene_file_path) as PackedScene
	if packed == null:
		return false
	var fresh := packed.instantiate()
	var parent := old.get_parent()
	var index := old.get_index()
	parent.remove_child(old)
	old.queue_free()
	parent.add_child(fresh)
	parent.move_child(fresh, index)
	tree.current_scene = fresh
	tree.scene_changed.emit()
	return true


## Registers a debug command the orchestrator may run (see commands.gd for the handler contract). Only
## registered commands and the SDK's built-ins can run.
static func register_command(name: String, handler: Callable, description := "", params := {}) -> void:
	Commands.register(name, handler, description, params)


static func unregister_command(name: String) -> void:
	Commands.unregister(name)


## Presses an action for exactly ticks game frames (used by UI_ACTION's ui_accept).
func press_for(action: String, ticks: int) -> void:
	_injection.queue_press(action, ticks)


## Uses an AStarGrid2D for navigation queries in a game without navigation regions (null stops). Grid
## points are world positions (cell * cell_size + offset); paths go through cell centres.
func use_nav_grid(grid: AStarGrid2D) -> void:
	_queries.grid = grid


## The glitchscout id for a node: its own, or that of its nearest observable ancestor (a collider's
## parent door, say), else its node path.
func entity_id(node: Node) -> String:
	return _observation.entity_id(node)


## Every observable entity (interactables, threats, observables) as {id, type, position}.
func all_entities() -> Array:
	return _observation.all_entities()


## The UI elements currently in the tree (observation's ui_elements).
func ui_elements() -> Array:
	return _ui.elements()


## Ends the session from the game's side with GOODBYE (sent automatically when the node leaves the tree).
func goodbye(reason: String) -> void:
	if state != State.READY or _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	send("GOODBYE", {"reason": reason})
	_peer.poll() # flush now: the game may be quitting
	_set_state(State.CLOSED)
	_close_at_ms = Time.get_ticks_msec() + 100


## Registers the handler for one request type. It receives the parsed message and replies with
## [method reply] or [method reply_error].
func register_handler(message_type: String, handler: Callable) -> void:
	_handlers[message_type] = handler


## Sends a message and returns its id ("" when not connected).
func send(message_type: String, payload: Dictionary, reply_to: Variant = null) -> String:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ""
	var id := _uuid()
	_put(encode(message_type, payload, reply_to, id).to_utf8_buffer(), false)
	return id


## Queues a binary frame (see capture.gd); done(messages_sent) is called once it's all out, with 0 if it
## couldn't be sent. A frame bigger than the send buffer (outbound_buffer_bytes, or less if the connection
## got less) goes as chunks that fit, at most 1 MiB each. Frames leave from poll() as the buffer drains, so
## sending never blocks the game; one that can't get out within frame_send_timeout_ms is dropped.
func send_frame(payload: PackedByteArray, f: Dictionary, done: Callable) -> void:
	var room := _frame_room()
	if room <= Capture.HEADER_BYTES:
		done.call(0)
		return
	var frames: Array[PackedByteArray] = []
	if Capture.HEADER_BYTES + payload.size() <= room:
		frames.append(Capture.encode_frame(payload, f))
	else:
		frames = Capture.split(payload, f, mini(Capture.MAX_CHUNK_BYTES, room - Capture.HEADER_BYTES))
	_outbox.append({"messages": frames, "binary": true, "next": 0, "done": done, "deadline": Time.get_ticks_msec() + frame_send_timeout_ms})
	_flush_outbox()


func _frame_room() -> int:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return 0
	return mini(_peer.outbound_buffer_size, outbound_buffer_bytes)


## Writes a message now, or queues it behind what's already waiting so messages keep their order and none
## is lost to a full send buffer.
func _put(bytes: PackedByteArray, binary: bool) -> void:
	if _outbox.is_empty() and (_fits(bytes.size()) or bytes.size() > _frame_room()):
		_write(bytes, binary) # one that could never fit is tried anyway, and the peer refuses it
		return
	_outbox.append({"messages": [bytes], "binary": binary, "next": 0, "done": Callable(), "deadline": Time.get_ticks_msec() + frame_send_timeout_ms})


func _fits(n: int) -> bool:
	return _peer.get_current_outbound_buffered_amount() + n <= _frame_room()


func _write(bytes: PackedByteArray, binary: bool) -> Error:
	return _peer.send(bytes, WebSocketPeer.WRITE_MODE_BINARY if binary else WebSocketPeer.WRITE_MODE_TEXT)


## Sends queued messages while they fit in the send buffer.
func _flush_outbox() -> void:
	while not _outbox.is_empty():
		var sent := _pump(_outbox[0])
		if sent < 0:
			return # the buffer is draining; carry on at the next poll
		var job: Dictionary = _outbox.pop_front()
		if job.done.is_valid():
			job.done.call(sent)


## Writes what fits of one queued job: its message count once all are out, -1 to wait, 0 if it failed.
func _pump(job: Dictionary) -> int:
	while job.next < job.messages.size():
		var bytes: PackedByteArray = job.messages[job.next]
		if not _fits(bytes.size()):
			return -1 if Time.get_ticks_msec() <= job.deadline else 0
		if _write(bytes, job.binary) != OK:
			return 0
		job.next += 1
	return job.messages.size()


## Sends an already encoded message (see [method encode]).
func send_text(text: String) -> void:
	if _peer and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_put(text.to_utf8_buffer(), false)


## The JSON text of one message (a fresh id unless given), with the current session and tick.
func encode(message_type: String, payload: Dictionary, reply_to: Variant = null, id := "") -> String:
	var env := {
		"protocol": PROTOCOL,
		"message_type": message_type,
		"id": id if not id.is_empty() else _uuid(),
		"reply_to": reply_to,
		"session": session_id if not session_id.is_empty() else null,
		"tick_frame": tick,
		"ts": Time.get_unix_time_from_system(),
		"payload": payload,
	}
	return JSON.stringify(env)


func reply(request: Dictionary, message_type: String, payload: Dictionary) -> void:
	send(message_type, payload, request.get("id"))


func reply_error(request: Dictionary, code: String, message: String, retryable := false) -> void:
	reply(request, "ERROR", {"code": code, "message": message, "retryable": retryable})


## The capability manifest sent in HELLO (protocol manifest.schema.json).
func build_manifest() -> Dictionary:
	var hints := {"units_per_meter": float(_setting("glitchscout/physics/units_per_meter", 1.0))}
	for key in ["move_speed", "jump_height"]:
		var v: Variant = _setting("glitchscout/physics/" + key, null)
		if v != null:
			hints[key] = float(v)
	var m := {
		"engine": {"name": "godot", "version": Engine.get_version_info().string},
		"sdk_version": SDK_VERSION,
		"input_actions": _input_actions(),
		"movement_space": str(_setting("glitchscout/movement_space", "camera")),
		"camera_actions": _strings(_setting("glitchscout/camera_actions", [])),
		"combat_actions": _strings(_setting("glitchscout/combat_actions", [])),
		"physics_hints": hints,
		"entity_types": _merged_entity_types(),
		"events": _event_names(),
		"commands": _command_descriptors(),
		"supports": _supports(),
		"limits": {
			"max_text_frame_bytes": MAX_TEXT_FRAME_BYTES,
			"max_binary_frame_bytes": MAX_BINARY_FRAME_BYTES,
			"observe_defaults": {"radius": Observation.DEFAULT_RADIUS, "max_n": Observation.DEFAULT_MAX_N},
		},
	}
	var build_id := str(_setting("application/config/version", ""))
	if not build_id.is_empty():
		m.build_id = build_id
	return m


func _open_socket() -> void:
	_peer = WebSocketPeer.new()
	_peer.outbound_buffer_size = outbound_buffer_bytes
	var err := _peer.connect_to_url(_endpoint)
	if err != OK:
		push_error("Glitchscout: can't connect to %s: %s" % [_endpoint, error_string(err)])
		_peer = null
		_next_connect_ms = Time.get_ticks_msec() + reconnect_interval_ms


func _send_hello() -> void:
	var payload := {"token": _token, "protocol_versions": [PROTOCOL], "manifest": build_manifest()}
	if not session_id.is_empty():
		payload.resume = {"session": session_id, "last_tick": tick}
	_hello_id = send("HELLO", payload)
	_set_state(State.HELLO_SENT)


func _on_text(text: String) -> void:
	var msg: Variant = JSON.parse_string(text)
	if not (msg is Dictionary) or not msg.has("message_type"):
		send("ERROR", {"code": "invalid_message", "message": "not a protocol message", "retryable": false})
		return
	var payload: Dictionary = msg.payload if msg.get("payload") is Dictionary else {}
	var message_type := str(msg.message_type)
	if state == State.HELLO_SENT:
		match message_type:
			"HELLO_ACK":
				if msg.get("reply_to") == _hello_id:
					_on_hello_ack(payload)
			"ERROR":
				_reject(payload)
			"GOODBYE":
				_on_goodbye(msg)
		return
	if state != State.READY:
		return
	match message_type:
		"HEARTBEAT", "HELLO_ACK":
			pass
		"GOODBYE":
			_on_goodbye(msg)
		"ERROR":
			last_error = {"code": str(payload.get("code", "")), "message": str(payload.get("message", ""))}
			push_warning("Glitchscout: the orchestrator reported %s: %s" % [last_error.code, last_error.message])
		_:
			var handler: Callable = _handlers.get(message_type, Callable())
			if handler.is_valid():
				handler.call(msg)
			else:
				reply_error(msg, "unsupported", "%s is not supported by Glitchscout SDK %s" % [message_type, SDK_VERSION])


func _on_hello_ack(payload: Dictionary) -> void:
	session_id = str(payload.get("session", ""))
	_dropped_ms = 0
	_next_heartbeat_ms = Time.get_ticks_msec() + heartbeat_interval_ms
	_set_state(State.READY)


func _reject(payload: Dictionary) -> void:
	last_error = {"code": str(payload.get("code", "")), "message": str(payload.get("message", ""))}
	push_error("Glitchscout: the orchestrator refused the connection (%s): %s" % [last_error.code, last_error.message])
	_set_state(State.REJECTED)
	if _peer:
		_peer.close()


func _on_goodbye(msg: Dictionary) -> void:
	send("GOODBYE", {"reason": "orchestrator_goodbye"}, msg.get("id"))
	_set_state(State.CLOSED)
	_peer.poll() # flush the GOODBYE now: the game may quit at the end of this frame
	# Close a little later rather than at once: a peer that receives a message and the close frame in
	# the same read can lose the message (Godot's own WebSocketPeer does).
	_close_at_ms = Time.get_ticks_msec() + 100
	quit_requested.emit()
	if quit_on_goodbye:
		get_tree().quit()


func _on_closed(now: int) -> void:
	var code := _peer.get_close_code()
	var reason := _peer.get_close_reason()
	_peer = null
	_outbox.clear() # their CAPTUREs died with the connection; the orchestrator retries
	if state == State.HELLO_SENT and code == 1008:
		# A refusal whose ERROR arrived with the close frame and was lost: the reason carries its code.
		_reject({"code": reason, "message": "the orchestrator closed the connection: %s" % reason})
		return
	match state:
		State.READY, State.HELLO_SENT:
			# The window runs from the first drop: a reconnect that fails mid-handshake doesn't restart it.
			if state == State.READY or _dropped_ms == 0:
				_dropped_ms = now
			_next_connect_ms = now + reconnect_interval_ms
			_set_state(State.RECONNECTING if not session_id.is_empty() else State.CONNECTING)
		State.CONNECTING, State.RECONNECTING: # this attempt failed; poll retries until the window ends
			_next_connect_ms = now + reconnect_interval_ms


func _give_up() -> void:
	push_error("Glitchscout: lost the connection to the orchestrator and couldn't resume within %d ms" % resume_window_ms)
	_set_state(State.CLOSED)


func _set_state(s: State) -> void:
	if s != state:
		state = s
		if s in [State.CLOSED, State.REJECTED]:
			_injection.release_all() # no orchestrator left to let go of anything
		state_changed.emit(s)


## Registered commands, plus any listed by hand in `commands` (registrations win on a name clash).
func _command_descriptors() -> Array:
	var out := Commands.descriptors()
	var names := out.map(func(c): return c.name)
	for c in commands:
		if not c.get("name") in names:
			out.append(c.duplicate(true))
	return out


func _supports() -> Dictionary:
	var s := supports.duplicate(true)
	var available := Commands.names()
	s.god_mode = s.god_mode or "god_mode" in available
	s.save_fixtures = s.save_fixtures or "load_save" in available
	s.seed = s.seed or "set_seed" in available
	s.screenshots = Capture.available()
	if is_inside_tree():
		s.navmesh = _queries.has_navmesh()
		s.nav_links = _queries.has_nav_links()
	return s


func _event_names() -> Array:
	var out := _events.names()
	for e in events:
		if not e in out:
			out.append(e)
	return out


func _merged_entity_types() -> Array:
	var out: Array = entity_types.duplicate()
	if is_inside_tree():
		for t in _observation.entity_types():
			if not t in out:
				out.append(t)
	return out


func _input_actions() -> Array:
	var out := []
	for action in InputMap.get_actions():
		var kind := "button"
		for e in InputMap.action_get_events(action):
			if e is InputEventJoypadMotion:
				kind = "axis_1d"
				break
		out.append({"name": String(action), "type": kind})
	for axis in InputInjection.axes():
		out.append({"name": axis, "type": "axis_2d"})
	return out


func _setting(name: String, default: Variant) -> Variant:
	return ProjectSettings.get_setting(name, default)


func _strings(v: Variant) -> Array:
	var out := []
	if v is Array or v is PackedStringArray:
		for s in v:
			out.append(str(s))
	return out


func _uuid() -> String:
	var b := _crypto.generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]
