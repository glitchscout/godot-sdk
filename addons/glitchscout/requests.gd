extends RefCounted
## Shape checks for orchestrator requests, made before any handler runs: a request whose payload breaks its
## message schema (protocol schemas/messages/) gets an ERROR instead of a handler working on bad data.
## Payloads are strict, so unknown fields are refused too. Handlers still check meaning (an action that
## exists, ticks of at least 1).

const NUMBER := "a number"
const INT := "an integer"
const STRING := "a string"
const BOOL := "true or false"
const ARRAY := "a list"
const OBJECT := "an object"
const ANY := "anything"

## Message type → field → [type, required, then the allowed values or the type of every item].
const SHAPES := {
	"OBSERVE": {
		"radius": [NUMBER], "entity_types": [ARRAY, false, STRING], "max_n": [INT],
		"sections": [ARRAY, false, STRING], "max_bytes": [INT], "stream_hz": [NUMBER],
	},
	"ACTION_INJECT": {"digital_buttons": [ARRAY, false, OBJECT], "analog_axes": [ARRAY, false, OBJECT]},
	"UI_ACTION": {
		"element_id": [STRING, true], "op": [STRING, true, ["focus", "click", "set_value", "submit"]], "value": [ANY],
	},
	"STEP": {"ticks": [INT, true]},
	"COMMAND": {"name": [STRING, true], "args": [OBJECT]},
	"STATE_CTRL": {"op": [STRING, true, ["RELOAD_SCENE", "SAVE", "LOAD"]], "slot": [STRING]},
	"QUERY": {"kind": [STRING, true], "params": [OBJECT, true]},
	"CAPTURE": {"encoding": [STRING, true, ["png", "jpeg"]], "max_long_edge": [INT], "lossless": [BOOL]},
}
## Message types whose payload needs at least one field.
const NOT_EMPTY := ["ACTION_INJECT"]


## Why payload doesn't fit the request shape of message_type, or "" when it does (or there's no shape).
static func problem(message_type: String, payload: Variant) -> String:
	if not payload is Dictionary:
		return "the payload must be an object"
	var shape: Dictionary = SHAPES.get(message_type, {})
	if shape.is_empty():
		return ""
	if message_type in NOT_EMPTY and payload.is_empty():
		return "the payload is empty"
	for key in payload:
		if not shape.has(key):
			return "unknown field '%s'" % key
	for key in shape:
		var field: Array = shape[key]
		if not payload.has(key):
			if field.size() > 1 and field[1]:
				return "'%s' is missing" % key
			continue
		var v: Variant = payload[key]
		if not _is(v, field[0]):
			return "'%s' must be %s" % [key, field[0]]
		if field.size() < 3:
			continue
		var rule: Variant = field[2]
		if rule is Array and not v in rule:
			return "'%s' must be one of %s" % [key, ", ".join(PackedStringArray(rule))]
		if rule is String:
			for item in v:
				if not _is(item, rule):
					return "every item of '%s' must be %s" % [key, rule]
	return ""


static func _is(v: Variant, type: String) -> bool:
	match type:
		NUMBER:
			return v is float or v is int
		INT:
			return v is int or (v is float and is_finite(v) and v == floorf(v))
		STRING:
			return v is String
		BOOL:
			return v is bool
		ARRAY:
			return v is Array
		OBJECT:
			return v is Dictionary
	return true
