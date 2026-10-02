#!/bin/bash
LABEL=org.omacvm.clip-in
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/share/omacvm/omacvm-clip-in"
echo "clipboard (VM -> Mac) removed"
