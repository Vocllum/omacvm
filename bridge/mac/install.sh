#!/bin/bash
# Install OmaparallelsBridge.app to ~/Applications and start it at login (LaunchAgent).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
LABEL=org.omaparallels.bridge
PL=~/Library/LaunchAgents/$LABEL.plist
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf ~/Applications/OmaparallelsBridge.app
cp -R build/OmaparallelsBridge.app ~/Applications/
# KeepAlive only after a crash: "Quit" in the menu bar stays quit until next login.
cat > "$PL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/OmaparallelsBridge.app/Contents/MacOS/omaparallels-bridge</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/omaparallels-bridge.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/omaparallels-bridge.log</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$PL"
echo "installed; log: ~/Library/Logs/omaparallels-bridge.log"
echo "token: ~/Library/Application Support/omaparallels-bridge/token (apply.sh copies it into the VM)"
