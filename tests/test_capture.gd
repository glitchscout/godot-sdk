extends SdkTestCase
## CAPTURE: binary-frame-v1 encoding against the protocol's golden fixtures, size caps, lossless baselines
## and chunking. Images here are synthetic (the test run is headless); render_tests/ covers a real viewport.

const Capture := preload("res://addons/glitchscout/capture.gd")
const ROUTINE_MAX := 262144


func _fixture_dir() -> String:
	var dir := OS.get_environment("GLITCHSCOUT_PROTOCOL_DIR")
	assert(not dir.is_empty(), "run through scripts/test.sh, which sets GLITCHSCOUT_PROTOCOL_DIR")
	return dir.path_join("fixtures/binary")


func _read(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)


func _noise(w: int, h: int) -> Image:
	return Image.create_from_data(w, h, false, Image.FORMAT_RGB8, Crypto.new().generate_random_bytes(w * h * 3))


func _fields(h: Dictionary) -> Dictionary:
	var f := {}
	for k in ["frame_type", "encoding", "flags", "tick_frame", "request_id", "width", "height", "source_width", "source_height"]:
		f[k] = h[k]
	return f


func test_frames_match_the_golden_fixtures_byte_for_byte() -> void:
	for name in ["screenshot-png", "live-view-jpeg-downscaled", "empty-payload"]:
		var bin := _read(_fixture_dir().path_join("valid/%s.bin" % name))
		var expect: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_fixture_dir().path_join("valid/%s.json" % name)))
		var frame := Capture.encode_frame(bin.slice(64), _fields(expect.header))
		assert_str(frame.hex_encode()).override_failure_message(name).is_equal(bin.hex_encode())


func test_chunks_match_the_golden_chunk_set() -> void:
	var dir := _fixture_dir().path_join("chunked/png-3-chunks")
	var chunks: Array[PackedByteArray] = []
	var payload := PackedByteArray()
	for i in 3:
		chunks.append(_read(dir.path_join("chunk-%d.bin" % i)))
		payload.append_array(chunks[i].slice(64))
	var f := _fields(MockOrchestrator.parse_header(chunks[0]))
	f.flags = 0
	var got := Capture.split(payload, f, 1200)
	assert_int(got.size()).is_equal(3)
	for i in got.size():
		assert_str(got[i].hex_encode()).override_failure_message("chunk %d" % i).is_equal(chunks[i].hex_encode())


func test_crc32_is_zlibs() -> void:
	assert_int(Capture.crc32("123456789".to_ascii_buffer())).is_equal(0xCBF43926)
	assert_int(Capture.crc32(PackedByteArray())).is_equal(0)


func test_routine_frames_fit_256_kb() -> void:
	var r := Capture.render(_noise(1920, 1080), {"encoding": "png"})
	assert_bool(r.has("error")).override_failure_message(str(r.get("message", ""))).is_false()
	assert_int(r.payload.size() + 64).is_less_equal(ROUTINE_MAX)
	assert_int(r.encoding).is_equal(Capture.ENCODING_JPEG) # PNG of noise is far over the cap
	assert_int(r.flags & Capture.FLAG_REENCODED).is_not_equal(0)
	assert_int(r.source_width).is_equal(1920)
	var small := Capture.render(Image.create_empty(320, 180, false, Image.FORMAT_RGB8), {"encoding": "png"})
	assert_int(small.encoding).is_equal(Capture.ENCODING_PNG) # a frame under the cap keeps its encoding
	assert_int(small.flags).is_equal(0)


func test_max_long_edge_downscales_and_says_so() -> void:
	var r := Capture.render(Image.create_empty(1280, 720, false, Image.FORMAT_RGB8), {"encoding": "jpeg", "max_long_edge": 640})
	assert_int(r.width).is_equal(640)
	assert_int(r.height).is_equal(360)
	assert_int(r.source_width).is_equal(1280)
	assert_int(r.source_height).is_equal(720)
	assert_int(r.flags & Capture.FLAG_DOWNSCALED).is_not_equal(0)


func test_lossless_baselines_are_png_with_the_exact_pixels() -> void:
	var img := _noise(640, 360)
	var r := Capture.render(img, {"encoding": "png", "lossless": true})
	assert_int(r.encoding).is_equal(Capture.ENCODING_PNG)
	assert_int(r.flags & Capture.FLAG_LOSSLESS).is_not_equal(0)
	assert_int(r.payload.size()).is_greater(ROUTINE_MAX) # exempt from the routine target
	var back := Image.new()
	assert_int(back.load_png_from_buffer(r.payload)).is_equal(OK)
	back.convert(Image.FORMAT_RGB8)
	assert_bool(back.get_data() == img.get_data()).is_true()


func test_a_lossless_frame_over_4_mb_is_refused() -> void:
	var r := Capture.render(_noise(1500, 1500), {"encoding": "png", "lossless": true})
	assert_str(r.get("error", "")).is_equal("frame_too_large")


