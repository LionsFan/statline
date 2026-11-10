#!/bin/zsh
# Checks a built StatLine.app: icon present with all sizes, Info.plist wiring, signature.
# Usage: Tests/check-bundle.sh [path/to/StatLine.app]   (default: build/StatLine.app)
set -euo pipefail
cd "${0:A:h}/.."
APP="${1:-build/StatLine.app}"
fail=0
ok()   { print "  ok    $1" }
bad()  { print "  FAIL  $1"; fail=1 }
check() { if eval "$1" >/dev/null 2>&1; then ok "$2"; else bad "$2"; fi }

plist="$APP/Contents/Info.plist"
icns="$APP/Contents/Resources/AppIcon.icns"
check '[[ -x "$APP/Contents/MacOS/StatLine" ]]' "executable exists"
check '[[ "$(plutil -extract CFBundleIconFile raw "$plist")" == AppIcon ]]' "Info.plist CFBundleIconFile = AppIcon"
check '[[ "$(plutil -extract LSUIElement raw "$plist")" == true ]]' "Info.plist LSUIElement = true (menu bar only)"
check '[[ -s "$icns" ]]' "AppIcon.icns is bundled"
check 'cmp -s "$icns" Resources/AppIcon.icns' "bundled icon matches Resources/AppIcon.icns"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if iconutil -c iconset "$icns" -o "$tmp/AppIcon.iconset" 2>/dev/null; then
  for n in 16 32 128 256 512; do
    for scale in 1 2; do
      if (( scale == 2 )); then suffix="@2x"; else suffix=""; fi
      name="icon_${n}x${n}${suffix}.png"
      px=$((n * scale))
      w="$(sips -g pixelWidth "$tmp/AppIcon.iconset/$name" 2>/dev/null | awk '/pixelWidth/{print $2}')"
      [[ "$w" == "$px" ]] && ok "icon $name is ${px}px" || bad "icon $name missing or wrong size (got '${w}')"
    done
  done
else
  bad "AppIcon.icns can be read by iconutil"
fi
check '[[ "$(sips -g pixelWidth docs/icon.png | awk "/pixelWidth/{print \$2}")" == 256 ]]' "README icon docs/icon.png is 256px"
check 'codesign --verify --strict "$APP"' "code signature is valid"

(( fail == 0 )) && print "Bundle checks passed" || { print "Bundle checks failed"; exit 1 }
