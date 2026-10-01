#!/bin/bash
# Apply OmacVM's guest side to a running VM, Parallels or UTM (build.sh ends
# with this; run it again after pulling a newer OmacVM):
#   ./apply.sh [--vm NAME | --ip IP] [--vm-type parallels|utm] [--user NAME] [--key PRIVATE_KEY]
#              [--keyboard "LAYOUT [VARIANT]"] [--display WxH@Hz] [--no-thp-kernel] [--autologin]
# Defaults: VM "Omarchy", its type from Parallels/UTM, user = your Mac login
# name, key ~/.ssh/omacvm, keyboard = the Mac's current layout, display (UTM)
# = the Mac's built-in display below the notch. Copies the bridge token and
# this repository into the VM (/usr/local/share/omacvm), runs guest/install.sh
# there as root, and (Parallels) gives the VM its Omarchy Dock icon.
set -euo pipefail
R=$(cd "$(dirname "$0")" && pwd)
VM=Omarchy; IP=""; TYPE=""; U=$(id -un); KEY=~/.ssh/omacvm; KB=""; MODE=""; EXTRA=()
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --keyboard) KB=$2; shift 2 ;;
    --display) MODE=$2; shift 2 ;;
    --no-thp-kernel|--autologin) EXTRA+=("$1"); shift ;;
    -h|--help) sed -n '2,11s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "apply.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
source "$R/lib/mac.sh"
[[ -n $KB ]] || KB=$("$R/keyboard/mac-layout.sh")
[[ -n $TYPE ]] || TYPE=$(vm_type "$VM") || die "no Parallels or UTM VM named '$VM' (or pass --vm-type and --ip)"
case $TYPE in
  parallels)
    PVM=$(vm_bundle "$VM")
    [[ -n $IP ]] || IP=$(vm_ip "$PVM") || die "no IP for VM '$VM' (is it running?)" ;;
  utm)
    PVM=""
    [[ -n $IP ]] || IP=$(utm_ip "$VM" 30) || die "no IP for UTM VM '$VM' (is it running?)"
    [[ -n $MODE ]] || MODE=$(swift "$R/display/mac-display.swift") ;;
  *) die "--vm-type parallels or utm" ;;
esac
export OMA_KEY=$KEY
wait_ssh "$IP"
log "$TYPE VM '$VM' at $IP"

log "bridge token -> $IP"
T=~/Library/Application\ Support/omacvm-bridge/token
[[ -f $T ]] || die "no bridge token yet: run mac/install.sh first"
gssh "$IP" "set -e; H=\$(getent passwd '$U' | cut -d: -f6)
  install -d -m700 -o '$U' -g '$U' \"\$H/.config/omacvm-bridge\"
  install -m600 -o '$U' -g '$U' /dev/stdin \"\$H/.config/omacvm-bridge/token\"" < "$T"

log "OmacVM -> $IP:/usr/local/share/omacvm"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$R" --exclude .git --exclude build --exclude docs -czf - . |
  gssh "$IP" "rm -rf /usr/local/share/omacvm && mkdir -p /usr/local/share/omacvm &&
              tar -C /usr/local/share/omacvm -xzf - 2>/dev/null"
gssh "$IP" "/usr/local/share/omacvm/guest/install.sh --user '$U' --keyboard '$KB' --vm-type $TYPE ${MODE:+--display $MODE} ${EXTRA[*]:-}"

if [[ $TYPE == parallels && -d $PVM ]]; then
  log "Dock icon"
  M=$(mktemp); gssh "$IP" cat /usr/share/omarchy/icon.txt > "$M"
  "$R/icon/set-vm-icon.sh" "$PVM" "$M" && rm -f "$M"
fi
log "done: reboot the VM to apply everything (kernel, zram, keyboard${MODE:+, display})"
