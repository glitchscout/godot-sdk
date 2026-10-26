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
| `glitchscout/step/method` | `hold` | How step mode makes the game wait between steps: `hold` blocks the main loop (nothing in the game runs or notices); `pause` pauses the scene tree instead, for games where blocking doesn't work |

## Step mode

Glitchscout normally runs the game in **step mode**: it is held from the handshake on, and each STEP from
Glitchscout runs exactly N physics and N idle frames. Launch with `--fixed-fps 60` and
`--audio-driver Dummy` (Glitchscout does this for you). `-- --glitchscout-time=realtime` lets the game run
freely instead, and `-- --glitchscout-step-method=pause` overrides the project setting. Code that reads the
wall clock (`Time.get_ticks_msec()`) sees jumps while the game is held; use `delta` or physics frames.

## Development

Godot 4.7.2 (see `.godot-version`) and Go are needed. Run `scripts/test.sh`.
