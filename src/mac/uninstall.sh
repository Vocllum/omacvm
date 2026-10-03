#!/bin/bash
# Remove everything OmacVM installed on the Mac (the VM is left alone).
# --purge also deletes the bridge token, config and logs.
R=$(cd "$(dirname "$0")/.." && pwd)
PURGE=""
for a in "$@"; do
  case $a in
    --purge) PURGE=--purge ;;
    -h|--help) sed -n '2,3s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm uninstall: unknown option $a (see --help)" >&2; exit 2 ;;
  esac
done
"$R/bridge/mac/uninstall.sh" $PURGE
"$R/gestures/mac/uninstall.sh"
"$R/clipboard/mac/uninstall.sh"
"$R/omanotch/mac/uninstall.sh"
tccutil reset Accessibility org.omacvm.gestures >/dev/null 2>&1 || true
tccutil reset ListenEvent org.omacvm.gestures >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Application Support/omacvm/installed"
[[ -n $PURGE ]] && rm -rf "$HOME/.local/share/omacvm" "$HOME/Library/Application Support/omacvm"   # also the VMs' SSH host keys
echo "OmacVM removed from this Mac"
