#!/bin/bash
# Remove everything Omaparallels installed on the Mac (the VM is left alone).
# --purge also deletes the bridge token, config and logs.
R=$(cd "$(dirname "$0")/.." && pwd)
"$R/bridge/mac/uninstall.sh" "$@"
"$R/gestures/mac/uninstall.sh"
"$R/clipboard/mac/uninstall.sh"
"$R/lock/mac/uninstall.sh"
tccutil reset Accessibility org.omaparallels.gestures >/dev/null 2>&1 || true
tccutil reset ListenEvent org.omaparallels.gestures >/dev/null 2>&1 || true
[[ ${1:-} == --purge ]] && rm -rf ~/.local/share/omaparallels
echo "Omaparallels removed from this Mac"
