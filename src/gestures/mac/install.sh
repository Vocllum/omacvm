#!/bin/bash
# Install OmacVMGestures.app to ~/Applications and start it at login (LaunchAgent).
#   ./install.sh [--keys-only]
# --keys-only: trackpad gestures stay with macOS; on UTM, Cmd still reaches
# Omarchy as Super.
set -euo pipefail
cd "$(dirname "$0")"
ARGS=""
[[ ${1:-} == --keys-only ]] && ARGS="<string>--keys-only</string>"
./build.sh
LABEL=org.omacvm.gestures
PL=~/Library/LaunchAgents/$LABEL.plist
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf ~/Applications/OmacVMGestures.app
cp -R build/OmacVMGestures.app ~/Applications/
cat > "$PL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/OmacVMGestures.app/Contents/MacOS/omacvm-gestures</string>$ARGS</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/omacvm-gestures.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/omacvm-gestures.log</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$PL"
echo "installed${ARGS:+ (keys only)}; log: ~/Library/Logs/omacvm-gestures.log"