func test_capture_sends_a_frame_for_the_request_then_acks() -> void:
	await _ready_sdk()
	sdk.capture_source = func() -> Image: return _noise(64, 32)
	var m := await request("CAPTURE", {"encoding": "png", "lossless": true})
	assert_str(m.message_type).is_equal("ACK")
	assert_int(orch.frames.size()).is_equal(1)
	var h := MockOrchestrator.parse_header(orch.frames[0])
	assert_str(h.request_id).is_equal(m.reply_to)
	assert_int(h.width).is_equal(64)
	assert_int(h.frame_type).is_equal(1)
	assert_int(h.tick_frame).is_equal(int(m.payload.result.tick_frame)) # realtime: the tick moves on while we wait


func test_frames_are_chunked_when_the_send_buffer_is_small() -> void:
	# What the SDK does when the transport refuses the 4 MiB buffer: chunks that fit what it got.
	start_sdk()
	sdk.outbound_buffer_bytes = 256 * 1024
	await handshake()
	var img := _noise(700, 500) # about 1 MB as PNG
	sdk.capture_source = func() -> Image: return img
	var m := await request("CAPTURE", {"encoding": "png", "lossless": true}, 10000)
	assert_str(m.message_type).is_equal("ACK")
	assert_int(orch.frames.size()).is_greater(1)
	var payload := PackedByteArray()
	for i in orch.frames.size():
		var h := MockOrchestrator.parse_header(orch.frames[i])
		assert_int(orch.frames[i].size()).is_less_equal(256 * 1024)
		assert_int(h.chunk_index).is_equal(i)
		assert_int(h.chunk_count).is_equal(orch.frames.size())
		assert_int(h.flags & Capture.FLAG_CHUNKED).is_not_equal(0)
		assert_bool((h.flags & Capture.FLAG_FINAL) != 0).is_equal(i == orch.frames.size() - 1)
		payload.append_array(orch.frames[i].slice(64))
	var back := Image.new()
	assert_int(back.load_png_from_buffer(payload)).is_equal(OK)
	back.convert(Image.FORMAT_RGB8)
	assert_bool(back.get_data() == img.get_data()).is_true()


func test_without_a_renderer_capture_is_refused_and_not_advertised() -> void:
	await _ready_sdk()
	assert_bool(orch.messages("HELLO")[0].payload.manifest.supports.screenshots).is_false() # headless run
	var m := await request("CAPTURE", {"encoding": "png"})
	assert_str(m.message_type).is_equal("ERROR")
	assert_str(m.payload.code).is_equal("capture_unavailable")


func test_an_impossible_frame_is_an_error_not_a_frame() -> void:
	await _ready_sdk()
	sdk.capture_source = func() -> Image: return _noise(1500, 1500)
	var m := await request("CAPTURE", {"encoding": "png", "lossless": true})
	assert_str(m.payload.code).is_equal("frame_too_large")
	assert_int(orch.frames.size()).is_equal(0)


func _ready_sdk() -> void:
	start_sdk()
	await handshake()


func test_messages_sent_while_frames_fill_the_buffer_are_kept_in_order() -> void:
	# A connection that really got only 64 KiB of send buffer (a refused raise): the first chunk fills it.
	sdk = GlitchscoutSDK.new()
	sdk.quit_on_goodbye = false
	sdk.time_mode = "realtime"
	sdk.outbound_buffer_bytes = 64 * 1024
	sdk.configure(orch.endpoint(), "tok")
	add_child(sdk)
	await handshake()
	var payload := Crypto.new().generate_random_bytes(300 * 1024)
	var f := {"frame_type": 1, "encoding": 1, "flags": 0, "tick_frame": 0, "request_id": MockOrchestrator._uuid(),
		"width": 1, "height": 1, "source_width": 1, "source_height": 1}
	var sent := [-1]
	sdk.send_frame(payload, f, func(n: int) -> void: sent[0] = n)
	sdk.event("gs_after_frame") # in the same frame, with the buffer full
	var got_event := func(): return orch.messages("EVENT").any(func(m): return m.payload.get("name") == "gs_after_frame")
	assert_bool(await pump_until(func(): return sent[0] > 0 and got_event.call(), 10000)).is_true()
	assert_int(orch.frames.size()).is_equal(sent[0])
	var assembled := PackedByteArray()
	for frame in orch.frames:
		assembled.append_array(frame.slice(64))
	assert_bool(assembled == payload).is_true()


func test_a_send_buffer_too_small_for_any_frame_fails_the_capture() -> void:
	await _ready_sdk()
	sdk.outbound_buffer_bytes = 64
	sdk.capture_source = func() -> Image: return _noise(16, 16)
	var m := await request("CAPTURE", {"encoding": "png"})
	assert_str(m.payload.code).is_equal("frame_send_failed")
