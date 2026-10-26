class_name SdkTestCase
extends GdUnitTestSuite
## Shared setup for suites that drive a GlitchscoutSDK node against a MockOrchestrator.

var orch: MockOrchestrator
var sdk: GlitchscoutSDK


func before_test() -> void:
	orch = MockOrchestrator.new()
	orch.start()


func after_test() -> void:
	if is_instance_valid(sdk):
		sdk.free()
	orch.stop()


func start_sdk(token := "tok") -> GlitchscoutSDK:
	sdk = GlitchscoutSDK.new()
	sdk.quit_on_goodbye = false
	sdk.reconnect_interval_ms = 50
	sdk.configure(orch.endpoint(), token)
	add_child(sdk)
	return sdk


## Polls the mock every frame until cond() is true or timeout_ms passes; returns whether it held.
func pump_until(cond: Callable, timeout_ms := 3000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		orch.poll()
		if cond.call():
			return true
		await get_tree().process_frame
	orch.poll()
	return cond.call()


## Waits for the nth (1-based) message of a type from the SDK and returns it ({} on timeout).
func wait_message(message_type: String, nth := 1, timeout_ms := 3000) -> Dictionary:
	var ok: bool = await pump_until(func(): return orch.messages(message_type).size() >= nth, timeout_ms)
	return orch.messages(message_type)[nth - 1] if ok else {}


## Runs the handshake to READY with the given session id and returns the HELLO.
func handshake(session := "s-1") -> Dictionary:
	var hello := await wait_message("HELLO")
	orch.send("HELLO_ACK", {"protocol": "glitchscout/1", "session": session, "resumed": false}, hello.get("id"))
	await pump_until(func(): return sdk.state == GlitchscoutSDK.State.READY)
	return hello
