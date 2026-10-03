#!/bin/bash
# Put OmacVM onto a running OmacVM.app VM: the Mac side its features need
# (Bridge, Gestures: OmacVM's own installers), the Bridge token, then the VM
# side. Like `omacvm apply` for the other routes.
#   apply-vm.sh VM_DIR [--no-mac]
set -euo pipefail
VM_DIR=${1:?usage: apply-vm.sh VM_DIR [--no-mac]}
MAC=1; [[ ${2:-} == --no-mac ]] && MAC=0
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "$VM_DIR"
qemu_running_any() { vssh true < /dev/null 2>/dev/null; }
qemu_running_any || die "the VM is not running (or has no SSH yet)"
on() { [[ " ${FEATURES:-} " == *" $1=on "* ]]; }

if (( MAC )) && { on bridge || on gestures; }; then
  args=(--quiet)
  on bridge || args+=(--no-bridge)
  on gestures || args+=(--skip-gestures)
  log "OmacVM on the Mac (Bridge, Gestures)"
  # A copy: the installers build next to their sources, never inside the app.
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cp -R "$OMACVM_SRC" "$tmp/src"
  "$tmp/src/mac/install.sh" "${args[@]}"
fi

# The Bridge's token: the VM shows it to the Mac's helpers on 127.0.0.1, which
# any Mac process can reach. Made here when the Bridge has not made one yet
# (same place and format, the Bridge keeps it).
T="$HOME/Library/Application Support/omacvm-bridge/token"
if on bridge; then for _ in $(seq 20); do [[ -f $T ]] && break; sleep 1; done; fi
if [[ ! -s $T ]]; then
  install -d -m700 "$(dirname "$T")"
  (umask 077; openssl rand -hex 32 > "$T")
fi
log "Bridge token -> VM"
vssh "set -e; H=\$(getent passwd '$VM_USER' | cut -d: -f6)
  install -d -m700 -o '$VM_USER' -g '$VM_USER' \"\$H/.config/omacvm-bridge\"
  install -m600 -o '$VM_USER' -g '$VM_USER' /dev/stdin \"\$H/.config/omacvm-bridge/token\"" < "$T"
log "OmacVM in the VM"
omacvm_guest_install
