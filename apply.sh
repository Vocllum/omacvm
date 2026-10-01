#!/bin/bash
# Apply Omaparallels' guest side to a running VM (build.sh ends with this; run
# it again after pulling a newer Omaparallels):
#   ./apply.sh [--vm NAME | --ip IP] [--user NAME] [--key PRIVATE_KEY]
#              [--keyboard "LAYOUT [VARIANT]"] [--no-thp-kernel] [--autologin]
# Defaults: VM "Omarchy", user = your Mac login name, key ~/.ssh/omaparallels,
# keyboard = the Mac's current layout. Copies the bridge token and this
# repository into the VM (/usr/local/share/omaparallels), runs
# guest/install.sh there as root, and gives the VM its Omarchy Dock icon.
set -euo pipefail
R=$(cd "$(dirname "$0")" && pwd)
VM=Omarchy; IP=""; U=$(id -un); KEY=~/.ssh/omaparallels; KB=""; EXTRA=()
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --keyboard) KB=$2; shift 2 ;;
    --no-thp-kernel|--autologin) EXTRA+=("$1"); shift ;;
    -h|--help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "apply.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
source "$R/lib/mac.sh"
[[ -n $KB ]] || KB=$("$R/keyboard/mac-layout.sh")
PVM=$(vm_bundle "$VM")
[[ -n $IP ]] || IP=$(vm_ip "$PVM") || die "no IP for VM '$VM' (is it running?)"
export OMA_KEY=$KEY
wait_ssh "$IP"

log "bridge token -> $IP"
T=~/Library/Application\ Support/omaparallels-bridge/token
[[ -f $T ]] || die "no bridge token yet: run mac/install.sh first"
gssh "$IP" "set -e; H=\$(getent passwd '$U' | cut -d: -f6)
  install -d -m700 -o '$U' -g '$U' \"\$H/.config/omaparallels-bridge\"
  install -m600 -o '$U' -g '$U' /dev/stdin \"\$H/.config/omaparallels-bridge/token\"" < "$T"

log "Omaparallels -> $IP:/usr/local/share/omaparallels"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$R" --exclude .git --exclude build --exclude docs -czf - . |
  gssh "$IP" "rm -rf /usr/local/share/omaparallels && mkdir -p /usr/local/share/omaparallels &&
              tar -C /usr/local/share/omaparallels -xzf - 2>/dev/null"
gssh "$IP" "/usr/local/share/omaparallels/guest/install.sh --user '$U' --keyboard '$KB' ${EXTRA[*]:-}"

if [[ -d $PVM ]]; then
  log "Dock icon"
  M=$(mktemp); gssh "$IP" cat /usr/share/omarchy/icon.txt > "$M"
  "$R/icon/set-vm-icon.sh" "$PVM" "$M" && rm -f "$M"
fi
log "done: reboot the VM to apply everything (kernel, zram, keyboard)"
