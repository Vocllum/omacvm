#!/bin/bash
# Install omarchy-lock on the Mac: screen saver, wallpaper helper, LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
LIB=$HOME/Library/Application\ Support/OmarchyLock
mkdir -p "$LIB" "$HOME/Library/Screen Savers" "$HOME/Library/LaunchAgents"
swiftc -O -o "$LIB/set-wallpaper" set-wallpaper.swift
install -m755 theme-sync "$LIB/theme-sync"
../saver/build.sh >/dev/null
rm -rf "$HOME/Library/Screen Savers/OmarchyLock.saver"
cp -R ../saver/build/OmarchyLock.saver "$HOME/Library/Screen Savers/"
LABEL=org.omaparallels.lock
PL=$HOME/Library/LaunchAgents/$LABEL.plist
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
cat > "$PL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$LIB/theme-sync</string></array>
  <key>WatchPaths</key><array><string>$HOME/.local/share/omaparallels/theme/theme.json</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/omaparallels-lock.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/omaparallels-lock.log</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$PL"
echo "installed; log ~/Library/Logs/omaparallels-lock.log"
