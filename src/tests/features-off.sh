#!/bin/bash
# A feature switched off is off on every route: nothing of it runs in the VM,
# nothing in the VM connects to the Mac for it, the Mac side does not serve
# it, and the checks say "off". No VM needed: the VM side's off steps
# (guest/off.sh) run in a scratch folder with systemctl and the session
# replaced; the Mac side's lines run with their helpers replaced.
#   src/tests/features-off.sh
# Every feature in src/features.tsv must be in the table below: a new feature
# says here what off means for it.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---------- every feature is covered ----------
# name: how off is made sure of (tested below, or why there is nothing to test)
covered="
bridge:off.sh bridge_off; no Bridge port from OmacVM.app
wallpaper:off.sh wallpaper_off (its watcher talks to the Bridge)
gestures:off.sh gestures_off; apply skips Gestures; no Gestures port from OmacVM.app
scroll-momentum:inside the gestures daemon; needs gestures (features_fix)
omanotch:off.sh omanotch_off, also an install queued for the next login; no Omanotch port from OmacVM.app
mac-clock:the Mac's format is read only when on (apply); clock.sh off, also a queued clock
camera:camera/guest/install.sh off on every apply; OmacVM.app does not serve the camera port
battery:battery/guest/install.sh off on every apply; OmacVM.app does not serve the battery port
idle-lock:nothing of it talks to the Mac
autologin:nothing of it talks to the Mac
thp-kernel:nothing of it talks to the Mac
fast-network:apply takes the Mac's service off when no VM has it (src/net/mac/test.sh)
"
while IFS=$'\t' read -r name _; do
  [[ -z $name || $name == \#* ]] && continue
  grep -q "^$name:" <<<"$covered" && echo "ok   $name: in this test's table" ||
    { echo "FAIL $name: not in src/tests/features-off.sh's table: say what off means for it"; fail=1; }
done < "$R/src/features.tsv"

# ---------- the VM side: guest/off.sh in a scratch folder ----------
# off STATE-SETUP FUNCTION: runs it as guest/install.sh would; CALLS has what
# it asked of systemd and the session, OUT what it logged.
U=me H=/home/me
ROOT=$T/root CALLS=$T/calls OUT=$T/out
reset_root() { rm -rf "$ROOT" "$CALLS" "$OUT"; mkdir -p "$ROOT$H/.config/hypr" "$ROOT/etc/systemd/user"; : > "$CALLS"; : > "$OUT"; }
run_off() {   # FUNCTION [SESSION=0|1] [SERVICE=enabled|active|none]
  ( SESSION=${2:-0} SERVICE=${3:-none}
    log() { echo "$*" >> "$OUT"; }
    user_ctl() { echo "user_ctl $*" >> "$CALLS"; }
    systemctl() {
      case "$1 $2" in
        "is-enabled -q") [[ $SERVICE == enabled ]] ;;
        "is-active -q") [[ $SERVICE == enabled || $SERVICE == active ]] ;;
        *) echo "systemctl $*" >> "$CALLS" ;;
      esac
    }
    in_session() { echo "in_session $*" >> "$CALLS"; (( SESSION )); }
    pkill() { echo "pkill $*" >> "$CALLS"; }
    chown() { :; }
    restart_shell_later() { echo "restart-shell" >> "$CALLS"; }
    /repo/guest/omanotch-notifications.sh() { :; }
    # shellcheck source=../guest/off.sh
    source "$R/src/guest/off.sh"
    R=/repo   # this copy of src/ in the VM
    "$1" )
}
has() { [[ -e $ROOT$1 || -L $ROOT$1 ]] && echo yes || echo no; }
called() { grep -qF -- "$1" "$CALLS" && echo yes || echo no; }
link() { mkdir -p "$(dirname "$ROOT$1")"; ln -sf "$2" "$ROOT$1"; }
file() { mkdir -p "$(dirname "$ROOT$1")"; printf '%s\n' "${2:-x}" > "$ROOT$1"; }

# Gestures: the daemon is stopped and disabled whatever state it is in.
for s in enabled active; do
  reset_root; run_off gestures_off 0 "$s"
  expect "gestures off ($s daemon): disabled and stopped" yes "$(called "systemctl disable --now omacvm-gestures")"
done
reset_root; run_off gestures_off 0 none
expect "gestures off, no daemon: nothing" "" "$(cat "$OUT" "$CALLS")"

