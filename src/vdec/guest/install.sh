#!/bin/bash
# Chromium's video decoding on the Mac's media engine (OmacVM.app). Run as root
# inside the VM: ./install.sh <desktop-user> on|off
#   on:  the omacvm-vdec kernel module (a V4L2 video decoder) through DKMS,
#        rebuilt by pacman's DKMS hook for every new kernel with its headers;
#        omacvm-vdecd, which decodes for it with VA-API (the app's VideoToolbox
#        backend); Chromium's switch for its V4L2 decoder in the user's flags,
#        and an extension that has YouTube send VP9 instead of AV1 (this
#        Chromium decodes AV1 only on the CPU)
#   off: all of it goes again (dkms and the kernel headers stay installed)
# Arch Linux ARM's Chromium has no VA-API, only V4L2: see docs/adr/0025.
# Google Chrome and Brave use VA-API directly and need none of this.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> on|off}; ON=${2:?on|off}
NAME=omacvm-vdec
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' module/dkms.conf)
SRC=/usr/src/$NAME-$VER
STAMP=/var/lib/omacvm/vdec-module
LOG=/var/lib/omacvm/vdec-build.log
LIB=/usr/local/lib/omacvm
say() { echo "  Chromium video: $*"; }
as_user() { runuser -u "$U" -- env -i PATH=/usr/bin:/bin "$@"; }

if [[ $ON == off ]]; then
  [[ -f /etc/systemd/system/omacvm-vdecd.service || -d $SRC ]] || exit 0
  [[ -x $LIB/chromium-flags.py ]] && as_user "$LIB/chromium-flags.py" off || true
  systemctl disable --now omacvm-vdecd.service >/dev/null 2>&1 || true
  modprobe -r omacvm_vdec 2>/dev/null || true
  for v in $(dkms status $NAME 2>/dev/null | sed -n "s#^$NAME/\([^,:]*\).*#\1#p" | sort -u); do
    dkms remove "$NAME/$v" --all >/dev/null 2>&1 || true
  done
  rm -rf /usr/src/$NAME-*
  rm -rf /usr/local/share/omacvm/chromium-no-av1
  rm -f /etc/systemd/system/omacvm-vdecd.service /usr/local/bin/omacvm-vdecd "$LIB/chromium-flags.py" \
    /etc/udev/rules.d/70-omacvm-vdec.rules /etc/modules-load.d/omacvm-vdec.conf \
    /etc/sysusers.d/omacvm-vdec.conf "$STAMP"
  systemctl daemon-reload
  say "off"
  exit 0
fi
[[ $ON == on ]] || { echo "usage: install.sh <desktop-user> on|off" >&2; exit 2; }
command -v chromium >/dev/null || { say "no Chromium, nothing to do"; exit 0; }

pacman -S --needed --noconfirm dkms make gcc ffmpeg libva mesa >/dev/null 2>&1 || true
for t in dkms make gcc; do
  command -v $t >/dev/null && continue
  say "not installed: pacman could not install $t (no network, or omarchy update first), then omacvm apply"
  exit 1
done
# The kernel's own headers (as battery/guest/install.sh does).
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
headers linux-aarch64

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
  install -m644 module/omacvm-vdec.c module/omacvm-vdec.h module/Makefile module/dkms.conf "$SRC/"
  dkms add "$NAME/$VER" >/dev/null
  install -Dm644 /dev/stdin "$STAMP" <<<"$sum"
fi
: > "$LOG"
for b in /usr/lib/modules/*/build; do
  [[ -f $b/Makefile ]] || continue
  k=$(basename "$(dirname "$b")")
  dkms status -k "$k" "$NAME/$VER" 2>/dev/null | grep -q installed && continue
  if dkms install "$NAME/$VER" -k "$k" >> "$LOG" 2>&1; then say "module built for $k"
  else say "the module did not build for $k (log: $LOG)"; fi
done

# The daemon, built here against the VM's FFmpeg, libva and Mesa.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pkgs="libva libva-drm egl glesv2 gbm libdrm libavcodec libavutil"
# shellcheck disable=SC2046
if ! cc -O2 -Wall -Imodule -o "$T/omacvm-vdecd" omacvm-vdecd.c $(pkg-config --cflags --libs $pkgs) >> "$LOG" 2>&1; then
  say "the daemon did not build (log: $LOG)"
  exit 1
fi
systemctl stop omacvm-vdecd.service 2>/dev/null || true
install -m755 "$T/omacvm-vdecd" /usr/local/bin/omacvm-vdecd
install -Dm755 chromium-flags.py "$LIB/chromium-flags.py"
install -Dm644 -t /usr/local/share/omacvm/chromium-no-av1 no-av1/manifest.json no-av1/no-av1.js
install -Dm644 omacvm-vdec.sysusers /etc/sysusers.d/omacvm-vdec.conf
systemd-sysusers /etc/sysusers.d/omacvm-vdec.conf
install -m644 70-omacvm-vdec.rules /etc/udev/rules.d/
install -m644 omacvm-vdecd.service /etc/systemd/system/
echo omacvm_vdec | install -Dm644 /dev/stdin /etc/modules-load.d/omacvm-vdec.conf
udevadm control --reload 2>/dev/null || true
systemctl daemon-reload
systemctl enable omacvm-vdecd.service >/dev/null 2>&1

as_user "$LIB/chromium-flags.py" on || say "Chromium's flags file not changed (see above)"

# Loaded now when this kernel has it (a changed one replaces the old).
(( changed )) && modprobe -r omacvm_vdec 2>/dev/null || true
if modprobe omacvm_vdec 2>/dev/null; then
  udevadm trigger --subsystem-match=misc --sysname-match=omacvm-vdec 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  systemctl restart omacvm-vdecd.service || true
  say "on (restart Chromium once)"
else
  say "on after a reboot (no module for the running kernel $(uname -r) yet)"
fi
