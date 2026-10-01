#!/bin/bash
# Build OmaparallelsGestures.app (background-only, ad-hoc signed) into ./build.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/OmaparallelsGestures.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
clang -O2 -Wall -o "$APP/Contents/MacOS/omaparallels-gestures" omaparallels-gestures.c \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework CoreFoundation
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.omaparallels.gestures</string>
  <key>CFBundleName</key><string>Omaparallels Gestures</string>
  <key>CFBundleExecutable</key><string>omaparallels-gestures</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
../../lib/sign.sh "$APP" org.omaparallels.gestures
echo "built $APP"
