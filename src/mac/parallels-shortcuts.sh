#!/bin/bash
# Let Cmd reach Omarchy as Super: empty Parallels' "Linux" keyboard profile,
# which by default rewrites Cmd+C/V/X (and more) to Ctrl before the VM sees
# them. Omarchy then gets Super+C/V/X (universal copy/cut/paste, terminals
# included) like every other Super shortcut.
# App-wide: it applies to every VM that uses the Linux profile. Quit Parallels
# Desktop first. The old profile is kept as Linux.dat.before-omacvm.
# Same as Parallels Desktop > Settings > Shortcuts > Virtual Machines > Linux,
# removing every entry.
set -euo pipefail
D=~/Library/Preferences/Parallels
pgrep -xq prl_client_app && { echo "quit Parallels Desktop first" >&2; exit 1; }
mkdir -p "$D"
[[ -f $D/Linux.dat && ! -f $D/Linux.dat.before-omacvm ]] && cp "$D/Linux.dat" "$D/Linux.dat.before-omacvm"
# Qt data stream: format 3, version 0x231, 1 profile named "Linux", 0 mappings.
echo 00030231000000010000000a004c0069006e00750078000000000000000000000000 | xxd -r -p > "$D/Linux.dat"
echo "Parallels' Linux shortcut profile emptied: Cmd now reaches the VM as Super"
