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

# Displays: VMware Tools brings Fusion's layout (every Mac display in full
# screen, the window size in a window) to vmwgfx; omacvm-fusion-displays puts
# Hyprland's monitors where it says. monitors.lua starts every output at its
# preferred mode, the Mac's display mode until the layout arrives. Scale: what
# Omarchy's scaling menu chose, else 2 on a Retina-size display.
"$here/build-open-vm-tools.sh" "$U"
install -m644 "$here/omacvm-fusion-displays.service" /etc/systemd/user/omacvm-fusion-displays.service
systemctl --global enable omacvm-fusion-displays.service >/dev/null 2>&1
M=$H/.config/hypr/monitors.lua
scale=$(sed -n 's/^local omarchy_monitor_scale = \([0-9.]*\).*/\1/p' "$M" 2>/dev/null | head -1)
[[ -n $scale ]] || { w=${MODE%%x*}; (( w >= 3000 )) && scale=2 || scale=1; }
gdk=$(printf '%.0f' "$scale")
cat > "$M" <<LUA
-- OmacVM, VMware Fusion: every output VMware Fusion gives the VM (one per Mac
-- display in full screen), placed by omacvm-fusion-displays as Fusion lays them
-- out. Virtual-1 starts at the Mac's display mode until Fusion's layout
-- arrives. Omarchy's scaling menu writes omarchy_monitor_scale here.
local omarchy_gdk_scale = ${gdk}
local omarchy_monitor_scale = ${scale}

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "Virtual-1", mode = "$MODE", position = "0x0", scale = omarchy_monitor_scale })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
LUA
chown "$U:$U" "$M"
if systemctl --user -M "$U@" daemon-reload 2>/dev/null; then
  systemctl --user -M "$U@" restart omacvm-fusion-displays.service 2>/dev/null || true
fi
echo "VMware Fusion: public DNS, Hyprland with the vmwgfx fix, VMware Tools, displays (first: $MODE, scale $scale)"
