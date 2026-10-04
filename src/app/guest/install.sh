#!/bin/bash
# OmacVM.app specifics, guest side. Run as root inside the VM: ./install.sh <desktop-user>
#  * the display follows the Mac window (omacvm-display-sync, from try-omarchy);
#    in full screen beside the notch, Omarchy's bar fills the strip
#  * Quit on the Mac (the VM's power button) shuts Omarchy down
#  * the clipboard, both ways (omacvm-clipboard, from try-omarchy)
#  * the QEMU guest agent
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
pacman -S --needed --noconfirm qemu-guest-agent python >/dev/null 2>&1 || true
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
install -m755 omacvm-display-sync omacvm-app-host omacvm-clipboard /usr/local/bin/
# Clipboard both ways, over a virtio port (the agent is try-omarchy's).
pacman -S --needed --noconfirm wl-clipboard >/dev/null 2>&1 || true
# uaccess: the logged-in user may open the port (before 73-seat-late.rules).
install -m644 70-omacvm-clipboard.rules /etc/udev/rules.d/
udevadm control --reload 2>/dev/null; udevadm trigger --subsystem-match=virtio-ports 2>/dev/null || true
install -m644 omacvm-clipboard.service /etc/systemd/user/
systemctl --global enable omacvm-clipboard.service >/dev/null 2>&1 || true
systemctl --user -M "$U@" daemon-reload 2>/dev/null && systemctl --user -M "$U@" restart omacvm-clipboard.service 2>/dev/null || true
install -m644 omacvm-app-host.service /etc/systemd/system/
systemctl enable --now omacvm-app-host.service >/dev/null 2>&1 || true
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