# Omanotch queued for the next login, not built yet (the RC3 bug: it built
# itself at the next login although off).
reset_root
file /etc/systemd/user/omacvm-omanotch.service
link /etc/systemd/user/graphical-session.target.wants/omacvm-omanotch.service /etc/systemd/user/omacvm-omanotch.service
run_off omanotch_off
expect "omanotch off, queued: says so" "Omanotch: off" "$(cat "$OUT")"
expect "omanotch off, queued: the queued install is gone" no "$(has /etc/systemd/user/omacvm-omanotch.service)"
expect "omanotch off, queued: not enabled for any user" no "$(has /etc/systemd/user/graphical-session.target.wants/omacvm-omanotch.service)"
expect "omanotch off, queued: disabled" yes "$(called "systemctl --global disable omacvm-omanotch.service")"

# Omanotch built and running, nobody logged in (its uninstall needs the session).
reset_root
file "$H/.local/bin/notchcast"; file "$H/.config/systemd/user/notchcast.service"
file "$H/.config/systemd/user/notchcast.service.d/omacvm-host.conf"
link "$H/.config/systemd/user/graphical-session.target.wants/notchcast.service" "$H/.config/systemd/user/notchcast.service"
file "$H/.config/hypr/notchbar.lua"; file "$H/.local/state/omacvm/omanotch"
file /etc/pacman.d/hooks/zz-omacvm-omanotch-notifications.hook
printf '%s\n' 'require("hypr.other")' '' '-- omarchy-notch-bar: hidden output for the macOS notch helper.' 'require("hypr.notchbar")' > "$ROOT$H/.config/hypr/hyprland.lua"
run_off omanotch_off 0
expect "omanotch off, built: its uninstall tried in the session" yes "$(called "in_session bash /repo/omanotch/guest/uninstall.sh")"
for p in "$H/.local/bin/notchcast" "$H/.config/systemd/user/notchcast.service" "$H/.config/systemd/user/notchcast.service.d" \
         "$H/.config/systemd/user/graphical-session.target.wants/notchcast.service" "$H/.config/hypr/notchbar.lua" \
         /etc/pacman.d/hooks/zz-omacvm-omanotch-notifications.hook; do
  expect "omanotch off, built, no session: $p gone" no "$(has "$p")"
done
expect "omanotch off: hyprland.lua no longer loads notchbar" "$(printf '%s\n' 'require("hypr.other")' '')" "$(cat "$ROOT$H/.config/hypr/hyprland.lua")"
expect "omanotch off: notchcast stopped" yes "$(called "user_ctl disable --now notchcast.service")"
: > "$OUT"; : > "$CALLS"; run_off omanotch_off 0
expect "omanotch off again: nothing to do" "" "$(cat "$OUT" "$CALLS")"

# The Bridge, nobody logged in: services, client, queued widgets; the widgets
# in the bar are disabled at the next login.
reset_root
for b in omacvm-bridge omacvm-bridge-osd omacvm-bridge-events omarchy-toggle-nightlight; do file "/usr/local/bin/$b"; done
for u in omacvm-bridge-osd.service omacvm-bridge-events.socket omacvm-bridge-events.service omacvm-plugins.service; do file "/etc/systemd/user/$u"; done
link "$H/.config/systemd/user/graphical-session.target.wants/omacvm-bridge-osd.service" /etc/systemd/user/omacvm-bridge-osd.service
link "$H/.config/systemd/user/sockets.target.wants/omacvm-bridge-events.socket" /etc/systemd/user/omacvm-bridge-events.socket
file "$H/.local/state/omacvm/pending-plugins" "$(printf '%s\n' omacvm.workspaces omacvm.wifi omacvm.audio)"
file "$H/.config/omarchy/shell.json" '{"bar": {"layout": {"right": [{"id": "omacvm.wifi"}, {"id": "omarchy.clock"}]}}}'
run_off bridge_off 0
expect "bridge off: says so" "bridge: off" "$(cat "$OUT")"
for p in /usr/local/bin/omacvm-bridge /usr/local/bin/omacvm-bridge-osd /usr/local/bin/omacvm-bridge-events \
         /etc/systemd/user/omacvm-bridge-osd.service /etc/systemd/user/omacvm-bridge-events.socket \
         "$H/.config/systemd/user/graphical-session.target.wants/omacvm-bridge-osd.service" \
         "$H/.config/systemd/user/sockets.target.wants/omacvm-bridge-events.socket"; do
  expect "bridge off, no session: $p gone" no "$(has "$p")"
