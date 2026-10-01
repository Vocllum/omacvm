#!/bin/bash
# Walk the user through Parallels' "Send macOS system shortcuts: Always"
# (Settings > Shortcuts > macOS System Shortcuts), which lets Cmd+Space,
# Cmd+Tab and friends reach Omarchy. Parallels keeps that setting to itself (no
# CLI, preference key or VM setting), so OmacVM can only ask: an alert, then
# Parallels Desktop opens with its Settings preselected on that page and a
# visual guide beside it, and a second alert confirms once the setting is on.
# build.sh and apply.sh run this in the background while the setting is
# missing; run it again any time.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
source "$R/lib/mac.sh"
parallels_sends_shortcuts && { echo "Parallels already sends macOS system shortcuts to the VM"; exit 0; }

# alert TITLE MESSAGE BUTTON... -> the button clicked (the last one is the default)
alert() {
  osascript - "$@" 2>/dev/null <<'EOF'
on run argv
  set b to items 3 thru -1 of argv
  return button returned of (display alert (item 1 of argv) message (item 2 of argv) buttons b default button (count of b))
end run
EOF
}

PATH_TXT='Settings… (Cmd+,) › Shortcuts › macOS System Shortcuts › Send macOS system shortcuts: Always'
a=$(alert "OmacVM: one setting in Parallels Desktop" \
"So Cmd+Space, Cmd+Tab and the other Cmd shortcuts reach Omarchy, set this once in Parallels Desktop:

$PATH_TXT

Parallels does not let other apps change it, so this is the one step you do by hand: click Open, and a picture shows where to click. OmacVM confirms when it is set." \
  "Later" "Open Parallels Desktop")
[[ $a == "Open Parallels Desktop" ]] || exit 0

# Parallels' Settings open on the page shown last: make that Shortcuts >
# macOS System Shortcuts.
defaults write "com.parallels.Parallels Desktop" "Application preferences.Last selected page" -int 1
defaults write "com.parallels.Parallels Desktop" "Application preferences.ShortcutPageLastSelectedItem" -int 6
open -a "Parallels Desktop"
# The visual guide (docs/parallels-shortcuts.svg) beside it, in Quick Look.
sleep 1.5
qlmanage -p "$R/docs/parallels-shortcuts.svg" >/dev/null 2>&1 &
QL=$!
trap 'kill $QL 2>/dev/null' EXIT

# Confirm as soon as Parallels has saved it (give up quietly after 15 minutes;
# check.sh still reports it).
for _ in $(seq 450); do
  sleep 2
  if parallels_sends_shortcuts; then
    kill $QL 2>/dev/null
    alert "✓ Parallels sends macOS shortcuts to Omarchy" \
      "Cmd+Space, Cmd+Tab and the other Cmd shortcuts now reach Omarchy while the VM window is in front." "OK" >/dev/null
    exit 0
  fi
done
