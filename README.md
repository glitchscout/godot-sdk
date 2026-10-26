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

## Development

Godot 4.7.2 (see `.godot-version`) and Go are needed. Run `scripts/test.sh`.
