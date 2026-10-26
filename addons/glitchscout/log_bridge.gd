extends Logger
## Collects Godot's log output for Glitchscout (Godot 4.5+). Godot calls these methods from any thread, so
## entries go into a locked queue that the SDK drains on the main thread. Loaded only where the Logger class
## exists, so the addon still parses on older Godot versions.

const MAX_BACKLOG := 2000

var _mutex := Mutex.new()
var _entries: Array = []
var _dropped := 0


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	var message := rationale if not rationale.is_empty() else code
	var data := {"file": file, "line": line, "function": function}
	if not script_backtraces.is_empty():
		data.backtrace = script_backtraces[0].format()
	_push({
		"kind": "script_error" if error_type in [ERROR_TYPE_SCRIPT, ERROR_TYPE_SHADER] else "log",
		"level": "warning" if error_type == ERROR_TYPE_WARNING else "error",
		"message": message,
		"data": data,
	})


func _log_message(message: String, error: bool) -> void:
	_push({"kind": "log", "level": "error" if error else "info", "message": message.strip_edges(false, true)})


func _push(entry: Dictionary) -> void:
	_mutex.lock()
	if _entries.size() < MAX_BACKLOG:
		_entries.append(entry)
	else:
		_dropped += 1
	_mutex.unlock()


## Takes up to n queued entries, oldest first, and the number dropped since the last call.
func take(n: int) -> Array:
	_mutex.lock()
	var out := _entries.slice(0, n)
	_entries = _entries.slice(n)
	var dropped := _dropped
	_dropped = 0
	_mutex.unlock()
	return [out, dropped]
