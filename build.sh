#!/bin/zsh
# Builds StatLine.app and (with --install) copies it to ~/Applications and launches it.
set -euo pipefail
cd "${0:A:h}"
APP=build/StatLine.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos13 -o "$APP/Contents/MacOS/StatLine" Sources/*.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.statline</string>
  <key>CFBundleName</key><string>StatLine</string>
  <key>CFBundleExecutable</key><string>StatLine</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x StatLine 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/StatLine.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/StatLine.app
  echo "Installed and launched ~/Applications/StatLine.app"
fi
