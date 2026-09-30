#!/bin/bash
# Build and install the macOS helper, and start it at login (LaunchAgent).
#   ./mac/install.sh      install / update
#   ./mac/uninstall.sh    remove
set -euo pipefail
cd "$(dirname "$0")"
LABEL=ch.gillesgoetsch.notchbar
APP="$HOME/Applications/Omarchy Notch Bar.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x notchbar 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"
cp -R "build/Omarchy Notch Bar.app" "$APP"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/notchbar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/notchbar.log</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1
launchctl print "gui/$(id -u)/$LABEL" | grep -E "^\s+state" || true
echo "installed: $APP (log: ~/Library/Logs/notchbar.log)"
