# Glitchscout starter

A small Godot 4 game to try Glitchscout on: a player, a key and a locked door, with two tests in
`qa/features/first_test.feature`. The [Get started](https://glitchscout.com/docs/getting-started/) guide walks
through it.

`gscout init --sample <dir>` writes this folder with the addon in `addons/glitchscout/`, ready to run. From it:

```sh
gscout lint
gscout run --headless --no-model
```

In a clone of the godot-sdk repository the sample has no addon: copy `addons/glitchscout/` from the repository's
root into `samples/starter/addons/` first.

| File | What it shows |
|---|---|
| `player.gd` | The `player` group: Glitchscout reads the player's position and velocity on its own |
| `key.gd`, `door.gd` | `glitchscout_interactable` nodes and the fields `glitchscout_observe()` adds |
| `vault.gd` | A registered debug command (`give_item`), game events, and the game state as an observable |
| `project.godot` | The `glitchscout/` settings: the movement axis, the game's events, move speed and jump height |
