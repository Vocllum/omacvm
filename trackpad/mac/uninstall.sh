#!/bin/bash
LABEL=org.omaparallels.trackpad-bridge
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist
rm -rf ~/Applications/TrackpadBridge.app
echo "removed (macOS gestures are back to normal)"
