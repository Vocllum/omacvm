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
  [[ $(xxd -p "$HOME/Library/Preferences/Parallels/Linux.dat" 2>/dev/null | tr -d '\n') == \
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
  local try i
  for try in 1 2; do
    [[ $(utm_state "$1") == started ]] || "$UTMCTL" start "$1" >/dev/null 2>&1 || true
    for ((i = 0; i < 60; i += 3)); do [[ $(utm_state "$1") == started ]] && return 0; sleep 3; done
    # After a long session UTM can stop answering start requests (they time out
    # with OSStatus -1712); restarting the app clears it. Never while another
    # UTM VM runs.
    (( try == 1 )) || break
    "$UTMCTL" list 2>/dev/null | awk 'NR > 1 && $2 == "started"' | grep -q . && break
    log "UTM did not start the VM: restarting UTM once"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for ((i = 0; i < 30; i++)); do pgrep -xq UTM || break; sleep 1; done
    open -a UTM; sleep 5
  done
  die "UTM VM '$1' did not start (try quitting and reopening UTM, then run build.sh again)"
}

utm_wait_stopped() {   # <vm name>
  local i
  for ((i = 0; i < 180; i += 3)); do [[ $(utm_state "$1") == stopped ]] && return 0; sleep 3; done
  die "UTM VM '$1' did not stop"
}

# ---- VMware Fusion ----
# Fusion's tools live in the app; its library is a text file, so listing VMs
# never starts Fusion. A VM is its .vmx; its name is displayName in there.
FUSION_LIB="/Applications/VMware Fusion.app/Contents/Library"
VMRUN=$FUSION_LIB/vmrun
FUSION_INVENTORY="$HOME/Library/Application Support/VMware Fusion/vmInventory"
FUSION_NETWORKING="/Library/Preferences/VMware Fusion/networking"
FUSION_LEASES=/var/db/vmware/vmnet-dhcpd-vmnet8.leases
FUSION_DIR=${OMACVM_FUSION_DIR:-$HOME/Virtual Machines.localized}   # where omacvm build puts new VMs

fusion_bundle() { echo "$FUSION_DIR/$1.vmwarevm"; }   # <vm name> -> the folder omacvm build gives it
fusion_version() { defaults read "/Applications/VMware Fusion.app/Contents/Info" CFBundleShortVersionString 2>/dev/null; }

fusion_list() {   # one line per VM in Fusion's library: NAME<TAB>VMX
  local x n
  [[ -f $FUSION_INVENTORY ]] || return 0
  sed -n 's/^vmlist[0-9]*\.config = "\(.*\.vmx\)"$/\1/p' "$FUSION_INVENTORY" | while IFS= read -r x; do
    [[ -f $x ]] || continue
    n=$(sed -n 's/^displayName = "\(.*\)"$/\1/p' "$x" | head -1)
    printf '%s\t%s\n' "${n:-$(basename "$x" .vmx)}" "$x"
  done
}

fusion_vmx() {   # <vm name> -> its .vmx (in Fusion's library, or one omacvm build made)
  local x
  x=$(fusion_list | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }')
  [[ -n $x ]] || { x="$(fusion_bundle "$1")/$1.vmx"; [[ -f $x ]] || x=""; }
  [[ -n $x ]] && echo "$x"
}

fusion_state() {   # <vm name> -> running|stopped
  local x
  x=$(fusion_vmx "$1") || return 1
  if [[ -x $VMRUN ]] && "$VMRUN" list 2>/dev/null | grep -qxF "$x"; then echo running; else echo stopped; fi
}

# The Mac's address on Fusion's NAT network (vmnet8). Fusion picks the subnet
# at install time; the Mac is .1 there (the guests' gateway is .2). The first
# VNET_8_HOSTONLY_SUBNET line, and only a private address (the Bridge and
# Gestures read it the same way).
fusion_host() {
  local net
  net=$(awk '$1 == "answer" && $2 == "VNET_8_HOSTONLY_SUBNET" { print $3; exit }' "$FUSION_NETWORKING" 2>/dev/null)
  private_ipv4 "$net" || return 1
  [[ ${net%.*}.1 != 192.168.64.1 ]] || return 1   # UTM's
  echo "${net%.*}.1"
}
private_ipv4() {   # 10/8, 172.16/12 or 192.168/16, each part 0-255
  local a b c d
  [[ ${1:-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  (( a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ))
}

fusion_ip() {   # <vm name> [seconds]: the address Fusion's DHCP gave the VM's MAC
  local x mac i ip
  x=$(fusion_vmx "$1") || return 1
  for ((i = 0; i < ${2:-1}; i += 3)); do
    mac=$(sed -n 's/^ethernet0\.generatedAddress = "\(.*\)"$/\1/p; s/^ethernet0\.address = "\(.*\)"$/\1/p' "$x" | head -1 | tr 'A-F' 'a-f')
    if [[ -n $mac ]]; then
      ip=$(awk -v m="$mac" '$1 == "lease" { ip = $2 } $1 == "hardware" && tolower($3) == m ";" { last = ip } END { print last }' "$FUSION_LEASES" 2>/dev/null)
      [[ -n $ip ]] && { echo "$ip"; return 0; }
    fi
    sleep 3
  done
  return 1
}

fusion_start() {   # <vm name>
  # Right after a shutdown Fusion can still hold the VM's files and leave a
  # start without effect (no error): check, and try again.
  local x i
  x=$(fusion_vmx "$1") || die "no VMware Fusion VM named '$1'"
  for ((i = 0; i < 5; i++)); do
    [[ $(fusion_state "$1") == running ]] && return 0
    "$VMRUN" -T fusion start "$x" gui >/dev/null 2>&1 || true
    sleep 3
  done
  [[ $(fusion_state "$1") == running ]] || die "VMware Fusion did not start '$1'"
}

fusion_wait_stopped() {   # <vm name>
  local i
  for ((i = 0; i < 180; i += 3)); do [[ $(fusion_state "$1") == stopped ]] && return 0; sleep 3; done
  die "VMware Fusion VM '$1' did not stop"
}

# OmacVM's helpers listen on the Mac's address on each VM app's shared network:
# 10.211.55.2 (Parallels), 192.168.64.1 (UTM), the .1 of Fusion's NAT network
# (fusion_host). vm_network_ok TYPE [IP] says (on stderr) what to change when
# that network was moved.
vm_network_ok() {
  local a
  case $1 in
    parallels)
      a=$(prlsrvctl net info Shared 2>/dev/null | awk '/Parallels adapter/ { f = 1 } f && /IPv4 address:/ { print $3; exit }')
      if [[ -n $a && $a != 10.211.55.2 ]]; then
        printf 'Parallels'"'"'s shared network is at %s; OmacVM needs its default, 10.211.55.0/24 (the Mac at 10.211.55.2): set it back in Parallels Desktop > Settings > Network (Shared).\n' "$a" >&2
        return 1
      fi ;;
    utm)
      if [[ -n ${2:-} && $2 != 192.168.64.* ]]; then
        printf 'The UTM VM is at %s, outside UTM'"'"'s default shared network 192.168.64.0/24 (the Mac at 192.168.64.1), which OmacVM needs: give the VM the "Shared Network" mode with macOS'"'"'s default range.\n' "$2" >&2
        return 1
      fi ;;
    fusion)
      a=$(fusion_host) || {
        printf 'VMware Fusion has no NAT network (vmnet8) on this Mac: open VMware Fusion > Settings > Network.\n' >&2
        return 1
      }
      if [[ -n ${2:-} && ${2%.*} != "${a%.*}" ]]; then
        printf 'The VMware Fusion VM is at %s, outside Fusion'"'"'s NAT network (the Mac at %s), which OmacVM needs: give the VM the "Share with my Mac" network.\n' "$2" "$a" >&2
        return 1
      fi ;;
    *) return 1 ;;
  esac
  return 0
}