done
expect "bridge off: queued widgets not enabled at the next login" omacvm.workspaces "$(cat "$ROOT$H/.local/state/omacvm/pending-plugins")"
expect "bridge off, no session: widgets disabled at the next login" 5 "$(grep -c . "$ROOT$H/.local/state/omacvm/pending-plugins-off")"
expect "bridge off, no session: omacvm-plugins runs at the next login" yes "$(has "$H/.config/systemd/user/graphical-session.target.wants/omacvm-plugins.service")"
expect "bridge off: widgets streaming from the Mac stopped" yes "$(called "pkill -u me -f -- /usr/local/bin/omacvm-bridge")"
: > "$OUT"; run_off bridge_off 0
expect "bridge off again, widgets still in the bar: queued once" "bridge: off 5" "$(cat "$OUT") $(grep -c . "$ROOT$H/.local/state/omacvm/pending-plugins-off")"
reset_root; file /usr/local/bin/omacvm-bridge
run_off bridge_off 1
expect "bridge off, session: widgets disabled now" yes "$(called "in_session bash -c")"
expect "bridge off, session: nothing queued" no "$(has "$H/.local/state/omacvm/pending-plugins-off")"
reset_root; run_off bridge_off 0
expect "bridge off, no Bridge: nothing" "" "$(cat "$OUT" "$CALLS")"
grep -q 'pending-plugins-off' "$R/src/lib/omacvm-plugins" && echo "ok   omacvm-plugins disables the queued widgets" ||
  { echo "FAIL omacvm-plugins does not read pending-plugins-off"; fail=1; }

# The wallpaper's watcher, enabled for the user only (no user manager to ask).
reset_root
file /usr/local/bin/omacvm-wallpaper; file /etc/systemd/user/omacvm-wallpaper.path; file /etc/systemd/user/omacvm-wallpaper.service
link "$H/.config/systemd/user/default.target.wants/omacvm-wallpaper.path" /etc/systemd/user/omacvm-wallpaper.path
link "$H/.config/systemd/user/graphical-session.target.wants/omacvm-wallpaper.service" /etc/systemd/user/omacvm-wallpaper.service
run_off wallpaper_off 0
for p in /usr/local/bin/omacvm-wallpaper /etc/systemd/user/omacvm-wallpaper.path \
         "$H/.config/systemd/user/default.target.wants/omacvm-wallpaper.path" \
         "$H/.config/systemd/user/graphical-session.target.wants/omacvm-wallpaper.service"; do
  expect "wallpaper off, no session: $p gone" no "$(has "$p")"
done

# guest/install.sh runs the off steps whenever a feature is off (not only when
# one marker of it is there).
inst=$R/src/guest/install.sh
for f in gestures bridge wallpaper omanotch; do
  b=$(awk -v f="$f" 'index($0, "if [[ ${F[" f "]} == on ]]; then") == 1 {on = 1} on {print} on && /^fi$/ {exit}' "$inst")
  [[ $(grep -c '^else$' <<<"$b") == 1 && $(grep -cE "^  ${f}_off( |$)" <<<"$b") == 1 && $(grep -c '^elif' <<<"$b") == 0 ]] &&
    echo "ok   install.sh: $f off -> ${f}_off, always" || { echo "FAIL install.sh: $f off does not always run ${f}_off"; fail=1; }
done
b=$(awk 'index($0, "if [[ ${F[battery]} == on ]]; then") == 1 {on = 1} on {print} on && /^fi$/ {exit}' "$inst")
[[ $b == *$'\nelse\n'*'battery/guest/install.sh" off'* && $b != *elif* ]] && echo "ok   install.sh: battery off -> its installer's off, always" ||
  { echo "FAIL install.sh: battery off does not always run its installer's off"; fail=1; }
grep -q '^"$R/camera/guest/install.sh" "$U" "$TYPE" "${F\[camera\]}"' "$inst" && echo "ok   install.sh: camera's installer on every apply, with the choice" ||
  { echo "FAIL install.sh: camera's installer not run with the choice"; fail=1; }

# clock.sh off: also a clock queued for the next login goes.
mkdir -p "$T/bin" "$T/home/.local/state/omacvm"
printf '#!/bin/sh\necho "me:x:1:1::%s:/bin/bash"\n' "$T/home" > "$T/bin/getent"; chmod +x "$T/bin/getent"
echo "EEE HH:mm" > "$T/home/.local/state/omacvm/pending-clock"
PATH="$T/bin:$PATH" bash "$R/src/clock/guest/clock.sh" me off >/dev/null 2>&1
expect "mac-clock off: the queued clock goes" no "$( [[ -e $T/home/.local/state/omacvm/pending-clock ]] && echo yes || echo no)"

