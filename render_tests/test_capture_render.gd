extends SdkTestCase
## CAPTURE against a real renderer: run with RENDER=1 scripts/test.sh -a res://render_tests (CI: under xvfb
## with opengl3). The headless suites in tests/ use synthetic images.


func after_test() -> void:
	super.after_test()
	RenderingServer.set_default_clear_color(Color(0.3, 0.3, 0.3))


func test_capture_grabs_what_the_viewport_rendered() -> void:
	RenderingServer.set_default_clear_color(Color(1, 0, 0))
	start_sdk()
	await handshake()
	assert_bool(orch.messages("HELLO")[0].payload.manifest.supports.screenshots).is_true()
	for i in 5:
		await get_tree().process_frame # let the new clear colour reach the screen
	var m := await request("CAPTURE", {"encoding": "png", "lossless": true}, 10000)
	assert_str(m.message_type).is_equal("ACK")
	var size := get_viewport().get_visible_rect().size
	var payload := PackedByteArray()
	for f in orch.frames:
		payload.append_array(f.slice(64))
	var h := MockOrchestrator.parse_header(orch.frames[0])
	assert_int(h.source_width).is_equal(int(size.x))
	assert_int(h.source_height).is_equal(int(size.y))
	var img := Image.new()
	assert_int(img.load_png_from_buffer(payload)).is_equal(OK)
	var c := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	assert_float(c.r).is_greater(0.9)
	assert_float(c.g).is_less(0.1)


func test_routine_capture_of_the_viewport_fits_the_cap() -> void:
	start_sdk()
	await handshake()
	for i in 3:
		await get_tree().process_frame
	var m := await request("CAPTURE", {"encoding": "jpeg", "max_long_edge": 640}, 10000)
	assert_str(m.message_type).is_equal("ACK")
	assert_int(orch.frames.size()).is_equal(1)
	assert_int(orch.frames[0].size()).is_less_equal(262144)
	assert_int(MockOrchestrator.parse_header(orch.frames[0]).width).is_less_equal(640)
