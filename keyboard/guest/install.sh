#!/bin/bash
# Keyboard, guest side. Run as root inside the VM:
#   ./install.sh <desktop-user> <xkb-layout> [xkb-variant]
# (build.sh passes the layout read from the Mac by ../mac-layout.sh)
# Sets the layout in Hyprland and the console, and makes Cmd+V paste everywhere.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> <layout> [variant]}; L=${2:?layout}; V=${3:-}
H=$(getent passwd "$U" | cut -d: -f6)

I=$H/.config/hypr/input.lua
sed -i '/^-- Omaparallels keyboard layout (from the Mac)/,/^})$/d' "$I" 2>/dev/null || true
cat >> "$I" <<LUA
-- Omaparallels keyboard layout (from the Mac)
hl.config({ input = { kb_layout = "$L", kb_variant = "$V" } })
LUA
localectl set-x11-keymap "$L" "" "$V" 2>/dev/null || true

B=$H/.config/hypr/bindings.lua
grep -q '"Universal paste"' "$B" 2>/dev/null || cat mac-paste.lua >> "$B"
chown "$U:$U" "$I" "$B"
echo "keyboard: $L${V:+ ($V)}, Cmd+V paste"
