extends SdkTestCase
## ui_element labels: the name a player reads for a slider, text field or dropdown, which their text isn't. And
## buttons that keep their text in a child Label. Realtime mode, like test_ui.gd.

var root: Control


func before_test() -> void:
	super.before_test()
	root = Control.new()
	add_child(root)


func after_test() -> void:
	super.after_test()
	root.free()


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


func _named(c: Control, id: String) -> Control:
	c.set_meta("glitchscout_id", id)
	return c


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _rich(text: String) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.text = text
	r.fit_content = true
	return r


## A container holding these controls, in order, under the test's root.
func _row(controls: Array, container: Container = HBoxContainer.new()) -> Container:
	for c in controls:
		container.add_child(c)
	root.add_child(container)
	return container


func test_a_slider_is_labelled_by_the_label_before_it() -> void:
	_row([_label("Volume"), _named(HSlider.new(), "volume")])
	_row([_rich("Music"), _named(HSlider.new(), "music")])
	await _ready_sdk()
	var ui := await _ui()
	assert_str(ui["volume"].get("label", "")).is_equal("Volume")
	assert_str(ui["music"].get("label", "")).is_equal("Music")
	assert_bool(ui["volume"].has("text")).is_false()


func test_accessibility_name_beats_the_label_beside_it_and_the_meta_beats_both() -> void:
	var named := _named(HSlider.new(), "named")
	named.set("accessibility_name", "Master volume") # set(): the property doesn't exist before Godot 4.5
	var both := _named(HSlider.new(), "both")
	both.set("accessibility_name", "Master volume")
	both.set_meta("glitchscout_label", "Main volume")
	_row([_label("Volume"), named])
	_row([_label("Volume"), both])
	await _ready_sdk()
	var ui := await _ui()
	assert_str(ui["named"].get("label", "")).is_equal("Master volume")
	assert_str(ui["both"].get("label", "")).is_equal("Main volume")


## Godot 4.4 has no accessibility_name: reading it gives nothing, and the next source names the control.
func test_without_an_accessibility_name_the_next_source_is_used() -> void:
	_row([_label("Volume"), _named(HSlider.new(), "volume")])
	await _ready_sdk()
	assert_str(sdk._ui._accessible_name(RefCounted.new())).is_empty() # an object with no such property, as in 4.4
	var ui := await _ui()
	assert_str(ui["volume"].get("label", "")).is_equal("Volume")


func test_a_text_field_is_labelled_by_its_placeholder_before_and_after_typing() -> void:
	var edit := _named(LineEdit.new(), "name") as LineEdit
	edit.placeholder_text = "Player name"
	var notes := _named(TextEdit.new(), "notes") as TextEdit
	notes.placeholder_text = "Notes"
	_row([edit, notes], VBoxContainer.new())
	await _ready_sdk()
	var ui := await _ui()
	assert_str(ui["name"].get("label", "")).is_equal("Player name")
	assert_str(ui["name"].text).is_empty()
	assert_str(ui["notes"].get("label", "")).is_equal("Notes")
	await request("UI_ACTION", {"element_id": "name", "op": "set_value", "value": "Ada"})
	ui = await _ui()
	assert_str(ui["name"].text).is_equal("Ada")
	assert_str(ui["name"].get("label", "")).is_equal("Player name")


func test_a_dropdown_is_labelled_by_the_label_before_it_and_its_text_is_the_selection() -> void:
	var quality := _named(OptionButton.new(), "quality") as OptionButton
	quality.add_item("Low")
	quality.add_item("High")
	quality.select(1)
	_row([_label("Quality"), quality])
	await _ready_sdk()
	var ui := await _ui()
	assert_str(ui["quality"].get("label", "")).is_equal("Quality")
	assert_str(ui["quality"].text).is_equal("High")
	await request("UI_ACTION", {"element_id": "quality", "op": "set_value", "value": "Low"})
	ui = await _ui()
	assert_str(ui["quality"].text).is_equal("Low")
	assert_str(ui["quality"].get("label", "")).is_equal("Quality")


## A caption names the control that follows it, not one further on with another control in between.
func test_a_label_beyond_another_control_is_not_taken() -> void:
	_row([_label("Audio"), _named(HSlider.new(), "first"), _named(HSlider.new(), "second")], VBoxContainer.new())
	await _ready_sdk()
	var ui := await _ui()
	assert_str(ui["first"].get("label", "")).is_equal("Audio")
	assert_bool(ui["second"].has("label")).is_false()


func test_a_button_is_labelled_only_by_its_meta_or_accessibility_name() -> void:
	var mute := _named(Button.new(), "mute") as Button
	mute.text = "Mute"
	var named := _named(Button.new(), "named") as Button
	named.text = "X"
	named.set_meta("glitchscout_label", "Close")
	var spoken := _named(CheckBox.new(), "spoken") as CheckBox
	spoken.text = "On"
	spoken.set("accessibility_name", "Subtitles")
	_row([_label("Sound"), mute, named, spoken])
	await _ready_sdk()
	var ui := await _ui()
	assert_bool(ui["mute"].has("label")).is_false()
	assert_str(ui["named"].get("label", "")).is_equal("Close")
	assert_str(ui["spoken"].get("label", "")).is_equal("Subtitles")


func test_a_button_with_no_text_of_its_own_reports_its_child_labels_text() -> void:
	var play := _named(Button.new(), "play")
	var styled := _rich("Play")
	styled.set_meta("glitchscout_id", "play_caption")
	play.add_child(styled)
	var icon := _named(TextureButton.new(), "icon_play")
	var caption := _label("Play")
	caption.set_meta("glitchscout_id", "icon_play_caption")
	icon.add_child(caption)
	var nested := _named(Button.new(), "nested_play")
	var margin := MarginContainer.new()
	var inner := _label("Play")
	inner.set_meta("glitchscout_id", "nested_play_caption")
	margin.add_child(inner)
	nested.add_child(margin)
	_row([play, icon, nested], VBoxContainer.new())
	await _ready_sdk()
	var ui := await _ui()
	for id in ["play", "icon_play", "nested_play"]:
		assert_str(ui[id].get("text", "")).is_equal("Play")
	for id in ["play_caption", "icon_play_caption", "nested_play_caption"]:
		assert_bool(ui.has(id)).is_false()


## A button with text of its own keeps it, and a Label inside it is still an element of its own.
func test_a_button_with_text_keeps_it_and_its_child_label() -> void:
	var start := _named(Button.new(), "start") as Button
	start.text = "Start"
	var badge := _label("New")
	badge.set_meta("glitchscout_id", "start_badge")
	start.add_child(badge)
	_row([start])
	await _ready_sdk()
	var ui := await _ui()
	assert_str(ui["start"].text).is_equal("Start")
	assert_str(ui["start_badge"].text).is_equal("New")
