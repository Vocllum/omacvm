#!/bin/bash
# Check that every OmacVM feature is in place and working, on the Mac and in a
# running VM (Parallels or UTM). Read-only; run it after build.sh / apply.sh or
# whenever something seems off:
#   ./check.sh [--vm NAME | --ip IP] [--vm-type parallels|utm] [--user NAME] [--key PRIVATE_KEY]
# Defaults as in apply.sh: VM "Omarchy", user = your Mac login, key
# ~/.ssh/omacvm. One line per feature (ok / FAIL / skip); exits 1 if anything
# failed. The desktop user must be logged in to the VM.
set -uo pipefail
R=$(cd "$(dirname "$0")" && pwd)
VM=Omarchy; IP=""; TYPE=""; U=$(id -un); KEY=~/.ssh/omacvm
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    -h|--help) sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "check.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
source "$R/src/lib/mac.sh"
[[ -n $TYPE ]] || TYPE=$(vm_type "$VM") || die "no Parallels or UTM VM named '$VM' (or pass --vm-type and --ip)"
case $TYPE in
  parallels) HOST=10.211.55.2
             [[ -n $IP ]] || IP=$(vm_ip "$(vm_bundle "$VM")") || die "no IP for VM '$VM' (is it running?)" ;;
  utm) HOST=192.168.64.1
       [[ -n $IP ]] || IP=$(utm_ip "$VM" 10) || die "no IP for UTM VM '$VM' (is it running?)" ;;
  *) die "--vm-type parallels or utm" ;;
esac
export OMA_KEY=$KEY

fails=0
ok()   { printf '  ok    %-24s %s\n' "$1" "${2:-}"; }
bad()  { printf '  FAIL  %-24s %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }
skip() { printf '  skip  %-24s %s\n' "$1" "${2:-}"; }
running() { launchctl print "gui/$(id -u)/$1" 2>/dev/null | grep -q 'state = running'; }
# listeners PORT: the addresses something listens on for that port
listeners() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { sub(/:[0-9]+$/, "", $9); print $9 }' | sort -u | tr '\n' ' '; }
last_line() { grep -E "$2" "$1" 2>/dev/null | tail -1 | sed 's/^.*omacvm-[a-z]*: //'; }

echo "Mac"
L=~/Library/Logs
# The VM network's Mac address exists only while a VM of that type runs.
if ! ifconfig | grep -q "inet $HOST "; then
  bad "VM network" "$HOST is not up on this Mac: start the VM, then run check.sh again"
  exit 1
fi
(wait_ssh "$IP" 30) >/dev/null 2>&1 || { bad "SSH" "no SSH to $IP with $KEY"; exit 1; }
# What was chosen at setup for this VM (defaults for VMs from before the choices).
envf=$(gssh "$IP" cat /etc/omacvm/env 2>/dev/null)
feat() { local v; v=$(sed -n "s/^OMACVM_FEATURE_$1=//p" <<<"$envf" | tail -1); echo "${v:-on}"; }
BRIDGE=$(feat bridge); GESTURES=$(feat gestures)

if [[ $BRIDGE == on ]]; then
  if running org.omacvm.bridge; then
    a=$(listeners 47831)
    if [[ " $a " == *" * "* || $a == *0.0.0.0* ]]; then bad "Bridge" "listens on every interface: $a"
    elif [[ " $a " == *" $HOST "* ]]; then ok "Bridge" "listening on $a"
    else bad "Bridge" "not listening on $HOST (only: ${a:-nothing})"; fi
  else bad "Bridge" "OmacVM Bridge is not running (src/mac/install.sh)"; fi
  T=~/Library/Application\ Support/omacvm-bridge/token
  if [[ -s $T ]]; then
    [[ $(stat -f %Lp "$T") == 600 ]] && ok "token" "private (600)" || bad "token" "readable by others: chmod 600"
    st=$(curl -s -m 3 -H "Authorization: Bearer $(cat "$T")" "http://$HOST:47831/state")
    if jq -e .location_authorized <<<"$st" >/dev/null 2>&1; then ok "Location Services" "granted (Wi-Fi names)"
    else bad "Location Services" "not granted to OmacVM Bridge (System Settings > Privacy & Security > Location Services)"; fi
  else bad "token" "missing (src/mac/install.sh)"; fi
  m=$(last_line "$L/omacvm-bridge.log" 'media keys: (event tap|waiting|cannot)')
  [[ $m == *installed* ]] && ok "media keys" "event tap installed" || bad "media keys" "${m:-no event tap yet}"
else skip "Bridge" "off (chosen at setup)"; fi
# Gestures runs keys-only when trackpad gestures were turned off; on UTM it
# also types Cmd as Super, so it is needed there either way.
if [[ $GESTURES == on || $TYPE == utm ]]; then
  if running org.omacvm.gestures; then
    a=$(listeners 47830)
    [[ " $a " == *" $HOST "* ]] && ok "Gestures" "listening on $a" || bad "Gestures" "not listening on $HOST (only: ${a:-nothing})"
    keysonly=$(launchctl print "gui/$(id -u)/org.omacvm.gestures" 2>/dev/null | grep -c -- '--keys-only')
    if [[ $GESTURES == on && $keysonly != 0 ]]; then
      bad "trackpad gestures" "OmacVM Gestures runs keys-only on this Mac: src/mac/install.sh turns gestures back on"
    fi
    p=$(last_line "$L/omacvm-gestures.log" 'permission')
    [[ $p == *granted* ]] && ok "keyboard/trackpad access" "Accessibility + Input Monitoring" \
      || bad "keyboard/trackpad access" "${p:-unknown}: System Settings > Privacy & Security"
  else bad "Gestures" "OmacVM Gestures is not running (src/mac/install.sh)"; fi
else skip "Gestures" "trackpad gestures off (chosen at setup)"; fi
if [[ $TYPE == parallels ]]; then
  running org.omacvm.clip-in && ok "clipboard VM -> Mac" "org.omacvm.clip-in" || bad "clipboard VM -> Mac" "org.omacvm.clip-in not running"
  # Parallels keeps both settings in undocumented files: hints, not failures.
  parallels_sends_shortcuts && ok "Cmd+Space etc. to the VM" "Send macOS system shortcuts: Always" \
    || skip "Cmd+Space etc. to the VM" "set Parallels Desktop > Settings > Shortcuts > macOS System Shortcuts > Send macOS system shortcuts: Always"
  parallels_profile_emptied && ok "Cmd+C/V/X as Super" "Parallels' Linux profile emptied" \
    || skip "Cmd+C/V/X as Super" "Parallels turns them into Ctrl: quit Parallels Desktop, run src/mac/parallels-shortcuts.sh"
else
  [[ $(defaults read com.utmapp.UTM QEMUVulkanDriver 2>/dev/null) == 1 ]] && ok "UTM speed settings" "no Vulkan driver (fast page size)" \
    || bad "UTM speed settings" "QEMUVulkanDriver is not 1 (build.sh sets it; restart UTM after)"
fi
pgrep -xq omanotch && ok "Omanotch (Mac)" "running" || skip "Omanotch (Mac)" "not running"
(( fails )) && mac_failed=1 || mac_failed=0

echo
echo "VM '$VM' at $IP"
gssh "$IP" "bash -s -- --user '$U'" < "$R/src/guest/check.sh"
guest=$?
(( mac_failed )) && echo "(and $fails check(s) failed on the Mac)"
(( guest == 0 && ! mac_failed ))
