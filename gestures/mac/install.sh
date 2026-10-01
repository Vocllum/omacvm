#!/bin/bash
# Install OmaparallelsGestures.app to ~/Applications and start it at login (LaunchAgent).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
LABEL=org.omaparallels.gestures
PL=~/Library/LaunchAgents/$LABEL.plist
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf ~/Applications/OmaparallelsGestures.app
cp -R build/OmaparallelsGestures.app ~/Applications/
cat > "$PL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/OmaparallelsGestures.app/Contents/MacOS/omaparallels-gestures</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/omaparallels-gestures.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/omaparallels-gestures.log</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$PL"
echo "installed; log: ~/Library/Logs/omaparallels-gestures.log"
