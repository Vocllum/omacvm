#!/bin/bash
# Give the VM an Omarchy Dock icon: a terminal-style squircle with Omarchy's mark
# (rendered from the VM's own /usr/share/omarchy/icon.txt) and a ❯ omarchy prompt.
#   ./set-vm-icon.sh <VM bundle .pvm> <icon.txt>
# Sets the Finder custom icon of the .pvm, which is what Parallels uses for the
# VM's Dock tile (picked up the next time the Parallels app starts).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
PVM=${1:?usage: set-vm-icon.sh <bundle.pvm> <icon.txt>}; MARK=${2:?}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swift "$here/make-icon.swift" "$MARK" "$T/icon.png" 1024 >/dev/null
mkdir "$T/vm.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/icon.png" --out "$T/vm.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/icon.png" --out "$T/vm.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/vm.iconset" -o "$T/vm.icns"
swift "$here/set-icon.swift" "$T/vm.icns" "$PVM"
