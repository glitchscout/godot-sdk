extends SdkTestCase
## ui_elements and UI_ACTION, against the fixture's main menu. Realtime mode: frames keep running, so the
## main-thread mock can wait for the effect of each action.

var game: Node


func before_test() -> void:
	super.before_test()
	game = load("res://fixture/main.tscn").instantiate()
	add_child(game)


func after_test() -> void:
	super.after_test()
	game.free()


func _ready_sdk() -> void:
	start_sdk()
	await handshake()
	await get_tree().process_frame


func _ui() -> Dictionary:
	var m := await request("OBSERVE", {"sections": ["ui_elements"]})
	var by_id := {}
	for e in m.payload.get("ui_elements", []):
		by_id[e.id] = e
	return by_id


func _act(element_id: String, op: String, value: Variant = null) -> Dictionary:
	var p := {"element_id": element_id, "op": op}
	if value != null:
		p.value = value
	return await request("UI_ACTION", p)


func _menu() -> Control:
	return game.get_node("MainMenu")


func test_ui_elements_describe_the_menu() -> void:
	await _ready_sdk()
	var ui := await _ui()
	assert_array(ui.keys()).contains(["main_menu/title", "main_menu/play", "main_menu/continue", "main_menu/options", "main_menu/quit", "options/volume", "options/back"])
	var play: Dictionary = ui["main_menu/play"]
	assert_str(play.type).is_equal("button")
	assert_str(play.text).is_equal("Play")
	assert_bool(play.enabled).is_true()
	assert_bool(play.visible).is_true()
	assert_bool(play.focused).is_true()
	assert_int(play.rect.size()).is_equal(4)
	assert_float(play.rect[2]).is_greater(0.0)
	assert_bool(ui["main_menu/continue"].enabled).is_false()
	assert_bool(ui["options/volume"].visible).is_false()
	assert_str(ui["options/volume"].type).is_equal("slider")
	assert_float(ui["options/volume"].value).is_equal(0.5)
	assert_str(ui["main_menu/title"].type).is_equal("label")


func test_play_starts_a_new_game_through_focus_and_accept() -> void:
	await _ready_sdk()
	var ack := await _act("main_menu/play", "click")
	assert_str(ack.message_type).is_equal("ACK")
	assert_str(ack.payload.result.activation).is_equal("focus_accept")
	assert_bool(await pump_until(func(): return game.state == "playing")).is_true()


func test_a_button_that_cannot_take_focus_is_activated_directly_and_flagged() -> void:
	await _ready_sdk()
	var quit_asked := [false]
	_menu().quit_requested.connect(func(): quit_asked[0] = true)
	_menu().get_node("Buttons/Quit").focus_mode = Control.FOCUS_NONE
	var ack := await _act("main_menu/quit", "click")
	assert_str(ack.payload.result.activation).is_equal("direct")
	assert_bool(await pump_until(func(): return quit_asked[0])).is_true()


func test_options_round_trip_and_set_value() -> void:
	await _ready_sdk()
	await _act("main_menu/options", "click")
	assert_bool(await pump_until(func(): return _menu().get_node("Options").visible)).is_true()
	var ack := await _act("options/volume", "set_value", 0.8)
	assert_str(ack.payload.result.activation).is_equal("direct")
	assert_float(_menu().volume).is_equal_approx(0.8, 0.001)
	assert_float((await _ui())["options/volume"].value).is_equal_approx(0.8, 0.001)
	await _act("options/back", "click")
	assert_bool(await pump_until(func(): return _menu().get_node("Buttons").visible)).is_true()


func test_focus_moves_focus() -> void:
	await _ready_sdk()
	var ack := await _act("main_menu/options", "focus")
	assert_str(ack.message_type).is_equal("ACK")
	await get_tree().process_frame
	assert_bool((await _ui())["main_menu/options"].focused).is_true()


func test_disabled_hidden_and_unknown_elements_are_refused() -> void:
	await _ready_sdk()
	assert_str((await _act("main_menu/continue", "click")).payload.code).is_equal("element_disabled")
	assert_str((await _act("options/back", "click")).payload.code).is_equal("element_not_visible")
	assert_str((await _act("main_menu/nope", "click")).payload.code).is_equal("unknown_element")


func test_text_inputs_and_checkboxes() -> void:
	var box := VBoxContainer.new()
	var name_edit := LineEdit.new()
	name_edit.set_meta("glitchscout_id", "form/name")
	var agree := CheckBox.new()
	agree.set_meta("glitchscout_id", "form/agree")
	box.add_child(name_edit)
	box.add_child(agree)
	game.add_child(box)
	var submitted := [""]
	name_edit.text_submitted.connect(func(t): submitted[0] = t)
	await _ready_sdk()
	await _act("form/name", "set_value", "Ada")
	await _act("form/agree", "set_value", true)
	var ack := await _act("form/name", "submit")
	assert_str(ack.message_type).is_equal("ACK")
	assert_bool(await pump_until(func(): return submitted[0] == "Ada")).is_true()
	assert_bool(agree.button_pressed).is_true()
	var ui := await _ui()
	assert_str(ui["form/name"].type).is_equal("text_input")
	assert_str(ui["form/name"].value).is_equal("Ada")
	assert_str(ui["form/agree"].type).is_equal("checkbox")
	assert_bool(ui["form/agree"].value).is_true()


func test_state_updates_carry_ui_elements_and_the_manifest_has_ui_tree() -> void:
	await _ready_sdk()
	var hello: Dictionary = orch.messages("HELLO")[0]
	assert_bool(hello.payload.manifest.supports.ui_tree).is_true()
	await request("OBSERVE", {"sections": ["ui_elements"], "stream_hz": 30})
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= 2)).is_true()
	for u in orch.messages("STATE_UPDATE"):
		assert_bool(u.payload.has("ui_elements")).is_true()


func test_a_huge_ui_is_truncated_rather_than_refused() -> void:
	var box := VBoxContainer.new()
	for i in 3000:
		var l := Label.new()
		l.text = "damage number %d with a little padding to make it bigger" % i
		box.add_child(l)
	game.add_child(box)
	await _ready_sdk()
	var m := await request("OBSERVE", {}, 10000)
	assert_str(m.message_type).is_equal("OBSERVATION")
	assert_bool(m.payload.truncated).is_true()
	assert_int(JSON.stringify(m).length()).is_less_equal(262144)
