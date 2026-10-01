#!/bin/bash
# Per-display workspaces, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Every display gets its own workspaces 1..0 (keys and bar), like Spaces on the
# Mac. Unplugging a display parks its workspaces on the main one and replugging
# puts them back (monitor_workspaces.lua).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
install -o "$U" -g "$U" -m644 monitor_workspaces.lua "$H/.config/hypr/monitor_workspaces.lua"
B=$H/.config/hypr/bindings.lua
grep -q 'require("hypr.monitor_workspaces")' "$B" 2>/dev/null || { cat workspace-bindings.lua >> "$B"; chown "$U:$U" "$B"; }
../../lib/install-plugin.sh "$U" ../plugins/omaparallels.workspaces
echo "per-display workspaces installed"
