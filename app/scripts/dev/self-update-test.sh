#!/bin/bash
# End-to-end test of OmacVM.app's self-update (docs/adr/0033) on this Mac,
# apart from any installed OmacVM: test bundles with their own bundle id in
# WORK (never /Applications), a local feed signed with a test key on
# 127.0.0.1, its own settings folder, a VM without an OS, all out of sight.
#   OMACVM_SIGN_ID=<Developer ID> scripts/build-app.sh --name "OmacVM SU-test" --id org.omacvm.sutest
#   OMACVM_SIGN_ID=<Developer ID> scripts/dev/self-update-test.sh dist/"OmacVM SU-test.app" WORK
# Versions made from the build (copied, version changed, signed again):
# 2.7.0 installed, 2.7.1 good, 2.7.2 without a QEMU library, 2.7.3 whose
# launcher exits at once. Tests: weekly schedule, silence switch, update
# held back while a VM runs and applied after, rollback of both broken
# builds, the one step back, a renamed copy. Exit 0 when all pass.
# check() evals its condition: variables used there look unused.
# shellcheck disable=SC2034
set -uo pipefail
SRC=${1:?usage: self-update-test.sh BUILT_APP WORK}
WORK=${2:?usage: self-update-test.sh BUILT_APP WORK}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
ID=org.omacvm.sutest
NAME="OmacVM SU-test"
PORT=${PORT:-18765}
SIGN_ID=${OMACVM_SIGN_ID:?set OMACVM_SIGN_ID (a Developer ID of team 722686Y34B)}
die() { echo "ERROR: $*" >&2; exit 1; }
[[ ! -e $HOME/.omacvm-user-testing ]] || die "the user is testing (~/.omacvm-user-testing): no VMs on this Mac now"
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist" 2>/dev/null) == "$ID" ]] ||
  die "$SRC is not a $ID test build"
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
[[ $WORK != /Applications* ]] || die "not in /Applications"

pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
log() { printf '\n== %s\n' "$*"; }

UPD="$HOME/Library/Application Support/OmacVM/Updates/$ID"
INST=$WORK/install
APP=$INST/$NAME.app
FEED=$WORK/feed
SETTINGS=$WORK/settings
SIGN=$REPO/src/release/sign.swift

