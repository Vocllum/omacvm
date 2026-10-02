#!/bin/bash
# Build and install linux-aarch64-thp: Arch Linux ARM's current linux-aarch64,
# with transparent huge pages "always" and MGLRU on (see thp-pkgbuild.py).
# Run as root inside the VM: ./build-thp-kernel.sh <desktop-user>
# Takes ~10 min on 16 vCPUs. The stock kernel stays installed as the fallback
# entry in GRUB's advanced menu; GRUB boots the THP kernel by default.
# Re-run it to follow a new ALARM kernel release; when the installed one is
# already ALARM's current release it does nothing (OMACVM_REBUILD_KERNEL=1
# builds anyway).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
U=${1:?usage: build-thp-kernel.sh <desktop-user>}
ALARM=https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/linux-aarch64
W=$(getent passwd "$U" | cut -d: -f6)/.cache/omacvm/linux-aarch64-thp

latest=$(curl -fsSL "$ALARM/PKGBUILD" | sed -n 's/^pkgver=//p; s/^pkgrel=//p' | paste -sd- -)
have=$(pacman -Q linux-aarch64-thp 2>/dev/null | awk '{ print $2 }')
if [[ -n $latest && $have == "$latest" && -z ${OMACVM_REBUILD_KERNEL:-} ]]; then
  echo "linux-aarch64-thp $have is ALARM's current kernel: nothing to build"
  exit 0
fi
pacman -S --needed --noconfirm xmlto docbook-xsl kmod inetutils bc git dtc python pahole cpio base-devel >/dev/null 2>&1
rm -rf "$W"; install -d -o "$U" -g "$U" "$W"
cd "$W"
curl -fsSL "$ALARM/PKGBUILD" -o PKGBUILD
for f in linux.preset linux-aarch64.install $(sed -n "/^source=(/,/)/p" PKGBUILD | grep -o "'[^':]*'" | tr -d "'"); do
  curl -fsSL "$ALARM/$f" -o "$f"
done
python3 "$here/thp-pkgbuild.py" "$W"
chown -R "$U:$U" "$W"
# makepkg builds with one job unless told otherwise: use every vCPU.
sudo -u "$U" env MAKEFLAGS="-j$(nproc)" makepkg --noconfirm --cleanbuild
pacman -U --noconfirm "$W"/linux-aarch64-thp-[0-9]*.pkg.tar.* "$W"/linux-aarch64-thp-headers-*.pkg.tar.*

# GRUB: boot the THP kernel by default.
G=/etc/default/grub
grep -q '^GRUB_TOP_LEVEL=' $G || echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux-aarch64-thp"' >> $G
grep -q '^GRUB_DISABLE_LINUX_UUID=' $G || echo 'GRUB_DISABLE_LINUX_UUID=false' >> $G
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -2
echo "linux-aarch64-thp installed; reboot to use it"
