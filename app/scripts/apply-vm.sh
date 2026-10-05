#!/bin/bash
# Put OmacVM onto a running OmacVM.app VM: `omacvm apply` from the copy of
# OmacVM inside the app (the Mac side its features need, the Bridge token,
# the VM side), with the features in the VM's vm.env.
#   apply-vm.sh VM_DIR [--no-mac | --image]
# --image: a VM for a prebuilt image (src/prebuilt/make-image.sh app): nothing
# of this Mac, not even the Bridge token.
set -euo pipefail
VM_DIR=${1:?usage: apply-vm.sh VM_DIR [--no-mac | --image]}
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "$VM_DIR"
vssh true < /dev/null 2>/dev/null || die "the VM is not running (or has no SSH yet)"

# A copy of src/ only: the Mac installers build next to their sources, never
# inside the app (or the source tree).
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/omacvm"
cp -R "$OMACVM_SRC" "$tmp/omacvm/src"
args=(--vm "$NAME" --vm-type app --ip "127.0.0.1:$SSH_PORT" --user "$VM_USER" --keyboard "$KEYBOARD")
for f in ${FEATURES:-}; do args+=(--feature "$f"); done
case ${2:-} in
  --no-mac) args+=(--no-mac) ;;
  --image) args+=(--no-mac --no-token --no-tools) ;;
esac
"$tmp/omacvm/src/cmd/apply.sh" "${args[@]}"
