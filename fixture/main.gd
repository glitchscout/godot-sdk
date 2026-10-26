extends Node
## The fixture game's root: it opens on the main menu, and "new game" swaps the menu for the first level.

const MENU := preload("res://fixture/ui/main_menu.tscn")
const FIRST_LEVEL := "res://fixture/levels/flat.tscn"

var state := "menu"


func _ready() -> void:
	var menu := MENU.instantiate()
	menu.new_game.connect(_start_new_game)
	add_child(menu)


func _start_new_game() -> void:
	get_node("MainMenu").queue_free()
	add_child(load(FIRST_LEVEL).instantiate())
	state = "playing"
