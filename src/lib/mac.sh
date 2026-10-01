# Shared helpers for build.sh and apply.sh (sourced, Mac side).
log() { printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

PRLCTL=/usr/local/bin/prlctl
LEASES=/Library/Preferences/Parallels/parallels_dhcp_leases

# SSH into the guest as root with the OmacVM key. VMs get rebuilt, so
# their host keys are not remembered.
gssh() {
  local ip=$1; shift
  ssh -i "${OMA_KEY:-$HOME/.ssh/omacvm}" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 \
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

# Parallels' "Send macOS system shortcuts" (Settings > Shortcuts > macOS System
# Shortcuts) has no CLI, plist key or VM setting. With "Always", Parallels
# writes ~/Library/Preferences/Parallels/sendtovmkeys.dat: a count, then one
# 9-byte entry per macOS shortcut with a 4-byte flag of 1. Undocumented, so a
# best guess, only used to decide whether to remind the user.
parallels_sends_shortcuts() {
  python3 - "$HOME/Library/Preferences/Parallels/sendtovmkeys.dat" 2>/dev/null <<'EOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
n = struct.unpack(">I", b[:4])[0]
entries = [b[4 + 9 * i:13 + 9 * i] for i in range(n)]
sys.exit(0 if n and len(b) == 4 + 9 * n and all(e[1:5] == b"\0\0\0\1" for e in entries) else 1)
EOF
}

# Parallels' "Linux" keyboard profile emptied by mac/parallels-shortcuts.sh?
parallels_profile_emptied() {
  [[ $(xxd -p ~/Library/Preferences/Parallels/Linux.dat 2>/dev/null | tr -d '\n') == \
     00030231000000010000000a004c0069006e00750078000000000000000000000000 ]]
}

# Ask for that one setting with mac/parallels-system-shortcuts.sh (alerts, in
# the background: the calling script goes on and may end first).
parallels_shortcuts_alert() {
  nohup "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/mac/parallels-system-shortcuts.sh" >/dev/null 2>&1 &
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

# ---- UTM ----
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl

vm_type() {   # <vm name> -> parallels | utm; a name in both: the one that is running
  local p="" u=""
  [[ -x $PRLCTL ]] && "$PRLCTL" list -a -o name 2>/dev/null | sed 1d | grep -qxF "$1" && p=1
  [[ -x $UTMCTL ]] && "$UTMCTL" list 2>/dev/null | awk 'NR > 1 { $1 = ""; $2 = ""; sub(/^  /, ""); print }' | grep -qxF "$1" && u=1
  if [[ -n $p && -n $u ]]; then
    [[ $(utm_state "$1") == started ]] && echo utm || echo parallels
  elif [[ -n $p ]]; then echo parallels
  elif [[ -n $u ]]; then echo utm
  else return 1; fi
}

utm_state() {   # <vm name> -> started|stopped|...
  "$UTMCTL" status "$1" 2>/dev/null | tr -d '[:space:]'; echo
}

utm_ip() {   # <vm name> [seconds]: the guest's address on UTM's shared network
  local i ip
  for ((i = 0; i < ${2:-1}; i += 3)); do
    # the QEMU guest agent knows; without it, UTM's DHCP server (bootpd) does
    ip=$("$UTMCTL" ip-address "$1" 2>/dev/null | grep -m1 -E '^192\.168\.[0-9]+\.[0-9]+$') && { echo "$ip"; return 0; }
    local mac
    mac=$(osascript -e "tell application \"UTM\"" -e "copy (configuration of virtual machine named \"$1\") to c" \
            -e "get address of item 1 of (network interfaces of c)" -e "end tell" 2>/dev/null |
          tr 'A-F' 'a-f' | sed 's/:0/:/g; s/^0//')
    if [[ -n $mac ]]; then
      ip=$(awk -v m="1,$mac" '/ip_address=/ { split($0, a, "="); ip = a[2] } /hw_address=/ { split($0, b, "="); if (b[2] == m) print ip }' /var/db/dhcpd_leases 2>/dev/null | tail -1)
      [[ -n $ip ]] && { echo "$ip"; return 0; }
    fi
    sleep 3
  done
  return 1
}

utm_start() {   # <vm name>: UTM must run in the foreground (open -g makes the VM ~8x slower)
  pgrep -xq UTM || { open -a UTM; sleep 3; }
  [[ $(utm_state "$1") == started ]] || "$UTMCTL" start "$1" >/dev/null
  local i
  for ((i = 0; i < 60; i += 3)); do [[ $(utm_state "$1") == started ]] && return 0; sleep 3; done
  die "UTM VM '$1' did not start"
}

utm_wait_stopped() {   # <vm name>
  local i
  for ((i = 0; i < 180; i += 3)); do [[ $(utm_state "$1") == stopped ]] && return 0; sleep 3; done
  die "UTM VM '$1' did not stop"
}
