#!/bin/bash
LABEL=org.omacvm.gestures
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/OmacVMGestures.app"
echo "removed (macOS gestures are back to normal)"
