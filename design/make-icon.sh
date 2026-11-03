#!/bin/bash
# Regenerates Resources/AppIcon.icns and docs/icon.png from design/render.swift.
# Uses only stock macOS tools (swift, iconutil). Review sheet: build/icon-review.png
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift "$ROOT/design/render.swift" "$ROOT" "$TMP"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for n in 16 32 128 256 512; do
  cp "$TMP/size-$n.png" "$SET/icon_${n}x${n}.png"
  cp "$TMP/size-$((n*2)).png" "$SET/icon_${n}x${n}@2x.png"
done
mkdir -p "$ROOT/Resources"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"

# Sanity check: the .icns must round-trip to all 10 representations.
iconutil -c iconset "$ROOT/Resources/AppIcon.icns" -o "$TMP/check.iconset"
count="$(find "$TMP/check.iconset" -name '*.png' | wc -l | tr -d ' ')"
[ "$count" = 10 ] || { echo "expected 10 icon sizes, got $count" >&2; exit 1; }
echo "Wrote Resources/AppIcon.icns ($count sizes), docs/icon.png, build/icon-review.png"
