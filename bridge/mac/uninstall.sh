#!/bin/bash
# Remove OmacVM Bridge from this Mac. --purge also deletes the token and config.
LABEL=org.omacvm.bridge
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist
rm -rf ~/Applications/OmacVMBridge.app
tccutil reset Accessibility $LABEL >/dev/null 2>&1 || true
[[ ${1:-} == --purge ]] && rm -rf ~/Library/Application\ Support/omacvm-bridge ~/Library/Logs/omacvm-bridge.log
echo "removed (media keys are back to macOS). Location Services: remove OmacVM Bridge in"
echo "System Settings > Privacy & Security > Location Services if it is still listed."
