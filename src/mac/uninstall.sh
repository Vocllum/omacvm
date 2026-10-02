#!/bin/bash
# Remove everything OmacVM installed on the Mac (the VM is left alone).
# --purge also deletes the bridge token, config and logs.
R=$(cd "$(dirname "$0")/.." && pwd)
"$R/bridge/mac/uninstall.sh" "$@"
"$R/gestures/mac/uninstall.sh"
"$R/clipboard/mac/uninstall.sh"
tccutil reset Accessibility org.omacvm.gestures >/dev/null 2>&1 || true
tccutil reset ListenEvent org.omacvm.gestures >/dev/null 2>&1 || true
rm -rf ~/Library/Application\ Support/omacvm/installed
[[ ${1:-} == --purge ]] && rm -rf ~/.local/share/omacvm
echo "OmacVM removed from this Mac"
