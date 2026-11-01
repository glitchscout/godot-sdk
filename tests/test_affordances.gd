extends SdkTestCase
## Collect and push affordances, the hazards section, deltas for entities an interaction changed outside the
## interest radius, and the scene_groups built-in. Realtime mode; every payload is also validated against
## the protocol schema by tools/schemacheck.

const WINDOW_SETTING := "glitchscout/interaction_delta_ticks"


## An observable node: glitchscout_observe() returns info.
class Thing:
	extends Node3D

	var info := {}

	func glitchscout_observe() -> Dictionary:
		return info


var level: Node3D
var things: Node3D


func before_test() -> void:
	super.before_test()
	level = load("res://fixture/levels/flat.tscn").instantiate()
	add_child(level)
	things = Node3D.new()
	add_child(things)


func after_test() -> void:
	super.after_test()
	level.free()
	things.free()
	ProjectSettings.set_setting(WINDOW_SETTING, null)


func _thing(groups: Array, id: String, pos: Vector3, info := {}) -> Thing:
	var t := Thing.new()
	t.info = info.duplicate()
	t.info.id = id
	for g in groups:
		t.add_to_group(g)
	things.add_child(t)
	t.global_position = pos
	return t


func _observe(payload := {}) -> Dictionary:
	start_sdk()
	await handshake()
	await get_tree().physics_frame
	var m := await request("OBSERVE", payload)
	assert_str(m.get("message_type", "")).is_equal("OBSERVATION")
	return m.get("payload", {})


func _by_id(arr: Array) -> Dictionary:
	var out := {}
	for e in arr:
		out[e.id] = e
	return out


func _ids(arr: Array) -> Array:
	return arr.map(func(e): return e.id)


## Every id an update carried in a section, across updates.
func _seen(updates: Array, section: String) -> Array:
	var out := []
	for u in updates:
		for e in u.payload.get(section, []):
			if not e.id in out:
				out.append(e.id)
	return out


func _press_interact() -> void:
	var ack := await request("ACTION_INJECT", {"digital_buttons": [{"action": "interact", "op": "press", "hold_ticks": 1}]})
	assert_str(ack.message_type).is_equal("ACK")
	# The press is applied at the next frame; the game reacts after it.
	await get_tree().process_frame
	await get_tree().process_frame


func test_collectible_and_pushable_groups_set_the_affordance() -> void:
	_thing(["glitchscout_interactable", "glitchscout_collectible"], "coin", Vector3(1, 1, 0), {"type": "coin"})
	_thing(["glitchscout_interactable", "glitchscout_pushable"], "crate", Vector3(2, 1, 0), {"type": "crate"})
	_thing(["glitchscout_interactable"], "door", Vector3(3, 1, 0), {"type": "door"})
	_thing(["glitchscout_interactable"], "gem", Vector3(4, 1, 0), {"type": "gem", "affordance": "collect"})
	_thing(["glitchscout_interactable"], "odd", Vector3(5, 1, 0), {"type": "odd", "affordance": "fly"})
	_thing(["glitchscout_collectible"], "loose_coin", Vector3(6, 1, 0), {"type": "coin"}) # not an interactable
	var obs := await _observe({"sections": ["interactables"]})
	var items := _by_id(obs.interactables)
	assert_array(items.keys()).contains_exactly_in_any_order(["coin", "crate", "door", "gem", "odd"])
	assert_str(items.coin.affordance).is_equal("collect")
	assert_str(items.crate.affordance).is_equal("push")
	assert_str(items.gem.affordance).is_equal("collect")
	assert_bool(items.door.has("affordance")).is_false() # interact is the default
	assert_bool(items.odd.has("affordance")).is_false() # not one the protocol knows


