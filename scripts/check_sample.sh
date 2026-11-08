#!/usr/bin/env bash
# Checks the starter sample the way a new user gets it: samples/starter copied out with addons/glitchscout
# copied into it, imported, then its main scene run headless for 5 seconds of game time. Fails on any engine or
# script error, or if the project isn't where the docs say. Godot comes from $GODOT_BIN, else `godot` on PATH.
# Prints the assembled project's path; KEEP=1 leaves it in place.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT_BIN:-$(command -v godot || true)}"
[[ -x "$GODOT" ]] || { echo "COULD NOT RUN: Godot not found (set GODOT_BIN)"; exit 2; }
[[ -f samples/starter/project.godot ]] || { echo "FAIL: samples/starter/project.godot is missing"; exit 1; }
[[ -z "$(git ls-files samples/starter/addons)" ]] || { echo "FAIL: samples/starter ships its own addons/; the docs copy the addon in"; exit 1; }

dir="$(mktemp -d)/starter"
cp -R samples/starter "$dir"
rm -rf "$dir/addons" "$dir/.godot" "$dir/.glitchscout" # a local copy's, so the check sees what a download has
mkdir -p "$dir/addons"
cp -R addons/glitchscout "$dir/addons/glitchscout"
[[ "${KEEP:-}" == 1 ]] || trap 'rm -rf "$(dirname "$dir")"' EXIT
echo "$dir"

log="$(mktemp)"
"$GODOT" --headless --path "$dir" --import >"$log" 2>&1 || true
"$GODOT" --headless --fixed-fps 60 --audio-driver Dummy --path "$dir" --quit-after 300 >>"$log" 2>&1 || {
  cat "$log"; echo "FAIL: the sample's main scene exited non-zero"; exit 1
}
if grep -E '^(ERROR|SCRIPT ERROR|USER ERROR|Parse Error)' "$log" >/dev/null; then
  cat "$log"; echo "FAIL: errors while importing or running the sample"; exit 1
fi
echo "OK: the starter sample imports and runs clean"
