#!/bin/bash
# Build OmarchyLock.saver into ./build (theme data is added by mac/theme-sync).
set -euo pipefail
cd "$(dirname "$0")"
B=build/OmarchyLock.saver
rm -rf "$B"; mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources/theme"
clang -fobjc-arc -bundle -O2 -Wall -mmacosx-version-min=14.0 -o "$B/Contents/MacOS/OmarchyLock" OmarchyLockView.m \
  -framework ScreenSaver -framework Cocoa -framework CoreImage -framework CoreText
cat > "$B/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.omaparallels.lock.saver</string>
  <key>CFBundleName</key><string>Omarchy Lock</string>
  <key>CFBundleExecutable</key><string>OmarchyLock</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSPrincipalClass</key><string>OmarchyLockView</string>
</dict></plist>
PL
../../lib/sign.sh "$B" org.omaparallels.lock.saver
echo "built $B"
