#!/bin/zsh
# Builds BatteryPeek.app into ./build. Pass --install to copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/BatteryPeek.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos13 \
  -o "$APP/Contents/MacOS/BatteryPeek" Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.tim.batterypeek</string>
  <key>CFBundleName</key><string>Battery Peek</string>
  <key>CFBundleExecutable</key><string>BatteryPeek</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/BatteryPeek.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/BatteryPeek.app"
fi
