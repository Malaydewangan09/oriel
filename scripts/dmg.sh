#!/bin/sh
# Packs dist/Sill.app into a drag-to-Applications disk image for the website.
# Needs a Developer ID signature and notarization before other Macs will open it.
set -eu
cd "$(dirname "$0")/.."
./scripts/bundle.sh
OUT="${1:-dist}"
mkdir -p "$OUT"
# dmgbuild writes the window layout without driving Finder, so it needs no Automation permission.
uvx --python 3.12 dmgbuild -s scripts/dmg-settings.py Sill "$OUT/Sill.dmg" >/dev/null
echo "built $OUT/Sill.dmg"
