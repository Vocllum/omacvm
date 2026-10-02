#!/bin/bash
# Build OmacVMGestures.app (background-only, ad-hoc signed) into ./build.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/OmacVMGestures.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
../../icon/make-icns.sh "$APP/Contents/Resources/OmacVM.icns"
clang -O2 -Wall -o "$APP/Contents/MacOS/omacvm-gestures" omacvm-gestures.c \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework AppKit -framework Carbon -framework CoreFoundation
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.omacvm.gestures</string>
  <key>CFBundleName</key><string>OmacVM Gestures</string>
  <key>CFBundleExecutable</key><string>omacvm-gestures</string>
  <key>CFBundleIconFile</key><string>OmacVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
../../lib/sign.sh "$APP" org.omacvm.gestures
echo "built $APP"
