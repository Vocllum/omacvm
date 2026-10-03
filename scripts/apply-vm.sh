#!/bin/bash
# Put OmacVM onto a running OmacVM.app VM: `omacvm apply` from the copy of
# OmacVM inside the app (the Mac side its features need, the Bridge token,
# the VM side), with the features in the VM's vm.env.
#   apply-vm.sh VM_DIR [--no-mac]
set -euo pipefail
VM_DIR=${1:?usage: apply-vm.sh VM_DIR [--no-mac]}
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "$VM_DIR"
vssh true < /dev/null 2>/dev/null || die "the VM is not running (or has no SSH yet)"

# A copy: the Mac installers build next to their sources, never inside the app.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp -R "$(dirname "$OMACVM_SRC")" "$tmp/omacvm"
args=(--vm "$NAME" --vm-type app --ip "127.0.0.1:$SSH_PORT" --user "$VM_USER" --keyboard "$KEYBOARD")
for f in ${FEATURES:-}; do args+=(--feature "$f"); done
[[ ${2:-} == --no-mac ]] && args+=(--no-mac)
"$tmp/omacvm/src/cmd/apply.sh" "${args[@]}"
