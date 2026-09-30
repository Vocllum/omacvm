#!/bin/bash
# Stop and remove the macOS helper.
set -euo pipefail
LABEL=ch.gillesgoetsch.notchbar
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x notchbar 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Omarchy Notch Bar.app"
echo "removed (the log ~/Library/Logs/notchbar.log is kept)"
