#!/bin/bash
# omacvm check: is every OmacVM feature in place and working, on the Mac and
# in a running VM (Parallels, UTM or VMware Fusion)? Read-only; run it after a build or an
# apply, or whenever something seems off:
#   omacvm check [--vm NAME | --ip IP] [--vm-type parallels|utm|fusion] [--user NAME] [--key PRIVATE_KEY] [--json]
# VM, user and key as in omacvm apply (a stopped VM is not started). One line
# per feature (ok / FAIL / skip); exits 1 if anything failed. The desktop user
# must be logged in to the VM.
# --json: {"vm", "type", "ip", "ok", "checks": [{"section", "name", "status",
# "detail", "needs_human"}]}; needs_human = only a person can fix it (a macOS
# permission, a Parallels setting).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
VM=""; IP=""; TYPE=""; U=""; KEY=~/.ssh/omacvm; JSON=0
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm check: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
export OMA_KEY=$KEY
if [[ -z $IP ]]; then
  resolve_vm
  [[ -n $IP ]] || { echo "omacvm check: '$VM' is not running (start it, or omacvm apply --vm \"$VM\" starts it)" >&2; exit 1; }
fi
[[ -n $TYPE ]] || TYPE=$(vm_type "$VM") || die "no Parallels, UTM or VMware Fusion VM named '$VM' (or pass --vm-type and --ip)"
case $TYPE in
  parallels) HOST=10.211.55.2
             [[ -n $IP ]] || IP=$(vm_ip "$(vm_bundle "$VM")") || die "no IP for VM '$VM' (is it running?)" ;;
  utm) HOST=192.168.64.1
       [[ -n $IP ]] || IP=$(utm_ip "$VM" 10) || die "no IP for UTM VM '$VM' (is it running?)" ;;
  fusion) HOST=$(fusion_host)
          [[ -n $IP ]] || IP=$(fusion_ip "$VM" 10) || die "no IP for VMware Fusion VM '$VM' (is it running?)" ;;
  *) die "--vm-type parallels, utm or fusion" ;;
esac
export OMA_KEY=$KEY

fails=0; ROWS=""; SECTION=Mac
# line STATUS LABEL NAME DETAIL [human]
line() {
  if (( JSON )); then ROWS+="$1"$'\t'"$SECTION"$'\t'"$3"$'\t'"$4"$'\t'"${5:+1}"$'\n'
  else printf '  %-5s %-24s %s\n' "$2" "$3" "$4"; fi
}
ok()   { line ok ok "$1" "${2:-}"; }
bad()  { line fail FAIL "$1" "${2:-}" "${3:-}"; fails=$((fails + 1)); }
skip() { line skip skip "$1" "${2:-}" "${3:-}"; }
say_() { (( JSON )) || echo "$@"; }
json_out() {   # the collected rows as JSON
  local first=1 st sec name detail human
  printf '{"vm": %s, "type": "%s", "ip": %s, "ok": %s, "checks": [' "$(json_str "${VM:-}")" "$TYPE" "$(json_str "${IP:-}")" "$1"
  while IFS=$'\t' read -r st sec name detail human; do
    [[ -n $st ]] || continue
    printf '%s\n  {"section": %s, "name": %s, "status": "%s", "detail": %s, "needs_human": %s}' \
      "$( ((first)) || echo ,)" "$(json_str "$sec")" "$(json_str "$name")" "$st" "$(json_str "$detail")" "$( [[ $human == 1 ]] && echo true || echo false)"
    first=0
  done <<<"$ROWS"
  printf '\n]}\n'
}
running() { launchctl print "gui/$(id -u)/$1" 2>/dev/null | grep -q 'state = running'; }
# listeners PORT: the addresses something listens on for that port
listeners() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { sub(/:[0-9]+$/, "", $9); print $9 }' | sort -u | tr '\n' ' '; }
last_line() { grep -E "$2" "$1" 2>/dev/null | tail -1 | sed 's/^.*omacvm-[a-z]*: //'; }

say_ "Mac"
L=~/Library/Logs
# The VM network's Mac address exists only while a VM of that type runs.
if ! msg=$(vm_network_ok "$TYPE" "$IP" 2>&1); then
  bad "VM network" "$msg" human
  (( JSON )) && json_out false
  exit 1
fi
if ! ifconfig | grep -q "inet $HOST "; then
  bad "VM network" "$HOST is not up on this Mac: start the VM, then run omacvm check again"
  (( JSON )) && json_out false
  exit 1
