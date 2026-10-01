#!/bin/bash
LABEL=org.omacvm.gestures
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist
rm -rf ~/Applications/OmacVMGestures.app
echo "removed (macOS gestures are back to normal)"
