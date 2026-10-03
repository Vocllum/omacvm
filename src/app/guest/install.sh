#!/bin/bash
# OmacVM.app specifics, guest side. Run as root inside the VM: ./install.sh <desktop-user>
#  * the display follows the Mac window (omacvm-display-sync, from try-omarchy);
#    in full screen beside the notch, Omarchy's bar fills the strip
#  * macOS draws the pointer, so Hyprland's is hidden
#  * Quit on the Mac (the VM's power button) shuts Omarchy down
#  * sound (PipeWire's ALSA and PulseAudio parts)
#  * the QEMU guest agent
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
pacman -S --needed --noconfirm qemu-guest-agent python >/dev/null 2>&1 || true
# Sound: omarchy-mac installs PipeWire's ALSA and PulseAudio parts only on Apple
# hardware; the VM has an Intel HDA card (QEMU plays it on the Mac).
# pipewire-jack replaces jack2 (as in bridge/guest/install.sh).
if ! pacman -Q pipewire-alsa pipewire-pulse pipewire-jack rtkit >/dev/null 2>&1; then
  pacman -Q jack2 >/dev/null 2>&1 && pacman -Rdd --noconfirm jack2 >/dev/null
  pacman -S --needed --noconfirm pipewire-alsa pipewire-pulse pipewire-jack rtkit >/dev/null 2>&1 || true
fi
systemctl --user -M "$U@" restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
install -m755 omacvm-display-sync omacvm-app-host /usr/local/bin/
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
