class_name MockOrchestrator
extends RefCounted
## A scripted WebSocket server standing in for the orchestrator in SDK tests. Every text message it
## receives is also saved under res://reports/messages/ so tools/schemacheck can validate it.

const MESSAGES_DIR := "res://reports/messages"

static var _saved := 0

var received: Array = [] ## parsed messages from the SDK, in arrival order, across connections
var connections := 0

var _tcp := TCPServer.new()
var _peers: Array[WebSocketPeer] = []


func start() -> void:
	var err := _tcp.listen(0, "127.0.0.1")
	assert(err == OK, "mock orchestrator could not listen: %s" % error_string(err))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MESSAGES_DIR))


func endpoint() -> String:
	return "ws://127.0.0.1:%d/" % _tcp.get_local_port()


## Accepts new connections and collects what the SDK sent. Call it every frame while waiting.
func poll() -> void:
	while _tcp.is_listening() and _tcp.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.accept_stream(_tcp.take_connection())
		_peers.append(ws)
		connections += 1
	for ws in _peers:
		ws.poll()
		while ws.get_available_packet_count() > 0:
			var packet := ws.get_packet()
			if not ws.was_string_packet():
				continue
			var text := packet.get_string_from_utf8()
			_save(text)
			received.append(JSON.parse_string(text))


func messages(message_type: String) -> Array:
	return received.filter(func(m): return m is Dictionary and m.get("message_type") == message_type)


## Sends a message on the newest connection and returns its id.
func send(message_type: String, payload: Dictionary, reply_to: Variant = null) -> String:
	var id := _uuid()
	var env := {
		"protocol": "glitchscout/1", "message_type": message_type, "id": id, "reply_to": reply_to,
		"session": null, "tick_frame": null, "ts": Time.get_unix_time_from_system(), "payload": payload,
	}
	_peers.back().send_text(JSON.stringify(env))
	return id


## Closes the newest connection without a GOODBYE, as a dropped socket would. Godot's WebSocketPeer
## loses a message that arrives in the same poll as a close frame, so never drop right after send.
func drop(code := 1001, reason := "dropped") -> void:
	_peers.back().close(code, reason)


func stop() -> void:
	for ws in _peers:
		ws.close()
	_tcp.stop()


func _save(text: String) -> void:
	_saved += 1
	var path := "%s/%d-%05d.json" % [MESSAGES_DIR, OS.get_process_id(), _saved]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)


static func _uuid() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]
