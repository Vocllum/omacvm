#!/bin/bash
# The Mac's battery in Omarchy's bar (UTM, VMware Fusion, OmacVM.app; Parallels
# gives the VM its own). Run as root inside the VM: ./install.sh on|off
#   on:  the omacvm-battery kernel module through DKMS (rebuilt by pacman's
#        DKMS hook for every new kernel that comes with its headers),
#        loaded at boot; the agent omacvm-battery.service that feeds it the
#        Mac's snapshots; UPower never suspends the VM for a low battery
#   off: all of it goes again (dkms and the kernel headers stay installed)
# Idempotent. The module, agent and DKMS steps come from try-omarchy (MIT).
set -euo pipefail
cd "$(dirname "$0")"
NAME=omacvm-battery
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' module/dkms.conf)
SRC=/usr/src/$NAME-$VER
STAMP=/var/lib/omacvm/battery-module
LOG=/var/lib/omacvm/battery-build.log
UPOWER=/etc/UPower/UPower.conf.d/90-omacvm-battery.conf
say() { echo "  battery: $*"; }

if [[ ${1:-} == off ]]; then
  [[ -f /etc/systemd/system/$NAME.service || -d $SRC ]] || exit 0
  systemctl disable --now $NAME.service >/dev/null 2>&1 || true
  modprobe -r omacvm_battery 2>/dev/null || true
  for v in $(dkms status $NAME 2>/dev/null | sed -n "s#^$NAME/\([^,:]*\).*#\1#p" | sort -u); do
    dkms remove "$NAME/$v" --all >/dev/null 2>&1 || true
  done
  rm -rf /usr/src/$NAME-*
  rm -f /etc/systemd/system/$NAME.service /usr/local/bin/$NAME /etc/udev/rules.d/70-omacvm-battery.rules \
    /etc/modules-load.d/omacvm-battery.conf "$UPOWER" "$STAMP"
  systemctl daemon-reload
  systemctl try-restart upower >/dev/null 2>&1 || true
  say "off"
  exit 0
fi
[[ ${1:-} == on ]] || { echo "usage: install.sh on|off" >&2; exit 2; }

# DKMS and the headers of every installed kernel. Arch Linux ARM's headers must
# be the kernel's own version: from the repository when it has that version,
# else from pacman's cache.
pacman -S --needed --noconfirm dkms make gcc >/dev/null 2>&1 || true
for t in dkms make gcc; do
  command -v $t >/dev/null && continue
  say "not installed: pacman could not install $t (no network, or omarchy update first), then omacvm apply"
  exit 1
done
headers() {   # KERNEL_PACKAGE
  local k=$1 have want f
  have=$(pacman -Q "$k" 2>/dev/null | awk '{ print $2 }') || return 0
  [[ -n $have ]] || return 0
  [[ $(pacman -Q "$k-headers" 2>/dev/null | awk '{ print $2 }') == "$have" ]] && return 0
  want=$(pacman -Si "$k-headers" 2>/dev/null | awk '/^Version/ { print $3; exit }') || true
  if [[ $want == "$have" ]]; then
    pacman -S --needed --noconfirm "$k-headers" >/dev/null 2>&1 && return 0
  fi
  f=$(ls /var/cache/pacman/pkg/"$k-headers-$have"-*.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | head -1) || true
  [[ -n $f ]] && pacman -U --noconfirm "$f" >/dev/null 2>&1 && return 0
  say "no $k-headers $have to build with (Arch Linux ARM has ${want:-none}): omarchy update, reboot, then omacvm apply"
}
headers linux-aarch64   # linux-aarch64-thp brings its own (kernel/build-thp-kernel.sh)

# The module's source for DKMS: again when it changed.
sum=$(cat module/* | sha256sum | cut -c1-16)
changed=0
if [[ $(cat "$STAMP" 2>/dev/null) != "$sum" || ! -f $SRC/dkms.conf ]]; then
  changed=1
  for v in $(dkms status $NAME 2>/dev/null | sed -n "s#^$NAME/\([^,:]*\).*#\1#p" | sort -u); do
    dkms remove "$NAME/$v" --all >/dev/null 2>&1 || true
  done
  rm -rf /usr/src/$NAME-*
  install -d "$SRC"
  install -m644 module/omacvm-battery.c module/Makefile module/dkms.conf "$SRC/"
  dkms add "$NAME/$VER" >/dev/null
  install -Dm644 /dev/stdin "$STAMP" <<<"$sum"
fi
# Built for every kernel that has its headers (the running one and any newer).
: > "$LOG"
for b in /usr/lib/modules/*/build; do
  [[ -f $b/Makefile ]] || continue
  k=$(basename "$(dirname "$b")")
  dkms status -k "$k" "$NAME/$VER" 2>/dev/null | grep -q installed && continue
  if dkms install "$NAME/$VER" -k "$k" >> "$LOG" 2>&1; then say "module built for $k"
  else say "the module did not build for $k (log: $LOG)"; fi
done

install -m755 omacvm-battery /usr/local/bin/
install -m644 omacvm-battery.service /etc/systemd/system/
install -m644 70-omacvm-battery.rules /etc/udev/rules.d/
echo omacvm_battery | install -Dm644 /dev/stdin /etc/modules-load.d/omacvm-battery.conf
if ! cmp -s 90-omacvm-battery.conf "$UPOWER"; then
  install -Dm644 90-omacvm-battery.conf "$UPOWER"
  systemctl try-restart upower >/dev/null 2>&1 || true
fi
udevadm control --reload 2>/dev/null; udevadm trigger --subsystem-match=virtio-ports 2>/dev/null || true
systemctl daemon-reload

# Loaded now when this kernel has it (a changed one replaces the old).
systemctl stop $NAME.service 2>/dev/null || true
(( changed )) && modprobe -r omacvm_battery 2>/dev/null || true
if modprobe omacvm_battery 2>/dev/null; then
  systemctl enable $NAME.service >/dev/null 2>&1
  systemctl restart $NAME.service
  say "on"
else
  systemctl enable $NAME.service >/dev/null 2>&1
  say "on after a reboot (no module for the running kernel $(uname -r) yet)"
fi
