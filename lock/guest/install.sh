#!/bin/bash
# Lock screen, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Publishes the current Omarchy theme (background, lock colours, font) to the
# shared folder "theme" whenever it changes; the Mac side turns it into the
# wallpaper and the Omarchy Lock screen saver.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
pacman -S --needed --noconfirm imagemagick >/dev/null 2>&1
install -m755 omarchy-theme-export /usr/local/bin/omarchy-theme-export
install -m644 omarchy-theme-export.service omarchy-theme-export.path /etc/systemd/user/
systemctl --user -M "$U@" daemon-reload
systemctl --user -M "$U@" enable --now omarchy-theme-export.path >/dev/null 2>&1
systemctl --user -M "$U@" start omarchy-theme-export.service || true
echo "lock screen theme export installed"
