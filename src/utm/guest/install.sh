#!/bin/bash
# UTM specifics, guest side. Run as root inside the VM:
#   ./install.sh <desktop-user> <WIDTHxHEIGHT@HZ>
# (apply.sh passes the Mac's built-in display below the notch, display/mac-display.swift)
#  * UTM's guest tools: the SPICE daemon with OmacVM's Wayland session agent
#    (clipboard both ways, pointer over the whole screen; the stock agent is
#    X11-only and sizes the pointer wrong under Hyprland) and the QEMU guest
#    agent (utmctl ip-address / exec / file push)
#  * virtio-gpu workarounds for Hyprland
#  * the GPU for Chrome and other Chromium browsers (virgl-msaa.c)
#  * a fixed display mode from boot: UTM's GPU path goes blank when the mode
#    changes while running, and "preferred" is only 1280x800
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> <WxH@Hz>}; MODE=${2:?display mode}
H=$(getent passwd "$U" | cut -d: -f6)
pacman -S --needed --noconfirm spice-vdagent qemu-guest-agent wl-clipboard python >/dev/null 2>&1
systemctl enable --now qemu-guest-agent spice-vdagentd >/dev/null 2>&1 || true
install -m755 omacvm-vdagent /usr/local/bin/omacvm-vdagent
install -m644 omacvm-vdagent.service /etc/systemd/user/omacvm-vdagent.service
systemctl --global mask spice-vdagent.service >/dev/null 2>&1
systemctl --global enable omacvm-vdagent.service >/dev/null 2>&1
# swap agents in a running session too
if systemctl --user -M "$U@" daemon-reload 2>/dev/null; then
  systemctl --user -M "$U@" stop spice-vdagent.service 2>/dev/null || true
  systemctl --user -M "$U@" restart omacvm-vdagent.service 2>/dev/null || true
fi
install -Dm644 90-omacvm-utm.conf /etc/environment.d/90-omacvm-utm.conf

# GPU in Chrome and other Chromium browsers: see virgl-msaa.c. Built here, as
# the kernel headers it needs come with the VM.
pacman -S --needed --noconfirm gcc >/dev/null 2>&1
L=/usr/local/lib/omacvm/virgl-msaa.so
install -d /usr/local/lib/omacvm
gcc -shared -fPIC -O2 -o "$L.new" virgl-msaa.c -ldl && mv -f "$L.new" "$L"
grep -qx "$L" /etc/ld.so.preload 2>/dev/null || echo "$L" >> /etc/ld.so.preload

M=$H/.config/hypr/monitors.lua
scale=$(sed -n 's/^local omarchy_monitor_scale = \([0-9.]*\).*/\1/p' "$M" 2>/dev/null | head -1)
cat > "$M" <<LUA
-- OmacVM, UTM: the Mac's built-in display below the notch, fixed from boot.
-- UTM's virtio-gpu (virgl) goes blank when the mode changes while running, so
-- do not switch modes live; edit and reboot instead. Omarchy's scaling menu
-- writes omarchy_monitor_scale here.
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = ${scale:-2}

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "Virtual-1", mode = "$MODE", position = "0x0", scale = omarchy_monitor_scale })
LUA
chown "$U:$U" "$M"
echo "UTM: guest tools, virtio-gpu settings, browser GPU, display $MODE"
