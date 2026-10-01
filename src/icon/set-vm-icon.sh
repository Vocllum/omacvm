#!/bin/bash
# Give a Parallels VM OmacVM's icon (icon/omacvm.svg) in the Dock:
#   ./set-vm-icon.sh <VM bundle .pvm>
# Sets the Finder custom icon of the .pvm, which is what Parallels uses for the
# VM's Dock tile (picked up the next time the Parallels app starts).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
PVM=${1:?usage: set-vm-icon.sh <bundle.pvm>}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$here/make-icns.sh" "$T/vm.icns"
swift "$here/set-icon.swift" "$T/vm.icns" "$PVM"
