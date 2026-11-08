# Glitchscout starter

A small Godot 4 game to try Glitchscout on: a player, a key and a locked door, with two tests in
`qa/features/first_test.feature`. The [Get started](https://glitchscout.com/docs/getting-started/) guide walks
through it.

1. Copy `addons/glitchscout/` from the root of this repository into `samples/starter/addons/`.
2. Open `samples/starter/project.godot` in Godot 4.7 once, so it imports.
3. From `samples/starter/`:

   ```sh
   gscout lint
   gscout run --godot /path/to/godot --project . --headless --no-model
   ```

| File | What it shows |
|---|---|
| `player.gd` | The `player` group: Glitchscout reads the player's position and velocity on its own |
| `key.gd`, `door.gd` | `glitchscout_interactable` nodes and the fields `glitchscout_observe()` adds |
| `vault.gd` | A registered debug command (`give_item`), game events, and the game state as an observable |
| `project.godot` | The `glitchscout/` settings: the movement axis, the game's events, move speed and jump height |