func test_hazards_report_position_radius_damage_and_velocity() -> void:
	_thing(["glitchscout_hazard"], "spikes", Vector3(3, 1, 0), {"type": "spikes", "radius": 1.5, "damage": 10})
	_thing(["glitchscout_hazard"], "arrow", Vector3(2, 1, 0), {"type": "projectile", "radius": 0.3, "velocity": Vector3(0, 0, -5)})
	_thing(["glitchscout_hazard"], "lava_far", Vector3(80, 1, 0), {"type": "lava", "radius": 4})
	_thing(["glitchscout_hazard"], "no_radius", Vector3(1, 1, 0), {"type": "spikes"})
	var obs := await _observe({"sections": ["hazards"], "radius": 20})
	assert_array(_ids(obs.hazards)).contains_exactly(["arrow", "spikes"])
	var spikes: Dictionary = obs.hazards[1]
	assert_str(spikes.type).is_equal("spikes")
	assert_float(spikes.radius).is_equal(1.5)
	assert_float(spikes.damage).is_equal(10.0)
	assert_float(spikes.position.x).is_equal_approx(3.0, 0.001)
	assert_float(obs.hazards[0].velocity.z).is_equal(-5.0)
	assert_bool(spikes.has("velocity")).is_false()


func test_hazards_are_a_default_section() -> void:
	_thing(["glitchscout_hazard"], "spikes", Vector3(3, 1, 0), {"radius": 1.0})
	var obs := await _observe()
	assert_array(_ids(obs.get("hazards", []))).contains_exactly(["spikes"])


func test_hazards_stream_in_full_and_delta_updates_with_removals() -> void:
	var spikes := _thing(["glitchscout_hazard"], "spikes", Vector3(3, 1, 0), {"radius": 1.0})
	var arrow := _thing(["glitchscout_hazard"], "arrow", Vector3(2, 1, 0), {"radius": 0.3})
	start_sdk()
	await handshake()
	await request("OBSERVE", {"sections": ["player", "hazards"], "stream_hz": 30})
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= 2)).is_true()
	arrow.free() # hit a wall
	var before := orch.messages("STATE_UPDATE").size()
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= before + 2)).is_true()
	var updates := orch.messages("STATE_UPDATE")
	assert_array(_ids(updates[0].payload.hazards)).contains_exactly(["arrow", "spikes"])
	var removal := updates.slice(before).filter(func(u): return u.payload.get("removed", {}).has("hazards"))
	assert_array(removal).is_not_empty()
	assert_array(removal[0].payload.removed.hazards).contains_exactly(["arrow"])
	assert_array(_ids(removal[0].payload.hazards)).contains_exactly(["spikes"]) # hazards move: sent every delta
	assert_bool(is_instance_valid(spikes)).is_true()


func test_changes_outside_the_radius_stream_for_k_ticks_after_an_interaction() -> void:
	ProjectSettings.set_setting(WINDOW_SETTING, 30)
	_thing(["glitchscout_interactable"], "lever", Vector3(2, 1, 0), {"type": "lever", "state": "off", "required_action": "interact"})
	var gate := _thing(["glitchscout_interactable"], "gate", Vector3(40, 1, 0), {"type": "gate", "state": "closed"})
	var light := _thing(["glitchscout_observable"], "light", Vector3(45, 1, 0), {"type": "light", "state": "off"})
	var rock := _thing(["glitchscout_observable"], "rock", Vector3(50, 1, 0), {"type": "rock", "state": "idle", "spin": 0})
	start_sdk()
	await handshake()
	await request("OBSERVE", {"sections": ["interactables", "entities"], "radius": 10, "stream_hz": 60})
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= 2)).is_true()
	await _press_interact()
	var pressed_at := sdk.tick
	gate.info.state = "open"
	light.info.state = "on"
	rock.info.spin = 1 # not a watched fact: an animation, not an effect
	var before := orch.messages("STATE_UPDATE").size()
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= before + 3)).is_true()
	var during := orch.messages("STATE_UPDATE").slice(before)
	assert_array(_seen(during, "interactables")).contains(["gate"])
	assert_array(_seen(during, "entities")).contains(["light"])
	var pulled := await request("OBSERVE", {"sections": ["interactables", "entities"], "radius": 10})
	assert_array(_ids(pulled.payload.interactables)).contains(["gate"])
	assert_array(_ids(pulled.payload.entities)).contains_exactly(["light"])
	# After K ticks the window closes: far changes are out of view again.
	assert_bool(await pump_until(func(): return sdk.tick > pressed_at + 35)).is_true()
	var after := orch.messages("STATE_UPDATE").size()
	gate.info.state = "closed"
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= after + 3)).is_true()
	var later := orch.messages("STATE_UPDATE").slice(after)
	assert_array(_seen(later, "interactables")).not_contains(["gate"])
	assert_array(_seen(orch.messages("STATE_UPDATE"), "entities")).not_contains(["rock"])