# What must not move: the installed app's settings, the shared settings file.
fingerprint() {
  { defaults read org.omacvm.app 2>/dev/null; cat "$HOME/Library/Application Support/omacvm/settings.json" 2>/dev/null
    for a in /Applications/*.app "$HOME"/Applications/*.app; do
      [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$a/Contents/Info.plist" 2>/dev/null) == org.omacvm.app ]] &&
        { echo "$a"; shasum "$a/Contents/Info.plist" "$a/Contents/MacOS/OmacVM"; }
    done; } | shasum | cut -c1-16
}
FP_BEFORE=$(fingerprint)

# Swap scripts first (one waiting for a marker would bring an app back),
# then every app and VM from WORK.
stop_all() {
  pkill -f "update-swap.sh .*$WORK/" 2>/dev/null
  pkill -f "$WORK/.*/Contents/" 2>/dev/null
  sleep 1
}
cleanup() {
  stop_all
  [[ -n ${SERVER:-} ]] && kill "$SERVER" 2>/dev/null
}
trap cleanup EXIT
stop_all   # leftovers of an earlier run

# ---- versions ----
log "test versions"
rm -rf "$WORK/v" "$FEED" "$SETTINGS" "$INST" "$WORK/VMs" "$UPD"
mkdir -p "$WORK/v" "$FEED" "$SETTINGS" "$INST" "$WORK/VMs"
resign() { codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none --identifier "$ID" \
  --entitlements "$HERE/app/OmacVM.entitlements" "$1" 2>/dev/null; }
make_version() {   # VERSION -> $WORK/v/VERSION/NAME.app
  local d=$WORK/v/$1
  mkdir -p "$d"; ditto "$SRC" "$d/$NAME.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" -c "Set :CFBundleVersion $1" "$d/$NAME.app/Contents/Info.plist"
}
for v in 2.7.0 2.7.1 2.7.2 2.7.3; do make_version $v; done
# 2.7.2: QEMU misses a library (dyld stops it).
rm "$WORK/v/2.7.2/$NAME.app/Contents/Resources/runtime/lib/libvirglrenderer.1.dylib"
# 2.7.3: a launcher that exits at once.
printf 'int main(void) { return 3; }\n' > "$WORK/v/exit3.c"
cc -o "$WORK/v/2.7.3/$NAME.app/Contents/MacOS/OmacVM" "$WORK/v/exit3.c"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$WORK/v/2.7.3/$NAME.app/Contents/MacOS/OmacVM"
for v in 2.7.0 2.7.1 2.7.2 2.7.3; do resign "$WORK/v/$v/$NAME.app" || die "signing $v"; done
DEVID='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "722686Y34B"'
for v in 2.7.0 2.7.1 2.7.2 2.7.3; do
  check "$v is signed with the Developer ID" 'codesign --verify --deep --strict -R="$DEVID" "$WORK/v/$v/$NAME.app" 2>/dev/null'
done
ditto "$WORK/v/2.7.0/$NAME.app" "$APP"

# ---- feed ----
swift "$SIGN" keygen "$WORK/test-key" > "$WORK/test-key.pub" || die keygen
publish() {   # VERSION: the feed offers it
  local z=$FEED/$NAME-$1.zip
  rm -f "$FEED"/*.zip
  ditto -c -k --keepParent "$WORK/v/$1/$NAME.app" "$z"
  cat > "$FEED/OmacVM-appcast.json" <<EOF
{"schema": 1, "kind": "app-feed", "version": "$1", "url": "http://127.0.0.1:$PORT/$(basename "$z" | sed 's/ /%20/g')",
 "length": $(stat -f %z "$z"), "sha256": "$(shasum -a 256 "$z" | cut -d' ' -f1)", "minimum_macos": "15.0"}
EOF
  swift "$SIGN" sign "$WORK/test-key" "$FEED/OmacVM-appcast.json" > "$FEED/OmacVM-appcast.json.sig"
}
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED" > "$WORK/server.log" 2>&1 &
SERVER=$!
sleep 1
requests() { grep -c "GET /$1" "$WORK/server.log"; }

# ---- the test app's own settings ----
defaults delete "$ID" >/dev/null 2>&1
defaults write "$ID" vmsRoot "$WORK/VMs"
defaults write "$ID" installedPath "$APP"
defaults write "$ID" startFullScreen -bool false
days_ago() { defaults write "$ID" updateLastCheck -date "$(date -u -v-"$1"d '+%Y-%m-%d %H:%M:%S +0000')"; }
ENV=(--env "OMACVM_APPCAST_URL=http://127.0.0.1:$PORT/OmacVM-appcast.json" --env "OMACVM_APPCAST_KEY=$(cat "$WORK/test-key.pub")"
     --env "OMACVM_SETTINGS_DIR=$SETTINGS" --env OMACVM_COCOA_HIDDEN=1 --env OMACVM_UPDATE_WAIT=20)
start_app() { open -n "${ENV[@]}" "$1" --args "${@:2}"; }
launcher_pid() { pgrep -f "$1/Contents/MacOS/OmacVM" | head -1; }
# A swap that is still on (waiting for the new app's answer) ends first.
wait_swaps() { local i; for ((i = 0; i < 180; i++)); do pgrep -f "update-swap.sh .*$WORK/" >/dev/null || return 0; sleep 0.5; done; return 1; }
quit_app() { local p; wait_swaps; p=$(launcher_pid "$1"); [[ -z $p ]] || { kill "$p"; sleep 1; }; }
# PlistBuddy, not defaults: cfprefsd caches a plist it read by path.
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
wait_for() {   # SECONDS CONDITION
  local i; for ((i = 0; i < $1 * 2; i++)); do eval "$2" && return 0; sleep 0.5; done; return 1
}
logtail() { tail -3 "$UPD/update.log" 2>/dev/null | sed 's/^/    /'; }

# ---- 1. weekly schedule ----
log "1. weekly: checked a day ago -> no check; 8 days ago -> check, download, offer"
publish 2.7.1
days_ago 1
start_app "$APP"
sleep 30
check "checked a day ago: no request" '[[ $(requests OmacVM-appcast.json) == 0 ]]'
quit_app "$APP"
days_ago 8
start_app "$APP"
check "8 days ago: feed fetched within 40 s" 'wait_for 40 "[[ \$(requests OmacVM-appcast.json.sig) -ge 1 ]]"'
check "2.7.1 downloaded, checked and offered" 'wait_for 30 "grep -q \"ready: 2.7.1\" \"\$UPD/update.log\""'
check "the staged app has no quarantine flag" '! xattr -r "$UPD/staged" 2>/dev/null | grep -q quarantine'
check "nothing replaced without asking" '[[ $(version "$APP") == 2.7.0 ]]'
quit_app "$APP"; logtail

# ---- 2. silence ----
log "2. update checks off: no request, nothing offered"
printf '{"update_checks": false}\n' > "$SETTINGS/settings.json"
n0=$(requests OmacVM-appcast.json)
days_ago 8
start_app "$APP"
sleep 30
check "checks off: no request after 30 s" '[[ $(requests OmacVM-appcast.json) == "$n0" ]]'
quit_app "$APP"
printf '{"update_checks": true}\n' > "$SETTINGS/settings.json"

# ---- 3. held back while a VM runs, applied after ----
log "3. a VM runs from the app: the update waits, then goes in when it stops"
VM=$WORK/VMs/SU-test-vm
mkdir -p "$VM"
cat > "$VM/vm.env" <<EOF
NAME='SU-test-vm'
CPUS=2
MEM_MB=1024
DISK_GB=1
SSH_PORT=52399
VM_USER='test'
FEATURES='bridge=off gestures=off omanotch=off camera=off battery=off'
EOF
dd if=/dev/null of="$VM/disk.img" bs=1 seek=$((1 << 30)) 2>/dev/null
mkfile -n 64m "$VM/efi-vars.fd"; touch "$VM/ready"
start_app "$APP" --start --vm SU-test-vm
check "the test VM's QEMU runs from the app" 'wait_for 20 "pgrep -f \"\$APP/Contents/Resources/runtime/bin/OmacVM\" >/dev/null"'
start_app "$APP" --update-now
check "update asked for: held back" 'wait_for 30 "grep -q \"install 2.7.1 deferred\" \"\$UPD/update.log\""'
sleep 3
check "still 2.7.0 while the VM runs" '[[ $(version "$APP") == 2.7.0 ]]'
check "the VM still runs" 'pgrep -f "$APP/Contents/Resources/runtime/bin/OmacVM" >/dev/null'
# Shut the VM down (QMP quit: QEMU ends with 0, as after a guest power-off).
QMP=$(getconf DARWIN_USER_TEMP_DIR)omacvm/$(printf '%s' "$VM" | shasum | cut -c1-8).qmp
python3 - "$QMP" <<'EOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rw')
f.readline()
for c in ("qmp_capabilities", "quit"):
    f.write(json.dumps({"execute": c}) + "\n"); f.flush(); time.sleep(0.3)
EOF
check "after the VM stopped: 2.7.1 in place" 'wait_for 60 "[[ \$(version \"\$APP\") == 2.7.1 ]]"'
check "swap result: installed" 'wait_for 30 "grep -q \"result: installed 2.7.0 2.7.1\" \"\$UPD/update.log\""'
check "2.7.0 kept for one step back" '[[ $(version "$UPD/previous/$NAME.app") == 2.7.0 ]]'
check "2.7.1 runs" 'wait_for 10 "[[ -n \$(launcher_pid \"\$APP\") ]]"'
check "2.7.1 read the result (its window says it updated)" 'wait_for 10 "[[ ! -e \"\$UPD/result\" ]]"'
check "installed app keeps the Developer ID" 'codesign --verify --deep --strict -R="$DEVID" "$APP" 2>/dev/null'
quit_app "$APP"; logtail

# ---- 4. rollback: QEMU does not start ----
log "4. 2.7.2 (QEMU misses a library): back to 2.7.1, 2.7.2 skipped"
publish 2.7.2
start_app "$APP" --update-now
check "rolled back within 60 s" 'wait_for 60 "grep -q \"result: rolled-back 2.7.2\" \"\$UPD/update.log\""'
check "2.7.1 in place again" '[[ $(version "$APP") == 2.7.1 ]]'
check "2.7.1 runs again" 'wait_for 10 "[[ -n \$(launcher_pid \"\$APP\") ]]"'
check "2.7.2 skipped" 'wait_for 10 "[[ \$(defaults read $ID updateSkip 2>/dev/null) == 2.7.2 ]]"'
check "2.7.0 still kept" '[[ $(version "$UPD/previous/$NAME.app") == 2.7.0 ]]'
quit_app "$APP"; logtail

# Skipped: a weekly check neither downloads nor offers it.
n0=$(requests "OmacVM%20SU-test-2.7.2.zip")
days_ago 8
start_app "$APP"
check "weekly check after the rollback: feed fetched" 'wait_for 40 "grep -q \"2.7.2 is skipped\" \"\$UPD/update.log\""'
check "skipped version not downloaded again" '[[ $(requests "OmacVM%20SU-test-2.7.2.zip") == "$n0" ]]'
quit_app "$APP"

# ---- 5. rollback: the launcher exits at once ----
log "5. 2.7.3 (launcher exits at once): back to 2.7.1"
publish 2.7.3
start_app "$APP" --update-now
check "rolled back after the 20 s wait" 'wait_for 60 "grep -q \"result: rolled-back 2.7.3\" \"\$UPD/update.log\""'
check "2.7.1 in place again" '[[ $(version "$APP") == 2.7.1 ]]'
check "2.7.1 runs again" 'wait_for 10 "[[ -n \$(launcher_pid \"\$APP\") ]]"'
quit_app "$APP"; logtail

# ---- 6. one step back (the menu's Go Back runs this) ----
log "6. go back to 2.7.0"
OMACVM_COCOA_HIDDEN=1 OMACVM_SETTINGS_DIR=$SETTINGS OMACVM_APPCAST_KEY=$(cat "$WORK/test-key.pub") \
  OMACVM_APPCAST_URL=http://127.0.0.1:$PORT/OmacVM-appcast.json \
  bash "$APP/Contents/Resources/scripts/update-swap.sh" rollback "$APP" - "$UPD" 99999 "$(openssl rand -hex 16)" \
  >> "$UPD/update.log" 2>&1 &
check "2.7.0 in place" 'wait_for 60 "[[ \$(version \"\$APP\") == 2.7.0 ]]"'
check "swap result: went back" 'wait_for 30 "grep -q \"result: went-back 2.7.1\" \"\$UPD/update.log\""'
check "2.7.1 skipped" 'wait_for 10 "[[ \$(defaults read $ID updateSkip 2>/dev/null) == 2.7.1 ]]"'
quit_app "$APP"; logtail

# ---- 7. a copy installed under its own name ----
log "7. renamed copy 'Omarchy SU' (ad hoc, as the installer does): keeps its name"
publish 2.7.1
defaults delete "$ID" updateSkip 2>/dev/null
REN=$INST/Omarchy\ SU.app
ditto "$WORK/v/2.7.0/$NAME.app" "$REN"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Omarchy SU" -c "Set :CFBundleDisplayName Omarchy SU" "$REN/Contents/Info.plist"
codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$REN" 2>/dev/null
start_app "$REN" --update-now
check "renamed copy updated to 2.7.1" 'wait_for 90 "[[ \$(version \"\$REN\") == 2.7.1 ]]"'
check "it keeps its name" '[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$REN/Contents/Info.plist") == "Omarchy SU" ]]'
check "its signature is valid" 'codesign --verify --deep --strict "$REN" 2>/dev/null'
check "its QEMU keeps the Developer ID" 'codesign --verify -R="$DEVID" "$REN/Contents/Resources/runtime/bin/OmacVM" 2>/dev/null'
check "it started (no rollback)" 'wait_swaps && [[ $(version "$REN") == 2.7.1 ]] && [[ -n $(launcher_pid "$REN") ]]'
quit_app "$REN"; logtail

log "the installed OmacVM and the shared settings untouched"
check "fingerprint unchanged" '[[ $(fingerprint) == "$FP_BEFORE" ]]'

echo; echo "$pass passed, $fail failed (log: $UPD/update.log, server: $WORK/server.log)"
(( fail == 0 ))
