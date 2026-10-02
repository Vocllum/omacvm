#!/bin/bash
# OmacVM, guest side check: is every feature in place and working right now?
# Run as root inside the VM while the desktop user is logged in (check.sh on
# the Mac does that over SSH):
#   guest/check.sh --user NAME [--tsv]
# One line per feature (ok / FAIL / skip); exits 1 if anything failed. --tsv:
# "status<TAB>name<TAB>detail<TAB>human" lines (human = 1: only a person can fix
# it) and "section<TAB>title", for omacvm check --json.
set -uo pipefail
U=""; TSV=0
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --tsv) TSV=1; shift ;;
    *) echo "usage: guest/check.sh --user NAME [--tsv]" >&2; exit 2 ;;
  esac
done
id "$U" >/dev/null 2>&1 || { echo "guest/check.sh: --user must be the desktop user" >&2; exit 2; }
H=$(getent passwd "$U" | cut -d: -f6); RUN=/run/user/$(id -u "$U")
fails=0
line() {   # STATUS LABEL NAME DETAIL [human]
  if (( TSV )); then printf '%s\t%s\t%s\t%s\n' "$1" "$3" "$4" "${5:+1}"
  else printf '  %-5s %-24s %s\n' "$2" "$3" "$4"; fi
}
ok()   { line ok ok "$1" "${2:-}"; }
bad()  { line fail FAIL "$1" "${2:-}" "${3:-}"; fails=$((fails + 1)); }
skip() { line skip skip "$1" "${2:-}" "${3:-}"; }
# check NAME DETAIL COMMAND...: ok if the command succeeds
check() { local n=$1 d=$2; shift 2; if "$@" >/dev/null 2>&1; then ok "$n" "$d"; else bad "$n" "$d"; fi; }
section() { if (( TSV )); then printf 'section\t%s\n' "$1"; else printf '%s\n' "$1"; fi; }
# In the desktop user's session, with Omarchy's and Hyprland's environment.
as_user() {
  local sig; sig=$(ls -t "$RUN/hypr" 2>/dev/null | head -1)
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="$RUN" WAYLAND_DISPLAY=wayland-1 \
    HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}
user_active() { systemctl --user -M "$U@" is-active "$1" >/dev/null 2>&1; }
connected_to() { ss -Htn state established "dst $1:$2" | grep -q .; }
ev_device() { grep -q "^N: Name=\"$1\"" /proc/bus/input/devices; }

[[ -r /etc/omacvm/env ]] || { bad "OmacVM guest side" "not installed (run apply.sh on the Mac)"; exit 1; }
source /etc/omacvm/env
HOST=$OMACVM_HOST; TYPE=$OMACVM_VM_TYPE
# Features chosen at setup (VMs set up before the choices existed: the defaults
# they were built with).
BRIDGE=${OMACVM_FEATURE_bridge:-on}; WALLPAPER=${OMACVM_FEATURE_wallpaper:-on}
GESTURES=${OMACVM_FEATURE_gestures:-on}; IDLE_LOCK=${OMACVM_FEATURE_idle_lock:-on}
THP_KERNEL=${OMACVM_FEATURE_thp_kernel:-}; AUTOLOGIN=${OMACVM_FEATURE_autologin:-}
GLIDE=${OMACVM_FEATURE_glide:-off}; OMANOTCH=${OMACVM_FEATURE_omanotch:-}

section "Session ($TYPE VM, the Mac is $HOST)"
if pgrep -u "$U" -x Hyprland >/dev/null; then ok "Hyprland" "running for $U"
else bad "Hyprland" "not running for $U: log in first, the checks below need the session"; fi
check "Omarchy shell" "answers" as_user omarchy-shell shell ping
mon=$(as_user hyprctl monitors -j 2>/dev/null | jq -r 'max_by(.width * .height) | "\(.width)x\(.height)@\(.refreshRate | round) scale \(.scale)"' 2>/dev/null)
if [[ -z $mon ]]; then bad "display" "no monitor from hyprctl"
elif [[ $mon == 1160x768* ]]; then bad "display" "$mon: still the firmware mode (monitors.lua not applied)"
else ok "display" "$mon"; fi

