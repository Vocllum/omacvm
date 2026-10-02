#!/bin/bash
# Install OmacVMGestures.app to ~/Applications and start it at login (LaunchAgent).
#   ./install.sh [--keys-only | --scroll]
# --keys-only: trackpad gestures stay with macOS; on UTM, Cmd still reaches
# Omarchy as Super. --scroll: two-finger scrolling goes to Omarchy's virtual
# touchpad too (only one-finger movement and clicks stay with the VM app).
set -euo pipefail
cd "$(dirname "$0")"
ARGS=""
for a in "$@"; do
  case $a in
    --keys-only|--scroll|-v|--record) ARGS+="<string>$a</string>" ;;
    *) echo "install.sh: unknown option $a" >&2; exit 2 ;;
  esac
done
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
echo "installed${ARGS:+ ($*)}; log: ~/Library/Logs/omacvm-gestures.log"
