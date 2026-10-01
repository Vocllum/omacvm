#!/bin/bash
# Install the guest side of omacvm-bridge. Run as root inside the VM, from this
# directory (the top-level guest/install.sh calls it):
#   ./install.sh <desktop-user>
# Idempotent. Installs:
#   /usr/local/bin/omacvm-bridge, /usr/local/bin/omacvm-bridge-osd
#   /usr/local/bin/omarchy-toggle-nightlight (Super+Ctrl+N drives the Mac's Night Shift)
#   /usr/local/bin/omarchy-network-{qr,password} (Omarchy's Wi-Fi QR card shares the Mac's network)
#   user service omacvm-bridge-osd (Omarchy OSD for the Mac's media keys)
#   PipeWire's ALSA/PulseAudio/JACK clients, the VM's own volume pinned at 100 %
#   the bar widgets in ../plugins (omacvm.wifi, omacvm.audio)
# The token (~/.config/omacvm-bridge/token) comes from the Mac, see push-guest.sh.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
as_user() { sudo -u "$U" env XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" "$@"; }

install -m755 omacvm-bridge omacvm-bridge-osd omarchy-toggle-nightlight \
  omarchy-network-qr omarchy-network-password /usr/local/bin/
install -m644 omacvm-bridge-osd.service /etc/systemd/user/omacvm-bridge-osd.service
systemctl --user -M "$U@" daemon-reload
systemctl --user -M "$U@" enable omacvm-bridge-osd.service >/dev/null 2>&1
systemctl --user -M "$U@" restart omacvm-bridge-osd.service

# Audio: PipeWire with ALSA, PulseAudio and JACK clients, so apps share the
# Parallels sound card and Omarchy's input meter works. The Mac owns loudness
# (the bridge sets the Mac's volume), so the VM's own levels stay at full.
if ! pacman -Q pipewire-alsa pipewire-pulse pipewire-jack >/dev/null 2>&1; then
  pacman -Q jack2 >/dev/null 2>&1 && pacman -Rdd --noconfirm jack2 >/dev/null
  pacman -S --needed --noconfirm pipewire-alsa pipewire-pulse pipewire-jack >/dev/null 2>&1
fi
systemctl --user -M "$U@" restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
sleep 1
# Microphone likewise: Parallels hands the Mac's input over at the Mac's level,
# so the VM's source stays at 100 % (it starts out far lower).
amixer -q -c0 sset Master 0dB unmute 2>/dev/null || true
amixer -q -c0 sset Capture 0dB cap 2>/dev/null || true
for dev in @DEFAULT_AUDIO_SINK@ @DEFAULT_AUDIO_SOURCE@; do
  as_user wpctl set-volume "$dev" 1.0 2>/dev/null || true
  as_user wpctl set-mute "$dev" 0 2>/dev/null || true
done

# Bar widgets: the Mac's Wi-Fi and audio, in the slots of Omarchy's own.
for p in ../plugins/*/; do ../../lib/install-plugin.sh "$U" "$p"; done

echo "omacvm-bridge guest side installed for $U"
