#!/bin/bash
# The VMs whose gestures daemon may come from before the Bridge token (OmacVM
# built them or set them up: vm_marked), as MAC addresses, one per line.
# src/mac/install.sh writes them to ~/Library/Application Support/omacvm/gestures-legacy
# once; OmacVM Gestures lets token-less daemons in from those VMs only, and
# omacvm apply takes each VM off the list when it gets the new daemon.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
while IFS=$'\t' read -r name type _; do
  [[ -n $name ]] || continue
  vm_marked "$name" "$type" && vm_hw_mac "$name" "$type"
done < <(vms_list) | sort -u
exit 0
