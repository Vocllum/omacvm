#!/bin/bash
# Build TrackpadBridge.app (background-only, ad-hoc signed) into ./build.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/TrackpadBridge.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
clang -O2 -Wall -o "$APP/Contents/MacOS/trackpad-bridge" trackpad-bridge.c \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework CoreFoundation
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.omaparallels.trackpad-bridge</string>
  <key>CFBundleName</key><string>TrackpadBridge</string>
  <key>CFBundleExecutable</key><string>trackpad-bridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - --identifier org.omaparallels.trackpad-bridge "$APP"
echo "built $APP"
