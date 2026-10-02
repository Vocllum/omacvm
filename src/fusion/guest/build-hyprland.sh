#!/bin/bash
# Build and install Hyprland with the vmwgfx fix (hyprland-vmwgfx-dmabuf.patch):
# without it no GPU client survives on VMware Fusion, SDDM's greeter included,
# and the VM shows a black screen. Run as root inside the VM.
#   build-hyprland.sh [--hook]
# Builds the release of the installed hyprland package, so it fits the rest of
# Omarchy's pinned Hyprland stack; the package's own binary is kept beside it
# (Hyprland.stock). Does nothing when the installed binary already is the
# patched build of that release. A pacman hook (--hook: no pacman calls, its
# database is locked then) runs it again after every hyprland upgrade.
# Takes 10 to 20 minutes on 4 vCPUs. OMACVM_REBUILD_HYPRLAND=1 builds anyway.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
HOOK=0; [[ ${1:-} == --hook ]] && HOOK=1
BIN=/usr/bin/Hyprland
STATE=/var/lib/omacvm/hyprland-vmwgfx      # "<package version> <sha256 of the patched binary>"
W=/var/cache/omacvm/hyprland-vmwgfx
DEPS=(base-devel git cmake ninja hyprwayland-scanner hyprland-protocols glaze)

pkg=$(pacman -Q hyprland 2>/dev/null | awk '{ print $2 }')
[[ -n $pkg ]] || { echo "build-hyprland: the hyprland package is not installed" >&2; exit 1; }
sum() { sha256sum "$1" | awk '{ print $1 }'; }
if [[ -z ${OMACVM_REBUILD_HYPRLAND:-} && -f $STATE && $(cat "$STATE") == "$pkg $(sum $BIN)" ]]; then
  echo "Hyprland $pkg already has the vmwgfx fix: nothing to build"
  exit 0
fi
ver=${pkg#*:}; ver=${ver%-*}               # 1:0.56.2-4 -> 0.56.2

if (( ! HOOK )); then pacman -S --needed --noconfirm "${DEPS[@]}" >/dev/null 2>&1; fi
rm -rf "$W"; mkdir -p "$W" "$(dirname "$STATE")"
git clone -q --recursive --depth 1 --branch "v$ver" https://github.com/hyprwm/Hyprland "$W/src" 2>/dev/null ||
  { echo "build-hyprland: no Hyprland source for v$ver" >&2; exit 1; }
cd "$W/src"
git apply --check "$here/hyprland-vmwgfx-dmabuf.patch" 2>/dev/null ||
  { echo "build-hyprland: the vmwgfx fix does not apply to Hyprland $ver (omacvm update may bring a newer one)" >&2; exit 1; }
git apply "$here/hyprland-vmwgfx-dmabuf.patch"
echo "building Hyprland $ver with the vmwgfx fix (10 to 20 minutes)"
cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr > "$W/build.log" 2>&1 &&
  cmake --build build --target Hyprland >> "$W/build.log" 2>&1 ||
  { tail -20 "$W/build.log" >&2; echo "build-hyprland: the build failed, full log: $W/build.log" >&2; exit 1; }
[[ -x build/Hyprland ]] || { echo "build-hyprland: no Hyprland binary after the build" >&2; exit 1; }

# The package's binary, unless what is there is an earlier patched build.
if [[ ! -f $STATE || $(awk '{ print $2 }' "$STATE") != "$(sum $BIN)" ]]; then cp -a $BIN $BIN.stock; fi
install -m755 build/Hyprland $BIN
echo "$pkg $(sum $BIN)" > "$STATE"
rm -rf "$W/src"
echo "Hyprland $ver with the vmwgfx fix installed; log out or reboot to use it"
