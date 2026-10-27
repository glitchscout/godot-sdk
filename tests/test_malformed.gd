extends SdkTestCase
## Requests the SDK can't act on get an ERROR before any handler runs on them, and the session goes on.


func _send(env: Dictionary) -> Dictionary:
	orch.send_text(JSON.stringify(env))
	var answer := func() -> Dictionary:
		for m in orch.received:
			if m is Dictionary and m.get("reply_to") == env.get("id"):
				return m
		return {}
	await pump_until(func(): return not answer.call().is_empty())
	return answer.call()


func _refused(env: Dictionary, code := "bad_request") -> void:
	var r := await _send(env)
	assert_str(r.get("message_type", "")).override_failure_message("%s → %s" % [JSON.stringify(env), r]).is_equal("ERROR")
	assert_str(r.get("payload", {}).get("code", "")).is_equal(code)


func test_a_message_for_another_protocol_version_is_refused() -> void:
	start_sdk()
	await handshake()
	var env := orch.envelope("OBSERVE", {})
	env.protocol = "glitchscout/9"
	await _refused(env, "unsupported_protocol")


func test_a_payload_that_isnt_an_object_is_refused() -> void:
	start_sdk()
	await handshake()
	await _refused(orch.envelope("OBSERVE", 42))


func test_requests_that_break_their_schema_are_refused() -> void:
	start_sdk()
	await handshake()
	for bad in [
		["QUERY", {"kind": "raycast", "params": "oops"}],
		["ACTION_INJECT", {"digital_buttons": "nope"}],
		["ACTION_INJECT", {"digital_buttons": ["nope"]}],
		["CAPTURE", {"encoding": "bmp"}],
		["STEP", {"ticks": "ten"}],
		["STEP", {"ticks": 1.5}],
		["COMMAND", {"name": 7}],
		["OBSERVE", {"no_such_filter": true}],
		["UI_ACTION", {"element_id": "x"}],
		["STATE_CTRL", {"op": "EXPLODE"}],
	]:
		await _refused(orch.envelope(bad[0], bad[1]))
	assert_dict(await request("OBSERVE", {})).contains_keys(["payload"]) # still answering


func test_a_request_without_an_id_gets_an_error_that_answers_nothing() -> void:
	start_sdk()
	await handshake()
	var env := orch.envelope("OBSERVE", {})
	env.erase("id")
	orch.send_text(JSON.stringify(env))
	var err := await wait_message("ERROR")
	assert_str(err.get("payload", {}).get("code", "")).is_equal("invalid_message")
	assert_that(err.get("reply_to")).is_null()
	assert_array(orch.messages("OBSERVATION")).is_empty()


func test_an_orchestrator_ack_gets_no_reply() -> void:
	start_sdk()
	await handshake()
	var ack := orch.envelope("ACK", {}, "00000000-0000-4000-8000-000000000001")
	orch.send_text(JSON.stringify(ack))
	await request("OBSERVE", {})
	assert_array(orch.received.filter(func(m): return m is Dictionary and m.get("reply_to") == ack.id)).is_empty()
