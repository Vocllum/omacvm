#!/bin/bash
# Clipboard, Mac side: VM -> Mac copy. LaunchAgent org.omacvm.clip-in.
set -euo pipefail
cd "$(dirname "$0")"
LABEL=org.omacvm.clip-in
D=$HOME/.local/share/omacvm
mkdir -p "$D/clip" "$HOME/Library/LaunchAgents"
install -m755 omacvm-clip-in "$D/omacvm-clip-in"
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
cat > "$HOME/Library/LaunchAgents/$LABEL.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$D/omacvm-clip-in</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "clipboard (VM -> Mac) installed; shared folder: $D/clip"
