#!/bin/bash
# trackpad-bridge, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Idempotent. Installs the daemon (virtual Apple touchpad fed by the Mac helper)
# and Hyprland's 3/4-finger workspace swipes.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)

pacman -S --needed --noconfirm python-evdev >/dev/null
install -m755 trackpad-bridge /usr/local/bin/trackpad-bridge
install -m644 trackpad-bridge.service /etc/systemd/system/trackpad-bridge.service
systemctl daemon-reload
systemctl enable trackpad-bridge >/dev/null 2>&1
systemctl restart trackpad-bridge

I=$H/.config/hypr/input.lua
if ! grep -q 'hl.gesture({ fingers = 3' "$I" 2>/dev/null; then
  cat >> "$I" <<'LUA'

-- Omaparallels trackpad: the Mac's multi-finger gestures arrive on a virtual
-- touchpad while the VM is full screen. Swipe between workspaces like Spaces.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })
LUA
  chown "$U:$U" "$I"
fi
echo "trackpad-bridge guest side installed"