section "The Mac in the bar (Bridge)"
if [[ $BRIDGE == on ]]; then
  if [[ -s $H/.config/omacvm-bridge/token ]]; then ok "token" "~/.config/omacvm-bridge/token"
  else bad "token" "missing: run apply.sh on the Mac"; fi
  state=$(as_user omacvm-bridge state 2>/dev/null)
  if jq -e .power >/dev/null 2>&1 <<<"$state"; then
    if jq -e .location_authorized <<<"$state" >/dev/null; then
      ok "Wi-Fi" "$(jq -r 'if .connected then "\(.ssid), \(.rssi) dBm" elif .power then "on, not connected" else "off" end' <<<"$state")"
    else bad "Wi-Fi" "Location Services not granted to OmacVM Bridge on the Mac (no network names)" human; fi
    if jq -e .can_share <<<"$state" >/dev/null; then ok "Wi-Fi password sharing" "QR card can ask the Mac"
    else skip "Wi-Fi password sharing" "not on a shareable network"; fi
  else bad "Wi-Fi" "the Bridge does not answer at $HOST:47831"; fi
  audio=$(as_user omacvm-bridge audio 2>/dev/null)
  if jq -e .devices >/dev/null 2>&1 <<<"$audio"; then
    ok "audio" "$(jq -r '(.devices[] | select(.default_output) | .name) // "no output"' <<<"$audio" | head -1)"
  else bad "audio" "no answer from the Bridge"; fi
  disp=$(as_user omacvm-bridge display 2>/dev/null)
  if jq -e .night_shift >/dev/null 2>&1 <<<"$disp"; then
    ok "Night Shift / True Tone" "$(jq -r '"night shift \(if .night_shift.enabled then "on" else "off" end), true tone \(if .true_tone.enabled then "on" else "off" end)"' <<<"$disp")"
  else bad "Night Shift / True Tone" "no answer from the Bridge"; fi
  if as_user bash -c 'timeout 4 omacvm-bridge events 2>/dev/null | grep -m1 -q "^event:"'; then ok "live updates" "event stream"
  else bad "live updates" "no events from the Bridge"; fi
  if user_active omacvm-bridge-osd.service; then ok "media keys OSD" "omacvm-bridge-osd"
  else bad "media keys OSD" "omacvm-bridge-osd.service not running"; fi
  layout=$(jq -r '[.bar.layout[]?[]?.id] | join(" ")' "$H/.config/omarchy/shell.json" 2>/dev/null)
  for w in omacvm.wifi omacvm.audio omacvm.nightshift; do
    if [[ " $layout " == *" $w "* ]]; then ok "bar: $w" "in the bar"
    elif [[ -s $H/.local/state/omacvm/pending-plugins ]]; then bad "bar: $w" "queued, not enabled yet (log out and in)"
    else bad "bar: $w" "not in the bar"; fi
  done
  for w in omarchy.network omarchy.audio; do
    [[ " $layout " == *" $w "* ]] && bad "bar: $w" "the stock widget is back next to OmacVM's"
  done
  if jq -e '.plugins[]? | select(.id == "omacvm.wifiqr")' "$H/.config/omarchy/shell.json" >/dev/null 2>&1; then ok "Wi-Fi QR card" "omacvm.wifiqr"
  else bad "Wi-Fi QR card" "omacvm.wifiqr not enabled"; fi
  check "Night Shift toggle" "Super+Ctrl+N drives the Mac" test -x /usr/local/bin/omarchy-toggle-nightlight
  if jq -e '[.bar.layout[]?[]? | select(.id == "omarchy.indicators") | (.items // ["NightLight"]) | index("NightLight")] | all(. == null)' "$H/.config/omarchy/shell.json" >/dev/null 2>&1 && ! pgrep -x hyprsunset >/dev/null; then
    ok "one night light" "the Mac's Night Shift; Omarchy's own is off"
  else bad "one night light" "Omarchy's night light (hyprsunset) is still reachable or running: omacvm apply"; fi
  if [[ $WALLPAPER == on ]]; then
    if user_active omacvm-wallpaper.path; then ok "wallpaper" "follows the Omarchy theme"
    else bad "wallpaper" "omacvm-wallpaper.path not active"; fi
  else skip "wallpaper" "off (chosen at setup)"; fi
