extends RefCounted
## The Control-tree walker (ui_elements) and UI_ACTION.
##
## UI_ACTION works the way a player would: it moves focus to the control and presses ui_accept for one
## tick, so the game's own input handling runs (activation "focus_accept"). Only when that can't work (the
## control takes no focus, or ui_accept isn't mapped) does it activate the control directly, which can hide
## input bugs, so the ACK says activation "direct" for the trace.
##
## Element ids come from the "glitchscout_id" metadata when a control has it, else its node path.

const ID_META := "glitchscout_id"

var sdk: Node


func _init(owner: Node) -> void:
	sdk = owner


## Every element in the tree, as ui_element dictionaries.
func elements() -> Array:
	var out := []
	for c in _controls():
		out.append(_element(c))
	return out


func on_ui_action(msg: Dictionary) -> void:
	var p: Dictionary = msg.payload
	var id := str(p.get("element_id", ""))
	var c := _find(id)
	if c == null:
		sdk.reply_error(msg, "unknown_element", "no UI element '%s'" % id)
		return
	if not c.is_visible_in_tree():
		sdk.reply_error(msg, "element_not_visible", "%s is not visible" % id)
		return
	if not _enabled(c):
		sdk.reply_error(msg, "element_disabled", "%s is disabled" % id)
		return
	match str(p.get("op", "")):
		"focus":
			if c.focus_mode == Control.FOCUS_NONE:
				sdk.reply_error(msg, "not_focusable", "%s can't take focus" % id)
				return
			c.grab_focus()
			_ack(msg, "focus_accept")
		"click", "submit":
			if _can_accept(c):
				c.grab_focus()
				sdk.press_for("ui_accept", 1)
				_ack(msg, "focus_accept")
			elif _activate(c):
				_ack(msg, "direct")
			else:
				sdk.reply_error(msg, "invalid_args", "%s can't be clicked" % id)
		"set_value":
			if _set_value(c, p.get("value")):
				_ack(msg, "direct")
			else:
				sdk.reply_error(msg, "invalid_args", "%s takes no value like %s" % [id, p.get("value")])
		var op:
			sdk.reply_error(msg, "bad_request", "unknown op '%s'" % op)


func _ack(msg: Dictionary, activation: String) -> void:
	sdk.reply(msg, "ACK", {"result": {"activation": activation, "tick_frame": sdk.tick}})


func _controls() -> Array[Control]:
	var out: Array[Control] = []
	_walk(sdk.get_tree().root, out)
	return out


func _walk(node: Node, out: Array[Control]) -> void:
	if node is Control and not _type(node).is_empty():
		out.append(node)
	for child in node.get_children():
		_walk(child, out)


func _find(id: String) -> Control:
	for c in _controls():
		if _id(c) == id:
			return c
	return null


func _type(c: Control) -> String:
	if c is CheckBox or c is CheckButton:
		return "checkbox"
	if c is OptionButton:
		return "option"
	if c is BaseButton:
		return "button"
	if c is LineEdit or c is TextEdit:
		return "text_input"
	if c is Slider or c is SpinBox:
		return "slider"
	if c is Label or c is RichTextLabel:
		return "label"
	if c.is_in_group("glitchscout_ui"):
		return "control"
	return ""


func _id(c: Control) -> String:
	if c.has_meta(ID_META):
		return str(c.get_meta(ID_META))
	var scene := sdk.get_tree().current_scene
	return str(scene.get_path_to(c)) if scene and scene.is_ancestor_of(c) else str(c.get_path())


func _element(c: Control) -> Dictionary:
	var xf := c.get_global_transform_with_canvas()
	var size := c.size * xf.get_scale()
	var e := {
		"id": _id(c),
		"type": _type(c),
		"enabled": _enabled(c),
		"visible": c.is_visible_in_tree(),
		"focused": c.has_focus(),
		"rect": [snappedf(xf.origin.x, 0.1), snappedf(xf.origin.y, 0.1), snappedf(size.x, 0.1), snappedf(size.y, 0.1)],
	}
	var text := _text(c)
	if text != null:
		e.text = text
	var value: Variant = _value(c)
	if value != null:
		e.value = value
	return e


func _text(c: Control) -> Variant:
	if c is OptionButton:
		return c.get_item_text(c.selected) if c.selected >= 0 else ""
	if c is Button or c is Label or c is LineEdit or c is TextEdit:
		return c.text
	if c is RichTextLabel:
		return c.get_parsed_text()
	return null


func _value(c: Control) -> Variant:
	if c is CheckBox or c is CheckButton:
		return c.button_pressed
	if c is Range:
		return c.value
	if c is LineEdit or c is TextEdit:
		return c.text
	if c is OptionButton:
		return c.get_item_text(c.selected) if c.selected >= 0 else null
	return null


func _enabled(c: Control) -> bool:
	if c is BaseButton:
		return not c.disabled
	if c is LineEdit or c is TextEdit or c is Slider or c is SpinBox:
		return c.editable
	return true


## Buttons react to the ui_accept action. Line edits only react to real key events, not actions, so
## submitting one is always a (flagged) direct activation.
func _can_accept(c: Control) -> bool:
	return c is BaseButton and c.focus_mode != Control.FOCUS_NONE and InputMap.has_action("ui_accept")


## Activates a control without going through input. Returns false if it has no activation.
func _activate(c: Control) -> bool:
	if c is BaseButton:
		if c.toggle_mode:
			c.button_pressed = not c.button_pressed # emits toggled
		c.pressed.emit()
		return true
	if c is LineEdit:
		c.text_submitted.emit(c.text)
		return true
	return false


func _set_value(c: Control, v: Variant) -> bool:
	if v == null:
		return false
	if c is LineEdit or c is TextEdit:
		c.text = str(v)
		if c is LineEdit:
			c.text_changed.emit(c.text)
		else:
			c.text_changed.emit()
		return true
	if c is CheckBox or c is CheckButton:
		c.button_pressed = bool(v) if not v is String else v.to_lower() in ["true", "1", "yes", "on"]
		return true
	if c is OptionButton:
		for i in c.item_count:
			if c.get_item_text(i) == str(v) or (v is float and i == int(v)):
				c.select(i)
				c.item_selected.emit(i)
				return true
		return false
	if c is Range and (v is float or v is int):
		c.value = float(v) # emits value_changed
		return true
	return false
