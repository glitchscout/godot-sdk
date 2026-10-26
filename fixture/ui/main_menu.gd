extends Control
## Fixture main menu. Play starts a new game; Continue stays disabled (there is no save yet); Options opens a
## panel with a volume slider and Back; Quit asks the game to quit.

signal new_game
signal quit_requested

var volume := 0.5


func _ready() -> void:
	$Buttons/Play.pressed.connect(func(): new_game.emit())
	$Buttons/Options.pressed.connect(_show_options.bind(true))
	$Buttons/Quit.pressed.connect(func(): quit_requested.emit())
	$Options/Back.pressed.connect(_show_options.bind(false))
	$Options/Volume.value_changed.connect(func(v: float): volume = v)
	$Buttons/Play.grab_focus()


func _show_options(show: bool) -> void:
	$Options.visible = show
	$Buttons.visible = not show
	if show:
		$Options/Volume.grab_focus()
	else:
		$Buttons/Options.grab_focus()
