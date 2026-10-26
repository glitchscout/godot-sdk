extends RefCounted
## Fallback log forwarding for Godot versions without a Logger class: follows the engine's log file from
## its end, classifying lines by Godot's prefixes.

var _path: String
var _pos := 0
var _partial := ""


func _init(path: String) -> void:
	_path = path
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			_pos = f.get_length()


## New complete lines since the last call, as EVENT payloads.
func read_new() -> Array:
	var f := FileAccess.open(_path, FileAccess.READ) if FileAccess.file_exists(_path) else null
	if f == null:
		return []
	var length := f.get_length()
	if length < _pos: # rotated or truncated
		_pos = 0
		_partial = ""
	f.seek(_pos)
	var text := _partial + f.get_buffer(length - _pos).get_string_from_utf8()
	_pos = length
	var lines := text.split("\n")
	_partial = lines[lines.size() - 1] # an unfinished last line waits for the next read
	var out := []
	for i in lines.size() - 1:
		var entry := classify(lines[i])
		if not entry.is_empty():
			out.append(entry)
	return out


static func classify(line: String) -> Dictionary:
	var t := line.strip_edges()
	if t.is_empty() or t.begins_with("at:") or t.begins_with("GDScript backtrace"):
		return {} # continuation lines of an error
	if t.begins_with("SCRIPT ERROR:") or t.begins_with("SHADER ERROR:"):
		return {"kind": "script_error", "level": "error", "message": t}
	for p in ["ERROR:", "USER ERROR:"]:
		if t.begins_with(p):
			return {"kind": "log", "level": "error", "message": t}
	for p in ["WARNING:", "USER WARNING:", "SCRIPT WARNING:"]:
		if t.begins_with(p):
			return {"kind": "log", "level": "warning", "message": t}
	return {"kind": "log", "level": "info", "message": t}
