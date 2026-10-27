extends SdkTestCase


func test_reads_endpoint_and_token_from_user_args() -> void:
	var parsed := GlitchscoutSDK.parse_args(PackedStringArray([
		"--level=3", "--glitchscout-endpoint=ws://127.0.0.1:9/", "--glitchscout-token=abc",
	]))
	assert_str(parsed.endpoint).is_equal("ws://127.0.0.1:9/")
	assert_str(parsed.token).is_equal("abc")


func test_inert_without_endpoint() -> void:
	sdk = GlitchscoutSDK.new()
	sdk.configure_from_args(PackedStringArray(["--level=3"]))
	add_child(sdk)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_int(sdk.state).is_equal(GlitchscoutSDK.State.DISABLED)
	orch.poll()
	assert_int(orch.connections).is_equal(0)


func test_hello_carries_token_versions_and_manifest() -> void:
	start_sdk("tok-1")
	var hello := await wait_message("HELLO")
	assert_dict(hello).is_not_empty()
	assert_str(hello.payload.token).is_equal("tok-1")
	assert_array(hello.payload.protocol_versions).contains_exactly(["glitchscout/1"])
	assert_bool(hello.payload.has("manifest")).is_true()
	assert_bool(hello.payload.has("resume")).is_false()
	assert_that(hello.session).is_null()


func test_hello_ack_makes_it_ready_and_later_messages_carry_the_session() -> void:
	start_sdk()
	await handshake("s-7")
	assert_int(sdk.state).is_equal(GlitchscoutSDK.State.READY)
	assert_str(sdk.session_id).is_equal("s-7")
	var hb := await wait_message("HEARTBEAT", 1, 3000)
	assert_dict(hb).is_not_empty()
	assert_str(hb.session).is_equal("s-7")
	assert_bool(hb.tick_frame is float or hb.tick_frame is int).is_true()


func test_bad_token_is_rejected_and_not_retried() -> void:
	start_sdk("bad")
	var hello := await wait_message("HELLO")
	orch.send("ERROR", {"code": "unauthorized", "message": "unknown session token", "retryable": false}, hello.id)
	assert_bool(await pump_until(func(): return sdk.state == GlitchscoutSDK.State.REJECTED)).is_true()
	assert_str(sdk.last_error.get("code", "")).is_equal("unauthorized")
	await pump_until(func(): return false, 500)
	assert_int(orch.connections).is_equal(1)


func test_version_mismatch_surfaces_the_upgrade_message() -> void:
	start_sdk()
	var hello := await wait_message("HELLO")
	var why := "the game's Glitchscout SDK speaks glitchscout/1 but this orchestrator speaks glitchscout/2: upgrade the game's Glitchscout SDK"
	orch.send("ERROR", {"code": "version_mismatch", "message": why, "retryable": false}, hello.id)
	assert_bool(await pump_until(func(): return sdk.state == GlitchscoutSDK.State.REJECTED)).is_true()
	assert_str(sdk.last_error.get("code", "")).is_equal("version_mismatch")
	assert_str(sdk.last_error.get("message", "")).contains("upgrade the game's Glitchscout SDK")


func test_refusing_close_without_its_error_still_rejects() -> void:
	# The ERROR can be lost when the close frame lands in the same poll; the close reason carries the code.
	start_sdk("bad")
	await wait_message("HELLO")
	orch.drop(1008, "unauthorized")
	assert_bool(await pump_until(func(): return sdk.state == GlitchscoutSDK.State.REJECTED)).is_true()
	assert_str(sdk.last_error.get("code", "")).is_equal("unauthorized")
	await pump_until(func(): return false, 500)
	assert_int(orch.connections).is_equal(1)


func test_resume_after_a_dropped_connection() -> void:
	start_sdk("tok-r")
	await handshake("s-1")
	orch.drop()
	var hello2 := await wait_message("HELLO", 2)
	assert_dict(hello2).is_not_empty()
	assert_int(orch.connections).is_equal(2)
	assert_str(hello2.payload.token).is_equal("tok-r")
	assert_str(hello2.payload.resume.session).is_equal("s-1")
	assert_bool(hello2.payload.resume.last_tick >= 0).is_true()
	orch.send("HELLO_ACK", {"protocol": "glitchscout/1", "session": "s-1", "resumed": true}, hello2.id)
	assert_bool(await pump_until(func(): return sdk.state == GlitchscoutSDK.State.READY)).is_true()
	assert_str(sdk.session_id).is_equal("s-1")


func test_gives_up_after_the_resume_window() -> void:
	start_sdk()
	sdk.resume_window_ms = 300
	await handshake()
	orch.stop()
	assert_bool(await pump_until(func(): return sdk.state == GlitchscoutSDK.State.CLOSED, 3000)).is_true()


