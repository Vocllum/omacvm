#!/bin/bash
# VMware Fusion guest specifics. Runs as root in the VM:
#   install.sh <desktop-user> <WxH@Hz: the Mac's display>
set -euo pipefail
U=${1:?usage: install.sh <desktop-user> <WxH@Hz>}
MODE=${2:?usage: install.sh <desktop-user> <WxH@Hz>}
here=$(cd "$(dirname "$0")" && pwd)
H=$(getent passwd "$U" | cut -d: -f6)

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

# The Mac's display mode. Without VMware's tools Fusion pushes no layout to the
# guest, so it starts at the firmware's 1280x800; vmwgfx takes any mode, live
# too. Scale: what Omarchy's scaling menu chose, else 2 on a Retina-size display.
M=$H/.config/hypr/monitors.lua
scale=$(sed -n 's/^local omarchy_monitor_scale = \([0-9.]*\).*/\1/p' "$M" 2>/dev/null | head -1)
[[ -n $scale ]] || { w=${MODE%%x*}; (( w >= 3000 )) && scale=2 || scale=1; }
gdk=$(printf '%.0f' "$scale")
cat > "$M" <<LUA
-- OmacVM, VMware Fusion: the Mac's display. Fusion sends no layout without
-- VMware's tools; any mode can be set here (and live with hyprctl). Omarchy's
-- scaling menu writes omarchy_monitor_scale here.
local omarchy_gdk_scale = ${gdk}
local omarchy_monitor_scale = ${scale}

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "Virtual-1", mode = "$MODE", position = "0x0", scale = omarchy_monitor_scale })
LUA
chown "$U:$U" "$M"
echo "VMware Fusion: public DNS, Hyprland with the vmwgfx fix, display $MODE scale $scale"
