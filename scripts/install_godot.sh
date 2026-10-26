#!/usr/bin/env bash
# Installs the pinned Godot editor binary for Linux x86_64 (CI) into DEST/godot and checks it against the
# SHA-512 recorded here. Usage: scripts/install_godot.sh DEST
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:?usage: install_godot.sh DEST}"
VERSION="$(cat .godot-version)"
ZIP="Godot_v${VERSION}-stable_linux.x86_64.zip"
# From the release's SHA512-SUMS.txt; bump together with .godot-version.
SHA512="9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65"

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$ZIP" "https://github.com/godotengine/godot/releases/download/${VERSION}-stable/$ZIP"
echo "$SHA512  $tmp/$ZIP" | sha512sum -c - >/dev/null
unzip -q "$tmp/$ZIP" -d "$tmp"
mv "$tmp/Godot_v${VERSION}-stable_linux.x86_64" "$DEST/godot"
chmod +x "$DEST/godot"
"$DEST/godot" --version