func test_goodbye_is_echoed_and_asks_to_quit() -> void:
	start_sdk()
	await handshake()
	var quit_asked := [false]
	sdk.quit_requested.connect(func(): quit_asked[0] = true)
	orch.send("GOODBYE", {"reason": "teardown"})
	var bye := await wait_message("GOODBYE")
	assert_dict(bye).is_not_empty()
	assert_bool(quit_asked[0]).is_true()
	assert_int(sdk.state).is_equal(GlitchscoutSDK.State.CLOSED)


func test_unsupported_request_gets_an_error_reply() -> void:
	start_sdk()
	await handshake()
	sdk.register_handler("QUERY", Callable()) # as if no feature handled QUERY
	var id := orch.send("QUERY", {"kind": "raycast", "params": {"origin": {"x": 0, "y": 0, "z": 0}, "direction": {"x": 1, "y": 0, "z": 0}, "max_distance": 1}})
	var err := await wait_message("ERROR")
	assert_dict(err).is_not_empty()
	assert_str(err.reply_to).is_equal(id)
	assert_str(err.payload.code).is_equal("unsupported")


func test_registered_handlers_answer_requests() -> void:
	start_sdk()
	await handshake()
	sdk.register_handler("COMMAND", func(msg: Dictionary) -> void:
		sdk.reply(msg, "ACK", {"result": {"value": msg.payload.name}}))
	var id := orch.send("COMMAND", {"name": "ping"})
	var ack := await wait_message("ACK")
	assert_dict(ack).is_not_empty()
	assert_str(ack.reply_to).is_equal(id)
	assert_str(ack.payload.result.value).is_equal("ping")


func test_failed_handshakes_do_not_extend_the_resume_window() -> void:
	start_sdk()
	sdk.resume_window_ms = 400
	await handshake()
	orch.drop()
	# Every reconnect gets as far as HELLO and is then dropped again; the window must still run out.
	var answered := [1]
	var closed: bool = await pump_until(func():
		var hellos := orch.messages("HELLO").size()
		if hellos > answered[0]:
			answered[0] = hellos
			orch.drop()
		return sdk.state == GlitchscoutSDK.State.CLOSED, 4000)
	assert_bool(closed).is_true()


func test_says_goodbye_when_the_game_exits() -> void:
	# _exit_tree calls goodbye(). Freeing the node here would also drop the socket, and the mock's Godot
	# WebSocketPeer loses a message that arrives with the drop, so the test calls goodbye() directly.
	start_sdk()
	await handshake()
	sdk.goodbye("game_exit")
	assert_int(sdk.state).is_equal(GlitchscoutSDK.State.CLOSED)
	var bye := await wait_message("GOODBYE")
	assert_dict(bye).is_not_empty()
	assert_str(bye.payload.reason).is_equal("game_exit")


## Step mode holds the game from the frame after HELLO_ACK. A request that arrives together with the
## HELLO_ACK must wait for that hold, or its reply describes a tick the game has already left behind.
func test_in_step_mode_a_request_sent_with_the_hello_ack_is_answered_held() -> void:
	sdk = GlitchscoutSDK.new()
	sdk.quit_on_goodbye = false
	sdk.time_mode = "step"
	sdk.max_hold_ms = 600 # this main-thread mock can't send STEPs: let the hold time out into realtime
	sdk.heartbeat_interval_ms = 100
	sdk.configure(orch.endpoint(), "tok")
	add_child(sdk)
	var hello := await wait_message("HELLO")
	orch.send("HELLO_ACK", {"protocol": "glitchscout/1", "session": "s-1", "resumed": false}, hello.id)
	var id := orch.send("OBSERVE", {})
	var reply := func() -> Array: return orch.received.filter(func(m): return m is Dictionary and m.get("reply_to") == id)
	await pump_until(func(): return not reply.call().is_empty(), 5000)
	assert_array(reply.call()).has_size(1)
	var beats := orch.messages("HEARTBEAT") # sent while held
	assert_array(beats).is_not_empty()
	assert_int(int(reply.call()[0].tick_frame)).is_equal(int(beats[0].tick_frame))


## An orchestrator that speaks only a newer protocol may refuse in its own envelope: still a refusal.
func test_a_refusal_in_another_protocols_envelope_still_rejects() -> void:
	start_sdk()
	var hello := await wait_message("HELLO")
	var env := orch.envelope("ERROR", {"code": "version_mismatch", "message": "upgrade the SDK", "retryable": false}, hello.id)
	env.protocol = "glitchscout/2"
	orch.send_text(JSON.stringify(env))
	await pump_until(func(): return sdk.state == GlitchscoutSDK.State.REJECTED)
	assert_int(sdk.state).is_equal(GlitchscoutSDK.State.REJECTED)
	assert_str(sdk.last_error.get("code", "")).is_equal("version_mismatch")
