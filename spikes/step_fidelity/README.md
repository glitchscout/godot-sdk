# Step-fidelity spike: hold mode vs pause mode

Glitchscout steps a game frame by frame and leaves it waiting while the test agent decides what to do next.
This spike measured the two ways the Godot SDK can make the game wait, on Godot 4.7.2 (2026-10-26):

- **Hold mode:** the SDK node runs first in every frame (lowest `process_priority`, `PROCESS_MODE_ALWAYS`).
  When its step budget is spent, it blocks the main loop until the next step arrives, calling
  `DisplayServer.process_events()` every ~1 ms so the OS keeps seeing a live window.
- **Pause mode:** `get_tree().paused = true` between steps, unpaused for exactly one frame per step.

## Method

`step_fidelity.tscn` builds one pausable "game" with a probe of each kind of game-time machinery, then
runs 600 one-frame steps at `--fixed-fps 60` (physics 60 Hz) with a 20 ms wait between steps:

- physics and idle callbacks;
- a node with `PROCESS_MODE_ALWAYS` (menus and UI that animate while paused);
- idle and physics `Timer`s (0.25 s);
- an `AnimationPlayer` track and a `Tween`;
- a one-shot `CPUParticles2D` (0.5 s lifetime);
- `NOTIFICATION_PAUSED`;
- an `AudioStreamGenerator` fed every frame (`get_skips()` counts underruns);
- the largest wall-clock jump the game sees between frames;
- the largest gap between OS event pumps while held.

```sh
godot --path . --fixed-fps 60 [--headless] [--audio-driver Dummy] \
  res://spikes/step_fidelity/step_fidelity.tscn -- --mode=hold|pause [--steps=600] [--hold-ms=20] [--out=FILE]
```

## Results

"Expected" is the value after 600 frames of game time (10 s). Hardware: Apple Silicon Mac (macOS 27);
the headless rows are CI conditions.

| Probe | Expected | Hold, headless | Pause, headless | Hold, headed, Dummy audio | Hold, headed, CoreAudio | Pause, headed, CoreAudio |
|---|---|---|---|---|---|---|
| Physics callbacks per step | 1 | 1.002 | 1.002 | 1.002 | 1.002 | 1.002 |
| Idle callbacks per step | 1 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| `ALWAYS` node idle callbacks per step | 1 | **1.000** | **4635.6** | **1.000** | **1.000** | **3.392** |
| Idle `Timer` timeouts | 40 | 39 | 39 | 39 | 39 | 39 |
| Physics `Timer` timeouts | 40 | 40 | 40 | 40 | 40 | 40 |
| `AnimationPlayer` frames off | 0 | 1 | 1 | 1 | 1 | 1 |
| `Tween` frames off | 0 | 0 | 0 | 0 | 0 | 0 |
| One-shot particles finished at step | 30 | 31 | 31 | 31 | 31 | 31 |
| `NOTIFICATION_PAUSED` received | 0 | **0** | **600** | **0** | **0** | **600** |
| Audio underruns | 0 | 0 | 0 | 32 | 3 | 14 |
| Largest wall-clock jump seen by the game (ms) | 16.7 | 41 | 28 | 90 | 96 | 64 |
| Largest gap between OS event pumps (ms) | — | 10.9 | — | 21.4 | 24.2 | — |
| Wall time for 600 steps (s) | — | 12.6 | 12.1 | 14.6 | 14.6 | 22.0 |

The one-frame differences for idle Timers, animation and particles appear in every column. They come from
sampling at the start of a frame, before idle-processed nodes have run, not from either mode.

## Findings

1. **Pausable game state steps identically in both modes.** Physics and idle stay 1:1. Timers, animations,
   tweens and particles follow game time exactly.
2. **Pause mode leaks into the game. Hold mode doesn't.**
   - Nodes set to `PROCESS_MODE_ALWAYS` keep running while the tree is paused: thousands of extra frames per
     step headless (frames spin as fast as possible under `--fixed-fps`), several per step headed (vsync).
     Menus, HUD animation and anything else the game marks `ALWAYS` drift away from game time.
   - The game receives a `NOTIFICATION_PAUSED` on every step, so games with their own pause handling react
     600 times in 10 s of game time.
   - In hold mode nothing in the game runs between steps, so there is nothing to leak.
3. **Hold mode keeps a headed window responsive** with `DisplayServer.process_events()`. The largest gap
   between pumps was 24 ms, far below the seconds it takes macOS to mark an app "not responding".
4. **Hold mode is faster headed:** 14.6 s against 22.0 s for 600 steps. Each pause-mode step costs
   at least two displayed frames.
5. **Audio can't follow stepped time in either mode.** Underruns appear whenever audio mixes in real time
   (any headed run, including Godot's Dummy driver, whose mixer thread keeps running). Step-mode runs use
   `--audio-driver Dummy`: nothing is audible, nothing depends on a sound device, and headless runs see no
   underruns at all.
6. **Known limit of hold mode:** game code that reads the wall clock (`Time.get_ticks_msec()`) sees jumps
   of the wait time between steps (here up to 96 ms). Game logic should use `delta` or physics frames.

## Conclusion

Hold mode is the default. Pause mode stays as a fallback for games where blocking the main loop is
incompatible, with the side effects above documented. The OS event-pumping call for headed hold mode is
`DisplayServer.process_events()`.
