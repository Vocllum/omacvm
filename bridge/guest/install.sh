#!/bin/bash
# Install the guest side of omaparallels-bridge. Run as root inside the VM, from this
# directory (the top-level guest/install.sh calls it):
#   ./install.sh <desktop-user>
# Idempotent. Installs:
#   /usr/local/bin/omaparallels-bridge, /usr/local/bin/omaparallels-bridge-osd
#   user service omaparallels-bridge-osd (Omarchy OSD for the Mac's media keys)
#   PipeWire's ALSA/PulseAudio/JACK clients, the VM's own volume pinned at 100 %
#   the bar widgets in ../plugins (omaparallels.wifi, omaparallels.audio)
# The token (~/.config/omaparallels-bridge/token) comes from the Mac, see push-guest.sh.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
as_user() { sudo -u "$U" env XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" "$@"; }

install -m755 omaparallels-bridge omaparallels-bridge-osd /usr/local/bin/
install -m644 omaparallels-bridge-osd.service /etc/systemd/user/omaparallels-bridge-osd.service
systemctl --user -M "$U@" daemon-reload
systemctl --user -M "$U@" enable omaparallels-bridge-osd.service >/dev/null 2>&1
systemctl --user -M "$U@" restart omaparallels-bridge-osd.service

# Audio: PipeWire with ALSA, PulseAudio and JACK clients, so apps share the
# Parallels sound card and Omarchy's input meter works. The Mac owns loudness
# (the bridge sets the Mac's volume), so the VM's own levels stay at full.
if ! pacman -Q pipewire-alsa pipewire-pulse pipewire-jack >/dev/null 2>&1; then
  pacman -Q jack2 >/dev/null 2>&1 && pacman -Rdd --noconfirm jack2 >/dev/null
  pacman -S --needed --noconfirm pipewire-alsa pipewire-pulse pipewire-jack >/dev/null
fi
systemctl --user -M "$U@" restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
sleep 1
amixer -q -c0 sset Master 0dB unmute 2>/dev/null || true
as_user wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 2>/dev/null || true
as_user wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || true

# Bar widgets: the Mac's Wi-Fi and audio, in the slots of Omarchy's own.
for p in ../plugins/*/; do ../../lib/install-plugin.sh "$U" "$p"; done

echo "omaparallels-bridge guest side installed for $U"
