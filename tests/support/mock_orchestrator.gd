class_name MockOrchestrator
extends RefCounted
## A scripted WebSocket server standing in for the orchestrator in SDK tests. Every text message it
## receives is also saved under res://reports/messages/, and every binary frame under res://reports/frames/,
## so tools/schemacheck can validate them.

const MESSAGES_DIR := "res://reports/messages"
const FRAMES_DIR := "res://reports/frames"
## Like the orchestrator, accept frames up to the protocol's 4 MiB cap (Godot's default is 64 KiB).
const INBOUND_BUFFER_BYTES := 4 * 1024 * 1024 + 64

static var _saved := 0
static var _save_mutex := Mutex.new()

var received: Array = [] ## parsed messages from the SDK, in arrival order, across connections
var frames: Array[PackedByteArray] = [] ## binary frames from the SDK, in arrival order
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
		ws.inbound_buffer_size = INBOUND_BUFFER_BYTES
		ws.accept_stream(_tcp.take_connection())
		_peers.append(ws)
		connections += 1
	for ws in _peers:
		ws.poll()
		while ws.get_available_packet_count() > 0:
			var packet := ws.get_packet()
			if not ws.was_string_packet():
				save_frame(packet)
				frames.append(packet)
				continue
			var text := packet.get_string_from_utf8()
			save_message(text)
			received.append(JSON.parse_string(text))


func messages(message_type: String) -> Array:
	return received.filter(func(m): return m is Dictionary and m.get("message_type") == message_type)


## Sends a message on the newest connection and returns its id.
func send(message_type: String, payload: Dictionary, reply_to: Variant = null) -> String:
	var env := envelope(message_type, payload, reply_to)
	_peers.back().send_text(JSON.stringify(env))
	return env.id


## A message envelope with a fresh id, for tests that bend it before sending it with send_text.
func envelope(message_type: String, payload: Variant, reply_to: Variant = null) -> Dictionary:
	return {
		"protocol": "glitchscout/1", "message_type": message_type, "id": _uuid(), "reply_to": reply_to,
		"session": null, "tick_frame": null, "ts": Time.get_unix_time_from_system(), "payload": payload,
	}


## Sends text as is on the newest connection.
func send_text(text: String) -> void:
	_peers.back().send_text(text)


## Closes the newest connection without a GOODBYE, as a dropped socket would. Godot's WebSocketPeer
## loses a message that arrives in the same poll as a close frame, so never drop right after send.
func drop(code := 1001, reason := "dropped") -> void:
	_peers.back().close(code, reason)


func stop() -> void:
	for ws in _peers:
		ws.close()
	_tcp.stop()


## Saves one message the SDK sent for tools/schemacheck. Safe to call from any thread.
static func save_message(text: String) -> void:
	_save_mutex.lock()
	_saved += 1
	var n := _saved
	_save_mutex.unlock()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MESSAGES_DIR))
	var path := "%s/%d-%05d.json" % [MESSAGES_DIR, OS.get_process_id(), n]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)


## Saves one binary frame the SDK sent for tools/schemacheck. Safe to call from any thread.
static func save_frame(bytes: PackedByteArray) -> void:
	_save_mutex.lock()
	_saved += 1
	var n := _saved
	_save_mutex.unlock()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FRAMES_DIR))
	var f := FileAccess.open("%s/%d-%05d.bin" % [FRAMES_DIR, OS.get_process_id(), n], FileAccess.WRITE)
	if f:
		f.store_buffer(bytes)


## The v1 header of a binary frame as a Dictionary (field names as in binary-frame-v1.md).
static func parse_header(b: PackedByteArray) -> Dictionary:
	var id := b.slice(24, 40).hex_encode()
	return {
		"magic": b.slice(0, 4).get_string_from_ascii(), "header_version": b[4], "frame_type": b[5],
		"encoding": b[6], "flags": b[7], "header_length": b.decode_u16(8), "payload_length": b.decode_u32(12),
		"tick_frame": b.decode_u64(16),
		"request_id": "%s-%s-%s-%s-%s" % [id.substr(0, 8), id.substr(8, 4), id.substr(12, 4), id.substr(16, 4), id.substr(20, 12)],
		"width": b.decode_u16(40), "height": b.decode_u16(42), "source_width": b.decode_u16(44),
		"source_height": b.decode_u16(46), "chunk_index": b.decode_u16(48), "chunk_count": b.decode_u16(50),
		"payload_crc32": b.decode_u32(52),
	}


static func _uuid() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]
