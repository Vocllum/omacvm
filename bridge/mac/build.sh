#!/bin/bash
# Build OmacVMBridge.app (agent app, no Dock icon) into ./build and sign it.
# Signed by ../../lib/sign.sh (permissions survive rebuilds; SIGN_IDENTITY for a
# real certificate).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/OmacVMBridge.app
ID=org.omacvm.bridge
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$APP/Contents/MacOS/omacvm-bridge" main.swift wifi.swift audio.swift server.swift keys.swift display.swift \
  -framework AppKit -framework CoreWLAN -framework CoreLocation -framework CoreAudio -framework AudioToolbox -framework ApplicationServices -framework Security
WHY="OmacVM Bridge reads the name of the Wi-Fi network this Mac is on, and of nearby networks, to show them in your Linux VM's status bar. macOS only reveals Wi-Fi network names to apps with Location Services access. No location is ever read or stored."
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>OmacVM Bridge</string>
  <key>CFBundleDisplayName</key><string>OmacVM Bridge</string>
  <key>CFBundleExecutable</key><string>omacvm-bridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>$WHY</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>$WHY</string>
</dict></plist>
PL
../../lib/sign.sh "$APP" "$ID"
echo "built $APP"
