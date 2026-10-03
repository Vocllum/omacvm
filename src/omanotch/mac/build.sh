#!/bin/bash
# Build "Omanotch.app" with the Xcode Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Omanotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework QuartzCore -framework Network -lcompression \
  Sources/*.swift -o "$APP/Contents/MacOS/omanotch"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
