#!/bin/bash
LABEL=org.omaparallels.clip-in
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist ~/.local/share/omaparallels/omaparallels-clip-in
echo "clipboard (VM -> Mac) removed"