func test_far_changes_without_an_interaction_stay_out_of_view() -> void:
	ProjectSettings.set_setting(WINDOW_SETTING, 30)
	var gate := _thing(["glitchscout_interactable"], "gate", Vector3(40, 1, 0), {"type": "gate", "state": "closed"})
	start_sdk()
	await handshake()
	await request("OBSERVE", {"sections": ["interactables", "entities"], "radius": 10, "stream_hz": 60})
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= 2)).is_true()
	gate.info.state = "open" # on a timer
	var before := orch.messages("STATE_UPDATE").size()
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= before + 3)).is_true()
	assert_array(_seen(orch.messages("STATE_UPDATE"), "interactables")).not_contains(["gate"])


func test_scene_groups_lists_the_groups_in_the_scene_with_counts() -> void:
	_thing(["coins"], "c1", Vector3(1, 1, 0))
	_thing(["coins"], "c2", Vector3(2, 1, 0))
	_thing(["spikes", "_engine_private"], "s1", Vector3(3, 1, 0))
	start_sdk()
	var hello := await wait_message("HELLO")
	assert_array(hello.payload.manifest.commands.map(func(c): return c.name)).contains(["scene_groups"])
	orch.send("HELLO_ACK", {"protocol": "glitchscout/1", "session": "s-1", "resumed": false}, hello.get("id"))
	await pump_until(func(): return sdk.state == GlitchscoutSDK.State.READY)
	var m := await request("COMMAND", {"name": "scene_groups"})
	assert_str(m.message_type).is_equal("ACK")
	var groups := {}
	for g in m.payload.result.value.groups:
		groups[g.name] = int(g.count)
	assert_int(groups.get("coins", 0)).is_equal(2)
	assert_int(groups.get("spikes", 0)).is_equal(1)
	assert_bool(groups.has("_engine_private")).is_false()


func test_a_changed_entity_inside_the_radius_survives_the_max_n_cut() -> void:
	ProjectSettings.set_setting(WINDOW_SETTING, 30)
	_thing(["glitchscout_interactable"], "lever", Vector3(1, 1, 0), {"type": "lever", "state": "off", "required_action": "interact"})
	_thing(["glitchscout_interactable"], "crate_a", Vector3(2, 1, 0), {"type": "crate"})
	var gate := _thing(["glitchscout_interactable"], "gate", Vector3(5, 1, 0), {"type": "gate", "state": "closed"})
	start_sdk()
	await handshake()
	await _press_interact()
	gate.info.state = "open"
	var pulled := await request("OBSERVE", {"sections": ["interactables"], "max_n": 2})
	assert_array(_ids(pulled.payload.interactables)).contains(["lever", "crate_a", "gate"])


func test_entities_an_interaction_changed_are_removed_when_the_window_closes() -> void:
	ProjectSettings.set_setting(WINDOW_SETTING, 20)
	_thing(["glitchscout_interactable"], "lever", Vector3(2, 1, 0), {"type": "lever", "state": "off", "required_action": "interact"})
	var light := _thing(["glitchscout_observable"], "light", Vector3(45, 1, 0), {"type": "light", "state": "off"})
	start_sdk()
	await handshake()
	await request("OBSERVE", {"sections": ["entities"], "radius": 10, "stream_hz": 60})
	assert_bool(await pump_until(func(): return orch.messages("STATE_UPDATE").size() >= 2)).is_true()
	await _press_interact()
	light.info.state = "on"
	var pressed_at := sdk.tick
	assert_bool(await pump_until(func(): return sdk.tick > pressed_at + 30)).is_true()
	var removals := orch.messages("STATE_UPDATE").filter(func(u): return u.payload.get("removed", {}).has("entities"))
	assert_array(removals).is_not_empty()
	assert_array(removals[0].payload.removed.entities).contains_exactly(["light"])


func test_a_ui_activation_that_does_nothing_is_not_an_interaction() -> void:
	var s := auto_free(GlitchscoutSDK.new()) as GlitchscoutSDK
	add_child(s)
	var label := auto_free(Label.new()) as Label
	assert_bool(s._ui._activate(label)).is_false()
	assert_int(s._observation._window_until).is_equal(-1)
