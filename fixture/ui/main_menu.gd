extends Control
## Fixture main menu. Play starts a new game; Continue stays disabled (there is no save yet); Options opens a
## panel with a volume slider and Back; Quit asks the game to quit.

signal new_game
signal quit_requested

var volume := 0.5
## The trap_focus fault: Options opens a panel focus can't leave, whose buttons do nothing.
var trap_focus := false


func _ready() -> void:
	$Buttons/Play.pressed.connect(func(): new_game.emit())
	$Buttons/Options.pressed.connect(_show_options.bind(true))
	$Buttons/Quit.pressed.connect(func(): quit_requested.emit())
	$Options/Back.pressed.connect(_show_options.bind(false))
	$Options/Volume.value_changed.connect(func(v: float): volume = v)
	$Buttons/Play.grab_focus()


func _show_trap() -> void:
	var trap := VBoxContainer.new()
	trap.name = "Trap"
	add_child(trap)
	for text in ["Sound", "Music", "Apply"]:
		var b := Button.new()
		b.name = text
		b.text = text
		b.set_meta("glitchscout_id", "settings_trap/" + text.to_lower())
		trap.add_child(b)
	var buttons := trap.get_children()
	for i in buttons.size():
		var before: NodePath = buttons[i].get_path_to(buttons[i - 1])
		var after: NodePath = buttons[i].get_path_to(buttons[(i + 1) % buttons.size()])
		buttons[i].focus_neighbor_top = before
		buttons[i].focus_neighbor_left = before
		buttons[i].focus_previous = before
		buttons[i].focus_neighbor_bottom = after
		buttons[i].focus_neighbor_right = after
		buttons[i].focus_next = after
	$Buttons.visible = false
	buttons[0].grab_focus()


func _show_options(show: bool) -> void:
	if show and trap_focus:
		_show_trap()
		return
	$Options.visible = show
	$Buttons.visible = not show
	if show:
		$Options/Volume.grab_focus()
	else:
		$Buttons/Options.grab_focus()
