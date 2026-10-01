#!/bin/bash
# Clipboard, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Mac -> VM is Parallels Tools. VM -> Mac: every copied text goes to the shared
# folder "clip", where omaparallels-clip-in on the Mac puts it on the clipboard.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)

install -m755 parallels-clip-out /usr/local/bin/parallels-clip-out
A=$H/.config/hypr/autostart.lua
grep -q parallels-clip-out "$A" 2>/dev/null ||
  echo 'o.launch_on_start("wl-paste --type text --watch parallels-clip-out")' >> "$A"
# Parallels Tools' invisible clipboard helper window stays out of the tiling layout.
C=$H/.config/hypr/hyprland.lua
grep -q "Parallels Shared Clipboard" "$C" 2>/dev/null || cat clipboard-window-rule.lua >> "$C"
chown "$U:$U" "$A" "$C"
echo "clipboard installed"
