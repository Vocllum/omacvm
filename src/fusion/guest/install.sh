#!/bin/bash
# VMware Fusion guest specifics. Runs as root in the VM: install.sh <desktop-user>
set -euo pipefail
U=${1:?usage: install.sh <desktop-user>}
here=$(cd "$(dirname "$0")" && pwd)

"$here/dns.sh"

# Hyprland with the vmwgfx fix, now and after every hyprland upgrade. The hook
# cannot install packages (pacman's database is locked), so the build tools stay.
install -Dm644 /dev/stdin /etc/pacman.d/hooks/zz-omacvm-hyprland.hook <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = hyprland

[Action]
Description = OmacVM: Hyprland with the vmwgfx fix for VMware Fusion (10 to 20 minutes)
When = PostTransaction
Exec = /usr/local/share/omacvm/fusion/guest/build-hyprland.sh --hook
HOOK
"$here/build-hyprland.sh"
