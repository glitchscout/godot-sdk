#!/usr/bin/env bash
# The repo's test loop: GdUnit4 suites headless, then a protocol schema check of every message the SDK
# sent during them. Prints GREEN p/t or RED p/t. Args go to GdUnit4 (default: -a res://tests).
# Godot comes from $GODOT_BIN, else `godot` on PATH; the version must match .godot-version.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT_BIN:-$(command -v godot || true)}"
[[ -x "$GODOT" ]] || { echo "COULD NOT RUN: Godot not found (set GODOT_BIN)"; exit 2; }
want="$(cat .godot-version)"
have="$("$GODOT" --version | head -1)"
[[ "$have" == "$want".* ]] || { echo "COULD NOT RUN: Godot $have, want $want"; exit 2; }

scripts/install_gdunit4.sh
rm -rf reports
mkdir -p reports/messages
# Import once so class_name caches exist for the test runner.
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

(( $# )) || set -- -a res://tests
set +e
"$GODOT" --headless --path . -s -d --remote-debug tcp://127.0.0.1:0 \
  res://addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -c -rd res://reports "$@"
status=$?
set -e

results="$(ls -t reports/report_*/results.xml 2>/dev/null | head -1 || true)"
[[ -n "$results" ]] || { echo "COULD NOT RUN: no GdUnit4 results (exit $status)"; exit 2; }
# A test case fails if it holds any <failure> or <error> (GdUnit4's failures attribute counts assertions).
read -r total failed < <(awk '
  /<testcase /                         { n++; cur = n }
  /<(failure|error)[ >]/ && !bad[cur]  { bad[cur] = 1; f++ }
  END                                  { print n + 0, f + 0 }' "$results")
passed=$((total - failed))

schema_status=0
(cd tools/schemacheck && go run . ../../reports/messages) || schema_status=$?

if (( status == 0 && failed == 0 && schema_status == 0 )); then
  echo "GREEN $passed/$total"
  exit 0
fi
echo "RED $passed/$total (gdunit exit $status, schemacheck exit $schema_status)"
exit 1
