#!/bin/bash
# Install TrackpadBridge.app to ~/Applications and start it at login (LaunchAgent).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
LABEL=org.omaparallels.trackpad-bridge
PL=~/Library/LaunchAgents/$LABEL.plist
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf ~/Applications/TrackpadBridge.app
cp -R build/TrackpadBridge.app ~/Applications/
cat > "$PL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/TrackpadBridge.app/Contents/MacOS/trackpad-bridge</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/trackpad-bridge.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/trackpad-bridge.log</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$PL"
echo "installed; log: ~/Library/Logs/trackpad-bridge.log"
