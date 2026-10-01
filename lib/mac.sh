# Shared helpers for build.sh and apply.sh (sourced, Mac side).
log() { printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

PRLCTL=/usr/local/bin/prlctl
LEASES=/Library/Preferences/Parallels/parallels_dhcp_leases

# SSH into the guest as root with the Omaparallels key. VMs get rebuilt, so
# their host keys are not remembered.
gssh() {
  local ip=$1; shift
  ssh -i "${OMA_KEY:-$HOME/.ssh/omaparallels}" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$ip" "$@"
}

wait_ssh() {   # <ip> [seconds]
  local i
  for ((i = 0; i < ${2:-600}; i += 5)); do gssh "$1" true 2>/dev/null && return 0; sleep 5; done
  die "no SSH on $1 after ${2:-600} s"
}

vm_bundle() {   # <vm name> -> path of its .pvm
  local p
  p=$("$PRLCTL" list -a -i "$1" 2>/dev/null | sed -n 's/^Home: \(.*\)\/$/\1/p; s/^Home: \(.*\)$/\1/p' | head -1)
  [[ -n $p ]] && echo "$p" || echo "$HOME/Parallels/$1.pvm"
}

vm_mac() {   # <pvm> -> guest MAC (lower case, no separators)
  python3 - "$1/config.pvs" <<'PY'
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).getroot().findtext("Hardware/NetworkAdapter/MAC", "").lower())
PY
}

vm_ip() {   # <pvm> [seconds] -> the IP Parallels' DHCP gave the guest's MAC
  local mac i ip
  mac=$(vm_mac "$1")
  [[ -n $mac ]] || return 1
  for ((i = 0; i < ${2:-1}; i += 3)); do
    ip=$(grep -i "$mac" "$LEASES" 2>/dev/null | sed -n 's/^\(10\.211\.55\.[0-9]*\)=.*/\1/p' | tail -1)
    [[ -n $ip ]] && { echo "$ip"; return 0; }
    sleep 3
  done
  return 1
}

vm_state() {   # <vm name> -> running|stopped|...
  "$PRLCTL" list -a -o status,name 2>/dev/null | awk -v n="$1" 'NR > 1 { s = $1; $1 = ""; sub(/^ /, ""); if ($0 == n) print s }'
}

wait_stopped() {   # <vm name>
  local i
  for ((i = 0; i < 180; i += 3)); do [[ $(vm_state "$1") == stopped ]] && return 0; sleep 3; done
  die "VM '$1' did not stop"
}

vm_start() {   # <vm name> <pvm>: opening the bundle in Parallels Desktop starts it
  local i
  open -a "Parallels Desktop" "$2"
  for ((i = 0; i < 60; i += 3)); do [[ $(vm_state "$1") == running ]] && return 0; sleep 3; done
  "$PRLCTL" start "$1" >/dev/null 2>&1 && return 0      # Pro/Business editions
  log "start the VM '$1' in Parallels Desktop (click the play button), waiting..."
  for ((i = 0; i < 600; i += 3)); do [[ $(vm_state "$1") == running ]] && return 0; sleep 3; done
  die "VM '$1' did not start"
}
