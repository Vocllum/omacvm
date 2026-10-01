#!/bin/bash
# Wallpaper, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# The Omarchy background follows to the Mac's wallpaper through OmacVM Bridge
# (needs the bridge client and token, see ../../bridge).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
pacman -S --needed --noconfirm imagemagick file >/dev/null 2>&1
install -m755 omacvm-wallpaper /usr/local/bin/omacvm-wallpaper
install -m644 omacvm-wallpaper.service omacvm-wallpaper.path /etc/systemd/user/
systemctl --user -M "$U@" daemon-reload
systemctl --user -M "$U@" enable --now omacvm-wallpaper.path >/dev/null 2>&1
systemctl --user -M "$U@" enable omacvm-wallpaper.service >/dev/null 2>&1
systemctl --user -M "$U@" start omacvm-wallpaper.service 2>/dev/null || true
echo "wallpaper follows to the Mac"
