#!/bin/bash
# OmacVM.app specifics, guest side. Run as root inside the VM: ./install.sh <desktop-user>
#  * the display follows the Mac window (omacvm-display-sync, from try-omarchy)
#  * macOS draws the pointer, so Hyprland's is hidden
#  * Quit on the Mac (the VM's power button) shuts Omarchy down
#  * the QEMU guest agent
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
pacman -S --needed --noconfirm qemu-guest-agent python >/dev/null 2>&1 || true
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
install -m755 omacvm-display-sync /usr/local/bin/omacvm-display-sync
install -Dm644 90-omacvm-app.conf /etc/environment.d/90-omacvm-app.conf
# Omarchy ignores the power key; here it comes only from the Mac's Quit.
install -Dm644 90-omacvm-app-power.conf /etc/systemd/logind.conf.d/90-omacvm-app-power.conf
install -o "$U" -g "$U" -m644 omacvm_app.lua "$H/.config/hypr/omacvm_app.lua"
B=$H/.config/hypr/hyprland.lua
grep -qxF 'require("hypr.omacvm_app")' "$B" || {
  printf -- '-- OmacVM.app: the display follows the Mac window.\nrequire("hypr.omacvm_app")\n' >> "$B"; chown "$U:$U" "$B"; }
A=$H/.config/hypr/autostart.lua
grep -q omacvm-display-sync "$A" 2>/dev/null || { echo 'o.launch_on_start("omacvm-display-sync")' >> "$A"; chown "$U:$U" "$A"; }
echo "OmacVM.app: display sync, guest agent"