fi
(wait_ssh "$IP" 30) >/dev/null 2>&1 || { bad "SSH" "no SSH to $IP with $KEY (omacvm apply shows how to let OmacVM in)"; (( JSON )) && json_out false; exit 1; }
[[ -n $U ]] || U=$(vm_probe "$IP" | sed -n 's/^OMACVM_USER=//p')
# What was chosen at setup for this VM (defaults for VMs from before the choices).
envf=$(gssh "$IP" cat /etc/omacvm/env 2>/dev/null)
feat() { local v; v=$(sed -n "s/^OMACVM_FEATURE_$1=//p" <<<"$envf" | tail -1); echo "${v:-${2:-on}}"; }
BRIDGE=$(feat bridge); GESTURES=$(feat gestures); GLIDE=$(feat scroll_momentum "$(feat glide off)")

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
    else bad "Location Services" "not granted to OmacVM Bridge (System Settings > Privacy & Security > Location Services)" human; fi
    bt=$(curl -s -m 3 -H "Authorization: Bearer $(cat "$T")" "http://$HOST:47831/bluetooth")
    case $(jq -r '.permission // empty' <<<"$bt" 2>/dev/null) in
      granted) ok "Bluetooth" "granted (connect devices from the VM)" ;;
      "") bad "Bluetooth" "the Bridge does not answer /bluetooth: src/mac/install.sh" ;;
      *) bad "Bluetooth" "not granted to OmacVM Bridge (System Settings > Privacy & Security > Bluetooth)" human ;;
    esac
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
    if [[ $GESTURES == on && $GLIDE == on ]]; then
      g=$(grep "guest connected: $IP " "$L/omacvm-gestures.log" 2>/dev/null | tail -1)
      if [[ $g == *"scroll momentum on"* || $g == *"Glide on"* ]]; then ok "scroll momentum (Mac)" "scrolling goes to this VM in full screen"
      else bad "scroll momentum (Mac)" "the helper does not scroll for this VM yet (omacvm apply --vm \"$VM\")"; fi
    fi
    # The helper listens only once it has its permissions, so a later
    # "listening" line overrides a "waiting" one (e.g. a restart while waiting).
    p=$(last_line "$L/omacvm-gestures.log" 'permission|listening on')
    [[ -z $p || $p == *granted* || $p == listening* ]] && ok "keyboard/trackpad access" "Accessibility + Input Monitoring" \
      || bad "keyboard/trackpad access" "${p}: System Settings > Privacy & Security" human
  else bad "Gestures" "OmacVM Gestures is not running (src/mac/install.sh)"; fi
else skip "Gestures" "trackpad gestures off (chosen at setup)"; fi
# macOS's "Automatically hide and show the menu bar: Never" keeps the Mac's
# menu bar over the full-screen VM: a hint (it is the person's setting).
if [[ $(defaults read NSGlobalDomain AppleMenuBarVisibleInFullscreen 2>/dev/null) == 1 ]]; then
  skip "menu bar in full screen" "macOS always shows it: System Settings > Menu Bar (older macOS: Control Center) > Automatically hide and show the menu bar: In Full Screen Only" human
else ok "menu bar in full screen" "hidden by macOS"; fi
case $TYPE in
parallels)
  running org.omacvm.clip-in && ok "clipboard VM -> Mac" "org.omacvm.clip-in" || bad "clipboard VM -> Mac" "org.omacvm.clip-in not running"
  # Parallels keeps both settings in undocumented files: hints, not failures.
  parallels_sends_shortcuts && ok "Cmd+Space etc. to the VM" "Send macOS system shortcuts: Always" \
    || skip "Cmd+Space etc. to the VM" "set Parallels Desktop > Settings > Shortcuts > macOS System Shortcuts > Send macOS system shortcuts: Always" human
  parallels_profile_emptied && ok "Cmd+C/V/X as Super" "Parallels' Linux profile emptied" \
    || skip "Cmd+C/V/X as Super" "Parallels turns them into Ctrl: quit Parallels Desktop, run src/mac/parallels-shortcuts.sh" human ;;
utm)
  [[ $(defaults read com.utmapp.UTM QEMUVulkanDriver 2>/dev/null) == 1 ]] && ok "UTM speed settings" "no Vulkan driver (fast page size)" \
    || bad "UTM speed settings" "QEMUVulkanDriver is not 1 (build.sh sets it; restart UTM after)" ;;
esac
pgrep -xq omanotch && ok "Omanotch (Mac)" "running" || skip "Omanotch (Mac)" "not running"
(( fails )) && mac_failed=1 || mac_failed=0

if (( JSON )); then
  out=$(gssh "$IP" "bash -s -- --user '$U' --tsv" < "$R/src/guest/check.sh"); guest=$?
  while IFS=$'\t' read -r a b c d; do
    if [[ $a == section ]]; then SECTION="VM: $b"
    elif [[ -n $a ]]; then ROWS+="$a"$'\t'"$SECTION"$'\t'"$b"$'\t'"$c"$'\t'"$d"$'\n'; fi
  done <<<"$out"
  json_out "$( (( guest == 0 && ! mac_failed )) && echo true || echo false)"
  (( guest == 0 && ! mac_failed )); exit
fi
echo
echo "VM '$VM' at $IP"
gssh "$IP" "bash -s -- --user '$U'" < "$R/src/guest/check.sh"
guest=$?
(( mac_failed )) && echo "(and $fails check(s) failed on the Mac)"
(( guest == 0 && ! mac_failed ))
