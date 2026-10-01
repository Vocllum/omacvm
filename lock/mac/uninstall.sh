#!/bin/bash
LABEL=org.omacvm.lock
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist
rm -rf ~/Library/Screen\ Savers/OmarchyLock.saver ~/Library/Application\ Support/OmarchyLock
echo "removed (wallpaper stays as it is)"
