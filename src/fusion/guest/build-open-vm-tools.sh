#!/bin/bash
# Build and install open-vm-tools (VMware Tools) for Arch Linux ARM, which
# does not package it: Arch's own package recipe, built for aarch64. Fusion
# sends its display layout (one display per Mac display in full screen, the
# window size in a window) only to a guest that runs VMware Tools. Run as
# root inside the VM: build-open-vm-tools.sh <desktop-user> (makepkg will not
# run as root). Does nothing when the installed build still starts (an update
# of one of its libraries can break it; then it builds again). About 5 minutes.
set -euo pipefail
U=${1:?usage: build-open-vm-tools.sh <desktop-user>}
W=/var/cache/omacvm/open-vm-tools
RECIPE=https://gitlab.archlinux.org/archlinux/packaging/packages/open-vm-tools.git

if pacman -Q open-vm-tools >/dev/null 2>&1 && ! ldd /usr/bin/vmtoolsd 2>/dev/null | grep -q "not found"; then
  echo "open-vm-tools $(pacman -Q open-vm-tools | awk '{ print $2 }') installed"
else
  rm -rf "$W"; mkdir -p "$W"
  git clone -q --depth 1 "$RECIPE" "$W/src"
  cd "$W/src"
  # gtkmm 4 only serves an optional GTK 4 part; Arch Linux ARM's GTK 4 makes
  # configure look for it.
  sed -i 's|    --without-kernel-modules|    --without-kernel-modules --without-gtkmm4|' PKGBUILD
  deps=$(bash -c 'source ./PKGBUILD; echo "${depends[@]} ${makedepends[@]}"' | tr ' ' '\n' | sed 's/[<>=].*//' | sort -u)
  pacman -S --needed --noconfirm base-devel $deps >/dev/null
  chown -R "$U:$U" "$W"
  echo "building open-vm-tools for aarch64 (about 5 minutes)"
  sudo -u "$U" env MAKEFLAGS="-j$(nproc)" makepkg -A --nodeps --noconfirm > "$W/build.log" 2>&1 ||
    { tail -20 "$W/build.log" >&2; echo "build-open-vm-tools: the build failed, full log: $W/build.log" >&2; exit 1; }
  pacman -U --noconfirm "$W"/src/open-vm-tools-*.pkg.tar.* >/dev/null
  rm -rf "$W/src"
  echo "open-vm-tools $(pacman -Q open-vm-tools | awk '{ print $2 }') built and installed"
fi
# Only the display layout is wanted: resolutionKMS hands it to vmwgfx.
install -Dm644 /dev/stdin /etc/vmware-tools/tools.conf <<'CONF'
[resolutionKMS]
enable=true
CONF
systemctl enable vmtoolsd >/dev/null 2>&1
systemctl restart vmtoolsd
