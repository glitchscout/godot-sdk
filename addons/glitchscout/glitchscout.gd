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

const PROTOCOL := "glitchscout/1"
const SDK_VERSION := "0.1.0"
const MAX_TEXT_FRAME_BYTES := 262144
const MAX_BINARY_FRAME_BYTES := 4194304
## Room for one assembled binary frame plus its 64-byte header (Godot's default is 64 KiB).
const OUTBOUND_BUFFER_BYTES := MAX_BINARY_FRAME_BYTES + 64

var state: State = State.DISABLED
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
	"step_mode": false, "reset_tiers": [], "navmesh": false, "nav_links": false, "ui_tree": false,
	"screenshots": false, "seed": false, "save_fixtures": false, "god_mode": false,
}
## Debug commands, events and entity types the game registered, for the manifest.
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


## Reads the endpoint and token from the user arguments that follow [code]--[/code].
static func parse_args(args: PackedStringArray) -> Dictionary:
	var out := {"endpoint": "", "token": ""}
	for a in args:
		if a.begins_with("--glitchscout-endpoint="):
			out.endpoint = a.trim_prefix("--glitchscout-endpoint=")
		elif a.begins_with("--glitchscout-token="):
			out.token = a.trim_prefix("--glitchscout-token=")
	return out


## Sets the endpoint and token instead of reading them from the command line. Call before adding the node.
func configure(endpoint: String, token: String) -> void:
	_endpoint = endpoint
	_token = token
	_configured = true


func configure_from_args(args: PackedStringArray) -> void:
	var parsed := parse_args(args)
	configure(parsed.endpoint, parsed.token)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1_000_000 # run before the game's own nodes each frame
	if not _configured:
		configure_from_args(OS.get_cmdline_user_args())
	_started_ms = Time.get_ticks_msec()
	if _endpoint.is_empty():
		return
	_dropped_ms = _started_ms
	_set_state(State.CONNECTING)
	_open_socket()


func _process(_delta: float) -> void:
	poll()


func _exit_tree() -> void:
	if _peer:
		_peer.close()


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
			elif state == State.READY and now >= _next_heartbeat_ms:
				_next_heartbeat_ms = now + heartbeat_interval_ms
				send("HEARTBEAT", {"uptime_ms": now - _started_ms})
		WebSocketPeer.STATE_CLOSED:
			_on_closed(now)


## Registers the handler for one request type. It receives the parsed message and replies with
## [method reply] or [method reply_error].
func register_handler(message_type: String, handler: Callable) -> void:
	_handlers[message_type] = handler


## Sends a message and returns its id ("" when not connected).
func send(message_type: String, payload: Dictionary, reply_to: Variant = null) -> String:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ""
	var id := _uuid()
	var env := {
		"protocol": PROTOCOL,
		"message_type": message_type,
		"id": id,
		"reply_to": reply_to,
		"session": session_id if not session_id.is_empty() else null,
		"tick_frame": Engine.get_physics_frames(),
		"ts": Time.get_unix_time_from_system(),
		"payload": payload,
	}
	_peer.send_text(JSON.stringify(env))
	return id


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
		"entity_types": entity_types.duplicate(),
		"events": events.duplicate(),
		"commands": commands.duplicate(true),
		"supports": supports.duplicate(true),
		"limits": {"max_text_frame_bytes": MAX_TEXT_FRAME_BYTES, "max_binary_frame_bytes": MAX_BINARY_FRAME_BYTES},
	}
	var build_id := str(_setting("application/config/version", ""))
	if not build_id.is_empty():
		m.build_id = build_id
	return m


func _open_socket() -> void:
	_peer = WebSocketPeer.new()
	_peer.outbound_buffer_size = OUTBOUND_BUFFER_BYTES
	var err := _peer.connect_to_url(_endpoint)
	if err != OK:
		push_error("Glitchscout: can't connect to %s: %s" % [_endpoint, error_string(err)])
		_peer = null
		_next_connect_ms = Time.get_ticks_msec() + reconnect_interval_ms


func _send_hello() -> void:
	var payload := {"token": _token, "protocol_versions": [PROTOCOL], "manifest": build_manifest()}
	if not session_id.is_empty():
		payload.resume = {"session": session_id, "last_tick": Engine.get_physics_frames()}
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
	if state == State.HELLO_SENT and code == 1008:
		# A refusal whose ERROR arrived with the close frame and was lost: the reason carries its code.
		_reject({"code": reason, "message": "the orchestrator closed the connection: %s" % reason})
		return
	match state:
		State.READY, State.HELLO_SENT:
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
		state_changed.emit(s)


func _input_actions() -> Array:
	var out := []
	for action in InputMap.get_actions():
		var kind := "button"
		for e in InputMap.action_get_events(action):
			if e is InputEventJoypadMotion:
				kind = "axis_1d"
				break
		out.append({"name": String(action), "type": kind})
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