# ---------- omacvm check in the VM: off says off ----------
# The Omanotch rows (check.sh) with the VM's state replaced.
om=$(awk '/^section "Omanotch"$/ {on = 1; next} on && /^elif \[\[ \$OMANOTCH == on/ {exit} on {print}' "$R/src/guest/check.sh")
[[ $om == 'if [[ $OMANOTCH == off ]]; then'* ]] || { echo "FAIL check.sh: no Omanotch off rows"; fail=1; }
om_check() {   # NOTCHCAST(active|none) QUEUED(enabled|disabled) -> the row
  ( A=$1 Q=$2 OMANOTCH=off HOST=10.0.2.2 U=me
    user_active() { [[ $A == active ]]; }
    pgrep() { [[ $A == active ]]; }
    connected_to() { false; }
    systemctl() { echo "$Q"; }
    bad() { echo "fail: $2"; }
    skip() { echo "skip: $2"; }
    eval "$om"$'\nfi' )
}
expect "check, omanotch off: off" "skip: off (chosen at setup)" "$(om_check none disabled)"
expect "check, omanotch off, notchcast runs: fails" "fail: off, but notchcast runs and talks to the Mac: omacvm apply" "$(om_check active disabled)"
expect "check, omanotch off, install queued: fails" "fail: off, but queued to install at the next login: omacvm apply" "$(om_check none enabled)"
for r in '"wallpaper" "off, but' '"Bridge" "off, but' '"camera" "off, but' '"battery" "off, but' "\"the Mac's clock\" \"off (chosen"; do
  grep -qF "$r" "$R/src/guest/check.sh" && echo "ok   check.sh: $r" || { echo "FAIL check.sh has no $r row"; fail=1; }
done

# ---------- the Mac side ----------
# omacvm apply: Gestures and the token only with gestures on.
mac=$(grep -E 'skip-gestures\)|bridge_token_ensure; fi' "$R/src/cmd/apply.sh")
[[ $(wc -l <<<"$mac") == *2 ]] || { echo "FAIL apply.sh gestures lines not found"; exit 1; }
apply() {   # TYPE GESTURES -> the installer's gestures argument and whether the token goes in
  ( TYPE=$1 G=$2 TOKEN=1 args=() tok=no
    on() { [[ $1 == gestures && $G == on ]]; }
    bridge_token_ensure() { tok=yes; }
    eval "$mac"
    echo "${args[*]:-none} token=$tok" )
}
for t in utm fusion app; do
  expect "$t, gestures off: Mac side skips Gestures" "--skip-gestures token=no" "$(apply $t off)"
  expect "$t, gestures on: Mac side installs Gestures" "none token=yes" "$(apply $t on)"
done

# OmacVM.app: apply writes the VM's features into its folder, the app opens
# the Mac only for the ones that are on (MacLinks.swift, compiled here).
source "$R/src/lib/app.sh"
mkdir -p "$T/vm"
app_features_write "$T/vm" "bridge=off gestures=on omanotch=off battery=off camera=on mac-clock=on"
expect "app: features written" "bridge=off gestures=on omanotch=off battery=off camera=on mac-clock=on" "$(cat "$T/vm/features")"
app_features_write "$T/vm" "bridge=off gestures=on omanotch=off battery=off camera=on mac-clock=on"
expect "app: unchanged features: status 1" 1 "$?"
if command -v swiftc >/dev/null; then
  cat > "$T/main.swift" <<'EOF'
import Foundation
let a = CommandLine.arguments
let l = a.count > 1 ? MacLinks.load(folder: URL(fileURLWithPath: a[1])) : MacLinks()
print("ports=\(l.hostPorts) battery=\(l.battery) camera=\(l.camera)")
EOF
  if swiftc -O -o "$T/links" "$R/app/app/Sources/OmacVM/MacLinks.swift" "$T/main.swift" 2>"$T/swiftc.log"; then
    expect "app: only gestures' port, camera served, battery not" "ports=47830 battery=false camera=true" "$("$T/links" "$T/vm")"
    app_features_write "$T/vm" "bridge=off wallpaper=off gestures=off omanotch=off battery=off camera=off"
    expect "app: all off: no port to the Mac, no battery, no camera" "ports= battery=false camera=false" "$("$T/links" "$T/vm")"
    app_features_write "$T/vm" "bridge=on gestures=on omanotch=on battery=on camera=on"
    expect "app: all on" "ports=47811,47830,47831 battery=true camera=true" "$("$T/links" "$T/vm")"
    mkdir -p "$T/old"
    expect "app: a VM from before (no features file): as before" "ports=47811,47830,47831 battery=true camera=true" "$("$T/links" "$T/old")"
  else
    echo "FAIL MacLinks.swift does not compile:"; cat "$T/swiftc.log"; fail=1
  fi
else
  echo "skip MacLinks.swift: no swiftc"
fi
grep -q 'env\["OMACVM_SLIRP_HOST_PORTS"\] = links.hostPorts' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  grep -q 'if links.battery { startBattery() }' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  grep -q 'if links.camera { startCamera() }' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  echo "ok   Runner.swift follows MacLinks" || { echo "FAIL Runner.swift does not follow MacLinks"; fail=1; }

exit $fail
