#!/bin/bash
# Stop and remove Omanotch from the Mac.
set -euo pipefail
for label in ch.gillesgoetsch.omanotch ch.gillesgoetsch.notchbar; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
pkill -x omanotch 2>/dev/null || true
pkill -x notchbar 2>/dev/null || true
rm -rf "$HOME/Applications/Omanotch.app" "$HOME/Applications/Omarchy Notch Bar.app"
echo "removed (the log ~/Library/Logs/omanotch.log is kept)"
