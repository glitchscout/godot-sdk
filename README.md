# godot-sdk

Godot 4 addon that lets Glitchscout's AI test agents observe and play your game: input injection, step mode,
navigation queries and screenshots. Compiled out of release builds.

## Install

Copy `addons/glitchscout/` into your project and enable **Glitchscout** under Project → Project Settings →
Plugins. That registers the `Glitchscout` autoload. It does nothing unless Glitchscout launches the game with
`-- --glitchscout-endpoint=… --glitchscout-token=…`.

Optional project settings:

| Setting | Default | Meaning |
|---|---|---|
| `glitchscout/movement_space` | `camera` | How movement input is interpreted: `camera`, `world` or `screen` |
| `glitchscout/physics/move_speed` | unset | Player move speed, units per second |
| `glitchscout/physics/jump_height` | unset | Player jump height, units |
| `glitchscout/physics/units_per_meter` | `1.0` | World units per meter |
| `glitchscout/camera_actions`, `glitchscout/combat_actions` | empty | Input actions that steer the camera or fight |
| `glitchscout/axes` | empty | Virtual 2D axes Glitchscout can drive with one analog input, `{name: [negative_x, positive_x, negative_y, positive_y]}` in `Input.get_vector` order, e.g. `{"move": ["move_left", "move_right", "move_forward", "move_back"]}` |
| `glitchscout/step/method` | `hold` | How step mode makes the game wait between steps: `hold` blocks the main loop (nothing in the game runs or notices); `pause` pauses the scene tree instead, for games where blocking doesn't work |

## What Glitchscout sees

Put nodes in these groups. Each may define `glitchscout_observe() -> Dictionary` to add fields; an `"id"` key
overrides the node path as its identifier. Glitchscout computes distances from the player itself.

| Group | Is | Fields from `glitchscout_observe()` |
|---|---|---|
| `player` | the player (first node in the group) | `health`, `state_flags`; position, velocity (`CharacterBody`/`RigidBody`) and `is_grounded` are read automatically |
| `glitchscout_interactable` | doors, levers, pickups, NPCs | `type`, `state`, `enabled`, `required_action`, `interaction_range`, `requires` |
| `glitchscout_threat` | enemies and hazards | `type`, `health`, `attack_range`, `state` |
| `glitchscout_observable` | anything else worth watching | `type`, plus any other fields (sent as `properties`) |

The current camera is reported too: position, yaw and pitch, and `mode` from `glitchscout/camera_mode` (default
`third_person`) or the camera's own `glitchscout_observe()`.

## UI

Glitchscout sees buttons, check boxes, option buttons, line edits, sliders, spin boxes and labels, plus any
Control in group `glitchscout_ui`. Give elements stable ids with the `glitchscout_id` metadata (otherwise the
node path is used). It presses buttons the way a player does, by focusing them and pressing `ui_accept`. Only
when a control can't take focus, and for line edits, which react to real keys only, does it activate the control
directly; reports flag those activations. UI inside a `SubViewport` is listed, but its rects are in the
sub-viewport's own pixels, not the screen's.

## Input

Glitchscout plays through your InputMap: every action is available, and so is every virtual axis in
`glitchscout/axes`. Its input arrives as `InputEventAction`s, so both `Input.is_action_pressed()` and `_input()`
handlers see it, exactly from the frame it applies to. It never sends raw key or mouse events.

## Step mode

Glitchscout normally runs the game in **step mode**: it is held from the handshake on, and each STEP from
Glitchscout runs exactly N physics and N idle frames. Launch with `--fixed-fps 60` and
`--audio-driver Dummy` (Glitchscout does this for you). `-- --glitchscout-time=realtime` lets the game run
freely instead, and `-- --glitchscout-step-method=pause` overrides the project setting. Code that reads the
wall clock (`Time.get_ticks_msec()`) sees jumps while the game is held; use `delta` or physics frames.

## Development

Godot 4.7.2 (see `.godot-version`) and Go are needed. Run `scripts/test.sh`.
