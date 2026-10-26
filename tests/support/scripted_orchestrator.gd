class_name ScriptedOrchestrator
extends RefCounted
## An orchestrator stand-in that runs a script on its own thread. Step mode holds the main loop, which
## freezes the test coroutine too, so anything that must talk to a held SDK has to live off the main
## thread. A script is a list of steps; each step is called repeatedly until it returns true.
## End scripts with goodbye() so the SDK lets the main loop go again.

var vars := {} ## values steps record for the test to read after done()

var _tcp := TCPServer.new()
var _peer: WebSocketPeer
var _received: Array = []
var _consumed := {} ## message index -> true once a step took it
var _steps: Array[Callable] = []
var _index := 0
var _step_started_ms := 0
var _done := false
var _quit := false
var _mutex := Mutex.new()
var _thread := Thread.new()


func endpoint() -> String:
	return "ws://127.0.0.1:%d/" % _tcp.get_local_port()


func listen() -> void:
	var err := _tcp.listen(0, "127.0.0.1")
	assert(err == OK, "scripted orchestrator could not listen: %s" % error_string(err))


func run(steps: Array[Callable]) -> void:
	_steps = steps
	_step_started_ms = Time.get_ticks_msec()
	_thread.start(_loop)


func done() -> bool:
	_mutex.lock()
	var d := _done
	_mutex.unlock()
	return d


func stop() -> void:
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	if _thread.is_started():
		_thread.wait_to_finish()
	if _peer:
		_peer.close()
	_tcp.stop()


## All messages received so far (call after done()).
func received() -> Array:
	_mutex.lock()
	var r := _received.duplicate()
	_mutex.unlock()
	return r


func messages(message_type: String) -> Array:
	return received().filter(func(m): return m is Dictionary and m.get("message_type") == message_type)


func _loop() -> void:
	while true:
		_mutex.lock()
		var quit := _quit
		_mutex.unlock()
		if quit:
			return
		_poll()
		if _index < _steps.size():
			if _steps[_index].call():
				_index += 1
				_step_started_ms = Time.get_ticks_msec()
		else:
			_mutex.lock()
			_done = true
			_mutex.unlock()
		OS.delay_msec(1)


func _poll() -> void:
	if _peer == null and _tcp.is_connection_available():
		_peer = WebSocketPeer.new()
		_peer.inbound_buffer_size = MockOrchestrator.INBOUND_BUFFER_BYTES
		_peer.accept_stream(_tcp.take_connection())
	if _peer == null:
		return
	_peer.poll()
	while _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		if _peer.was_string_packet():
			var text := packet.get_string_from_utf8()
			MockOrchestrator.save_message(text)
			_mutex.lock()
			_received.append(JSON.parse_string(text))
			_mutex.unlock()


## The next message of a type that no step has taken yet, or {}. Steps call it from the thread.
func take(message_type: String, reply_to := "") -> Dictionary:
	for i in _received.size():
		var m: Variant = _received[i]
		if _consumed.has(i) or not (m is Dictionary) or m.get("message_type") != message_type:
			continue
		if not reply_to.is_empty() and m.get("reply_to") != reply_to:
			continue
		_consumed[i] = true
		return m
	return {}


func send(message_type: String, payload: Dictionary, reply_to: Variant = null) -> String:
	var id := MockOrchestrator._uuid()
	_peer.send_text(JSON.stringify({
		"protocol": "glitchscout/1", "message_type": message_type, "id": id, "reply_to": reply_to,
		"session": "s-1", "tick_frame": null, "ts": Time.get_unix_time_from_system(), "payload": payload,
	}))
	return id


# --- Steps -----------------------------------------------------------------------------------------

## Answers the HELLO.
func ack_hello() -> Callable:
	return func() -> bool:
		var hello := take("HELLO")
		if hello.is_empty():
			return false
		send("HELLO_ACK", {"protocol": "glitchscout/1", "session": "s-1", "resumed": false}, hello.id)
		return true


func wait_ms(ms: int) -> Callable:
	return func() -> bool: return Time.get_ticks_msec() - _step_started_ms >= ms


## Runs f once (from the thread) and moves on.
func call_once(f: Callable) -> Callable:
	return func() -> bool:
		f.call()
		return true


## Sends a request and remembers its id as vars[key].
func request(message_type: String, payload: Dictionary, key: String) -> Callable:
	return func() -> bool:
		vars[key] = send(message_type, payload)
		return true


## Waits for the reply (of any type) to the request remembered as vars[key]; stores it as vars[key + "_reply"].
func reply_to(key: String, timeout_ms := 5000) -> Callable:
	return func() -> bool:
		for t in ["ACK", "ERROR", "OBSERVATION", "QUERY_REPLY"]:
			var m := take(t, vars[key])
			if not m.is_empty():
				vars[key + "_reply"] = m
				return true
		if Time.get_ticks_msec() - _step_started_ms > timeout_ms:
			vars[key + "_reply"] = {}
			return true
		return false


## Says GOODBYE and waits for the SDK's answer, so the SDK stops holding the game.
func goodbye() -> Callable:
	var sent := [false]
	return func() -> bool:
		if not sent[0]:
			send("GOODBYE", {"reason": "test over"})
			sent[0] = true
		return not take("GOODBYE").is_empty() or Time.get_ticks_msec() - _step_started_ms > 3000
