# godot-sdk

Godot 4 addon that lets Glitchscout's AI test agents observe and play your game: input injection, step mode,
navigation queries and screenshots. Compiled out of release builds.

## Install

Copy `addons/glitchscout/` into your project and enable **Glitchscout** under Project → Project Settings →
Plugins. That registers the `Glitchscout` autoload. It does nothing unless Glitchscout launches the game with
`-- --glitchscout-endpoint=… --glitchscout-token=…`, and only in a debug build or one exported with the `qa`
feature tag.

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

## Debug commands

Glitchscout sets up tests with debug commands, and runs only the ones you register (plus four built-ins):

```gdscript
var gs := get_node_or_null("/root/Glitchscout")  # null in a build without the addon
if gs:
    gs.register_command("give_item", _give_item, "Adds items to the inventory", {"item": "string", "count": "int"})

func _give_item(args: Dictionary) -> Variant:
    if not args.has("item"):
        return "give_item needs an item"  # a String refuses the command with that message
    inventory.add(args.item, args.get("count", 1))
    return null                           # null or true: done; a Dictionary: done, sent back as the result
```

The recommended standard set is `set_flag {name, value}`, `god_mode {enabled}`, `load_save {slot | path}`,
`give_item {item, count}` and `set_time {time}`. Built in, and replaced by a registration of the same name:
`teleport {position}`, `load_scene {scene}`, `set_seed {seed}` and `time_scale {scale}`. Unregister commands when
the node that handles them leaves the tree.

## Navigation

Glitchscout plans routes with your `NavigationRegion3D`/`2D` navmesh. Mark how each `NavigationLink3D`/`2D`
is crossed with the `glitchscout_link_type` metadata: `walk`, `jump`, `drop`, `ladder` or `teleport`. Without it,
a link that falls more than one unit counts as `drop`, and any other as `jump`.

**No navmesh?** A grid-based game can call `Glitchscout.use_nav_grid(grid)` with an `AStarGrid2D` whose points are
world positions (`cell * cell_size + offset`). Glitchscout then plans walking paths through cell centres. With
neither, navigation queries fail with `no_navmesh` and the manifest reports `navmesh: false`, so Glitchscout
explores without a map.

Raycasts take physics layer names (Project Settings → Layer Names). A hit reports the `glitchscout_id`
(metadata) of the collider or of its nearest observable ancestor.

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

## Screenshots

Glitchscout's CAPTURE grabs what the viewport last rendered, so it needs a renderer (it is refused in a
`--headless` run). Routine screenshots are kept to 256 KB (JPEG at lower quality, then smaller, as needed);
visual baselines are lossless PNG at full resolution, up to the protocol's 4 MB frame cap. The SDK asks for
a 4 MiB WebSocket send buffer; frames bigger than the buffer it gets go out in chunks, without blocking the
game.

## Events and logs

`gs.event("dialogue_started", {"npc_id": "elder"})`, with `gs` looked up as under Reset, reports a game
event; events sent before the session opens are kept and delivered in order. List the event names your game
sends in the `glitchscout/events` project setting so Glitchscout knows to expect them. Scene changes are
reported as `scene_changed` automatically.

Errors, warnings and printed lines are forwarded as they happen (GDScript and shader errors with their file,
line and function), up to 200 a frame; a flood beyond that is reported as one "log lines dropped" line.

## Reset

Between test runs Glitchscout reloads the current scene. If your game keeps state outside the scene (autoloads,
statics), register a reset that clears it and starts the level afresh:

```gdscript
var gs := get_node_or_null("/root/Glitchscout")
if gs: gs.set_reset_handler(_reset)
```

## Shipping builds

The SDK must not ship. In every release export preset, add `addons/glitchscout/*` to **Resources → Filters to
exclude files**; the addon's export plugin then also drops its autoload and plugin entry from the exported
project settings, and reports an error if a release preset would still include SDK files. A QA build that
should keep the SDK is a release preset with the `qa` custom feature tag and no exclusion. See
`export_presets.cfg` for both. `tools/releasescan` checks an exported pack (`go run . path/to/game.pck`
fails if the SDK is in it); CI runs it on a Release and a QA export.

Code that talks to the SDK should look it up with `get_node_or_null("/root/Glitchscout")`, as above, so it still
runs when the SDK isn't there.

## Development

Godot 4.7.2 (see `.godot-version`) and Go are needed. Run `scripts/test.sh`. Suites that need a real
renderer live in `render_tests/`: `RENDER=1 scripts/test.sh -a res://render_tests` (CI runs them under Xvfb).