else skip "Bridge" "off (chosen at setup): Omarchy's own Wi-Fi and audio widgets"; fi

section "Trackpad and keyboard"
if [[ $GESTURES == on || $TYPE == utm ]]; then   # on UTM the daemon also types Cmd as Super
  if systemctl is-active -q omacvm-gestures; then
    if connected_to "$HOST" 47830; then ok "gestures" "connected to the Mac"
    else bad "gestures" "service runs but is not connected to $HOST:47830"; fi
  else bad "gestures" "omacvm-gestures.service not running"; fi
fi
if [[ $GESTURES == on ]]; then
  check "virtual trackpad" "Magic Trackpad (OmacVM)" ev_device "Apple Inc. Magic Trackpad (OmacVM)"
  if grep -rqs '^hl.gesture({ fingers = 3' "$H/.config/hypr/"; then ok "workspace swipes" "3/4-finger gestures configured"
  else bad "workspace swipes" "no hl.gesture lines in ~/.config/hypr"; fi
else skip "trackpad gestures" "off (chosen at setup): macOS keeps its swipes"; fi
if [[ $GLIDE == on && $GESTURES == on ]]; then
  pid=$(systemctl show -p MainPID --value omacvm-gestures 2>/dev/null)
  if [[ -n $pid && $pid != 0 ]] && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qx 'OMACVM_FEATURE_glide=on'; then
    ok "Glide" "two-finger scrolling from the Mac (experimental)"
  else bad "Glide" "chosen, but the daemon runs without it: systemctl restart omacvm-gestures"; fi
  if [[ -f $H/.config/hypr/omacvm_glide.lua ]] && grep -qxF 'require("hypr.omacvm_glide")' "$H/.config/hypr/hyprland.lua"; then
    ok "Glide scroll settings" "omacvm_glide.lua"
  else bad "Glide scroll settings" "omacvm_glide.lua missing or not loaded from hyprland.lua (omacvm enable glide)"; fi
else skip "Glide" "off (experimental, opt-in: omacvm enable glide)"; fi
if [[ $TYPE == utm ]]; then
  check "Cmd as Super" "OmacVM keyboard (Mac shortcuts)" ev_device "OmacVM keyboard (Mac shortcuts)"
fi
check "Cmd+V paste" "Universal paste binding" grep -qs '"Universal paste"' "$H/.config/hypr/bindings.lua"
kb=$(as_user hyprctl getoption input:kb_layout -j 2>/dev/null | jq -r '.str // empty')
if [[ -n $kb ]]; then ok "keyboard layout" "$kb"; else bad "keyboard layout" "no layout from Hyprland"; fi

if [[ $TYPE == parallels ]]; then
  section "Parallels"
  check "Parallels Tools" "prltoolsd" systemctl is-active -q prltoolsd
  check "dynamic resolution" "parallels-dynres" test -x /usr/local/bin/parallels-dynres
  check "clipboard VM -> Mac" "parallels-clip-out" test -x /usr/local/bin/parallels-clip-out
else
  section "UTM"
  check "SPICE daemon" "spice-vdagentd" systemctl is-active -q spice-vdagentd
  if user_active omacvm-vdagent.service; then ok "clipboard + pointer" "omacvm-vdagent"
  else bad "clipboard + pointer" "omacvm-vdagent.service not running"; fi
  user_active spice-vdagent.service && bad "stock SPICE agent" "running: the pointer stops halfway"
  w=$(as_user hyprctl monitors -j 2>/dev/null | jq -r 'max_by(.width * .height) | .width')
  tab=$(python3 - 2>/dev/null <<'EOF'
import evdev
for p in evdev.list_devices():
    d = evdev.InputDevice(p)
    if d.name == "spice vdagent tablet":
        print(dict(d.capabilities(absinfo=True)[3])[0].max + 1)
EOF
)
  if [[ -z $tab ]]; then skip "pointer range" "no SPICE tablet yet (UTM window not open?)"
  elif [[ $tab == "$w" ]]; then ok "pointer range" "${tab} px, the whole screen"
  else bad "pointer range" "tablet $tab px vs screen $w px"; fi
  check "QEMU guest agent" "utmctl ip-address/exec" systemctl is-active -q qemu-guest-agent
  check "virtio-gpu settings" "90-omacvm-utm.conf" test -f /etc/environment.d/90-omacvm-utm.conf
