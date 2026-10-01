#!/bin/bash
# Display sync, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# parallels-dynres makes Hyprland follow what Parallels pushes: the window or
# display size, the refresh rate (120 Hz ProMotion), every external display and
# the macOS arrangement. Needs the read-only shared folder "vmlog" (the VM bundle,
# set up by build.sh) for the arrangement; without it, sizes only.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)

install -m755 parallels-dynres /usr/local/bin/parallels-dynres

# monitors.lua: keep the scale chosen in Omarchy's menu if there already is one.
M=$H/.config/hypr/monitors.lua
scale=$(sed -n 's/^local omarchy_monitor_scale = \([0-9.]*\).*/\1/p' "$M" 2>/dev/null | head -1)
install -o "$U" -g "$U" -m644 monitors.lua "$M"
[[ -n $scale ]] && sed -i "s/^local omarchy_monitor_scale = .*/local omarchy_monitor_scale = $scale/" "$M"

A=$H/.config/hypr/autostart.lua
grep -q parallels-dynres "$A" 2>/dev/null || { echo 'o.launch_on_start("parallels-dynres")' >> "$A"; chown "$U:$U" "$A"; }
echo "display sync installed"
