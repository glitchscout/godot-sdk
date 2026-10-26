#!/usr/bin/env bash
# Installs the pinned GdUnit4 test framework into addons/gdUnit4 (gitignored). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="v6.2.2"
SHA256="53ba53c23328d8f30205acc2f7ffe3d663773847d09b8f48edab1df6a5950571"
DEST="addons/gdUnit4"
STAMP="$DEST/.installed-$TAG"
[[ -f "$STAMP" ]] && exit 0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/gdunit4.tar.gz" "https://github.com/godot-gdunit-labs/gdUnit4/archive/refs/tags/$TAG.tar.gz"
if command -v sha256sum >/dev/null; then
  echo "$SHA256  $tmp/gdunit4.tar.gz" | sha256sum -c - >/dev/null
else
  echo "$SHA256  $tmp/gdunit4.tar.gz" | shasum -a 256 -c - >/dev/null
fi
tar -xzf "$tmp/gdunit4.tar.gz" -C "$tmp"
rm -rf "$DEST"
mv "$tmp/gdUnit4-${TAG#v}/addons/gdUnit4" "$DEST"
touch "$STAMP"
echo "installed GdUnit4 $TAG"
