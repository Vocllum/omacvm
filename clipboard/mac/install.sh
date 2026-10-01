#!/bin/bash
# Clipboard, Mac side: VM -> Mac copy. LaunchAgent org.omaparallels.clip-in.
set -euo pipefail
cd "$(dirname "$0")"
LABEL=org.omaparallels.clip-in
D=~/.local/share/omaparallels
mkdir -p "$D/clip" ~/Library/LaunchAgents
install -m755 omaparallels-clip-in "$D/omaparallels-clip-in"
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
cat > ~/Library/LaunchAgents/$LABEL.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$D/omaparallels-clip-in</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$LABEL.plist
echo "clipboard (VM -> Mac) installed; shared folder: $D/clip"
