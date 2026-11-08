# godot-sdk repo

Public (Apache-2.0). The Glitchscout Godot 4 SDK: the `addons/glitchscout/` addon games install, its tests,
and the Godot fixture game. The repo root is a Godot project used for development and tests.

## Checks

- `scripts/test.sh` is the test loop: it installs the pinned GdUnit4 (`scripts/install_gdunit4.sh`), runs every
  suite in `tests/` headless and prints `GREEN p/t` or `RED p/t`, then validates every protocol message the SDK
  sent during the tests against the `github.com/glitchscout/protocol` schemas (`tools/schemacheck`).
- `scripts/check_sample.sh` checks `samples/starter/` (the getting-started guide's sample, its own Godot project) the way a
  user gets it: the addon copied in, imported, and run headless with no errors. The glitchscout repo's godot CI job runs
  `gscout lint` and `gscout run` on it, and checks the guide shows its feature file as it is.
- `tools/stepbench` (`go run .` from that directory) is the step-overhead benchmark CI gates on: the median STEP
  round trip (OBSERVE then STEP) on an empty scene must stay at or under 5 ms.
- Godot comes from `$GODOT_BIN` or `godot` on PATH and must match `.godot-version`. Bump `.godot-version` and the
  SHA-512 in `scripts/install_godot.sh` together.

## Rules

- This repo is public. Never add orchestrator code, internal planning docs, pricing, internal notes or secrets.
  Only what a game developer or SDK contributor needs belongs here.
- Red → Green → Refactor: write the failing GdUnit4 test first; never edit a test to make it pass.
- GDScript is statically typed. Public classes are prefixed `Glitchscout`; the addon must not add other global names.
- Godot's WebSocketPeer loses a message that arrives in the same poll as a close frame: never send and close in
  one breath (flush, then close a little later), in the SDK or in test mocks.
- Tests that drive a held SDK run their orchestrator on a thread (`ScriptedOrchestrator`). From there, read only
  plain variables the game records (e.g. the fixture player's `last_position`), never node transforms: Godot
  returns zeros for those off the main thread.
- Commits and PR titles start with the ticket key: `GSC-n <imperative summary>`.
- No AI attribution in commits, PRs or review comments.