fi

section "Speed and safety"
k=$(uname -r)
[[ -n $THP_KERNEL ]] || { [[ $k == *thp* ]] && THP_KERNEL=on || THP_KERNEL=off; }
if [[ $k == *thp* ]]; then ok "kernel" "$k (memory-optimized: THP + MGLRU)"
elif [[ $THP_KERNEL == off ]]; then ok "kernel" "$k (Arch Linux ARM's own; memory-optimized kernel not chosen)"
elif ! command -v grub-mkconfig >/dev/null; then skip "kernel" "$k (the memory-optimized kernel needs GRUB)"
else bad "kernel" "$k: not the memory-optimized kernel yet (reboot after apply.sh?)"; fi
thp=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
if [[ $thp == always || $thp == madvise ]]; then ok "transparent huge pages" "$thp"
elif [[ $k == *thp* ]]; then bad "transparent huge pages" "${thp:-unavailable}"
else skip "transparent huge pages" "${thp:-not in this kernel} (part of the memory-optimized kernel)"; fi
lru=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)
if [[ -n $lru && $lru != 0x0000 ]]; then ok "MGLRU" "$lru"
elif [[ $k == *thp* ]]; then bad "MGLRU" "${lru:-unavailable}"
else skip "MGLRU" "${lru:-not in this kernel} (part of the memory-optimized kernel)"; fi
z=$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | awk '/zram/ { print $2; exit }')
[[ -n $z ]] && ok "zram swap" "$z" || bad "zram swap" "none (reboot after apply.sh?)"
if command -v grub-mkconfig >/dev/null; then
  check "bootable snapshots" "grub-btrfsd" systemctl is-active -q grub-btrfsd
fi
if ufw status 2>/dev/null | grep -q "omacvm: ssh from the Mac"; then ok "SSH from the Mac" "firewall rule"
else bad "SSH from the Mac" "no OmacVM firewall rule"; fi

section "Choices"
if [[ $IDLE_LOCK == off ]]; then
  if [[ -f $H/.local/state/omarchy/indicators/stay-awake ]]; then ok "screensaver and lock" "off: the Mac's lock protects the VM"
  else bad "screensaver and lock" "chosen off, but Omarchy's Stay Awake is not set"; fi
else ok "screensaver and lock" "Omarchy's own, after idle"; fi
[[ -f /etc/sddm.conf.d/20-omacvm-autologin.conf ]] && ok "autologin" "on" || ok "autologin" "off"

section "Omanotch"
if [[ $OMANOTCH == on && ! -x $H/.local/bin/notchcast ]]; then
  if [[ -f /etc/systemd/user/omacvm-omanotch.service ]]; then bad "Omanotch" "chosen, not installed yet: it installs at the next login"
  else bad "Omanotch" "chosen, not set up (omacvm enable omanotch)"; fi
elif systemctl --user -M "$U@" list-unit-files notchcast.service 2>/dev/null | grep -q notchcast; then
  if connected_to "$HOST" 47811; then ok "Omanotch" "streaming the bar to the Mac"
  else bad "Omanotch" "notchcast is not connected to $HOST:47811 (Omanotch on the Mac serves one VM at a time: is it running, or is another VM connected?)"; fi
else skip "Omanotch" "not installed (omacvm enable omanotch, on a MacBook with a notch)"; fi

(( TSV )) && exit $(( fails ? 1 : 0 ))
echo
(( fails )) && { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
