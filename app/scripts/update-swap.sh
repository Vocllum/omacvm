#!/bin/bash
# OmacVM.app's self-update, the part that runs while the app is closed
# (docs/adr/0033). The app starts it from a copy outside its bundle:
#   update-swap.sh install  APP NEW HOME PID TOKEN   NEW in place of APP; APP kept as the previous version
#   update-swap.sh rollback APP -   HOME PID TOKEN   the previous version back in place of APP
# It waits for the app (PID) to quit and never swaps while a process runs
# from APP (a VM's QEMU). Then it starts the swapped-in app with
# --update-check TOKEN; that app writes HOME/launch-TOKEN ("ok" once its
# QEMU starts). No "ok" within a minute: the app that was there before goes
# back. HOME/result tells the app that runs at the end what happened.
set -uo pipefail
MODE=${1:-} APP=${2:-} NEW=${3:-} HOME_DIR=${4:-} OLD_PID=${5:-} TOKEN=${6:-}
[[ $MODE == install || $MODE == rollback ]] && [[ $APP == /*.app && -d $APP && -d $HOME_DIR ]] &&
  [[ $OLD_PID =~ ^[0-9]+$ && $TOKEN =~ ^[0-9a-f]{32}$ ]] ||
  { echo "usage: update-swap.sh install|rollback APP NEW|- HOME PID TOKEN" >&2; exit 2; }
BASE=$(basename "$APP")
PREV=$HOME_DIR/previous/$BASE
INCOMING=$HOME_DIR/incoming/$BASE
FAILED=$HOME_DIR/failed
MARKER=$HOME_DIR/launch-$TOKEN
WAIT=${OMACVM_UPDATE_WAIT:-60}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

log() { printf '%s swap: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
result() { printf '%s\n' "$*" > "$HOME_DIR/result"; log "result: $*"; }
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo unknown; }
# Processes started from inside the bundle (its QEMU, the launcher).
running_from() { ps -axww -o pid=,args= | grep -F -- "$1/Contents/" | grep -v -e grep -e update-swap.sh | awk '{ print $1 }'; }

# The test hooks travel with the app across the restart.
OPEN_ENV=()
for v in OMACVM_APPCAST_URL OMACVM_APPCAST_KEY OMACVM_SETTINGS_DIR OMACVM_COCOA_HIDDEN; do
  [[ -n ${!v:-} ]] && OPEN_ENV+=(--env "$v=${!v}")
done
launch() { open -n ${OPEN_ENV[@]+"${OPEN_ENV[@]}"} "$APP" --args "$@"; }

# Nothing swapped: say why and open the app that is there.
abort() {
  [[ $MODE == rollback && -d $INCOMING && ! -e $PREV ]] && mkdir -p "$HOME_DIR/previous" && mv "$INCOMING" "$PREV"
  result "aborted $*"
  launch
  exit 1
}

log "$MODE $APP (now $(version "$APP"))"
for ((i = 0; i < 600; i++)); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$OLD_PID" 2>/dev/null; then
  result "aborted the app did not quit"
  exit 1
fi
[[ -z $(running_from "$APP") ]] || abort "a VM runs from $BASE: the update waits until it is shut down"

if [[ $MODE == rollback ]]; then
  [[ -d $PREV ]] || abort "there is no previous version"
  rm -rf "$HOME_DIR/incoming"; mkdir -p "$HOME_DIR/incoming"
  mv "$PREV" "$INCOMING" || abort "could not take out the previous version"
  NEW=$INCOMING
fi
[[ -d $NEW ]] || abort "the new app is missing"
OLD_V=$(version "$APP") NEW_V=$(version "$NEW")

# Old aside, new in: renames on one volume, each checked. The version kept
# from before stays in previous.old until the new one has started.
rm -rf "$HOME_DIR/previous.old"
[[ ! -e $HOME_DIR/previous ]] || mv "$HOME_DIR/previous" "$HOME_DIR/previous.old" || abort "could not move the kept version aside"
keep_old() { rm -rf "$HOME_DIR/previous"; [[ ! -e $HOME_DIR/previous.old ]] || mv "$HOME_DIR/previous.old" "$HOME_DIR/previous"; }
mkdir -p "$HOME_DIR/previous"
if ! mv "$APP" "$PREV"; then keep_old; abort "could not move $BASE aside"; fi
if ! mv "$NEW" "$APP"; then
  mv "$PREV" "$APP" || log "the old app is at $PREV"
  keep_old
  abort "could not put $NEW_V in place"
fi
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
log "swapped $OLD_V -> $NEW_V, starting it"

rm -f "$MARKER"
why="no answer within ${WAIT} s"
if launch --update-check "$TOKEN"; then
  for ((i = 0; i < WAIT * 4; i++)); do
    [[ -s $MARKER ]] && break
    sleep 0.25
  done
  answer=$(head -1 "$MARKER" 2>/dev/null)
  rm -f "$MARKER"
  if [[ $answer == ok ]]; then
    if [[ $MODE == install ]]; then result "installed $OLD_V $NEW_V"; else result "went-back $OLD_V"; fi
    rm -rf "$HOME_DIR/incoming" "$FAILED" "$HOME_DIR/previous.old"
    exit 0
  fi
  [[ -n $answer ]] && why=${answer#fail: }
else
  why="it did not open"
fi

# It did not start: stop what runs of it and put the old app back.
log "$NEW_V did not start ($why): putting $OLD_V back"
pids=$(running_from "$APP")
if [[ -n $pids ]]; then
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null; sleep 2
  pids=$(running_from "$APP")
  # shellcheck disable=SC2086
  [[ -z $pids ]] || kill -9 $pids 2>/dev/null
fi
rm -rf "$FAILED"; mkdir -p "$FAILED"
if ! mv "$APP" "$FAILED/$BASE" || ! mv "$PREV" "$APP"; then
  result "rolled-back $NEW_V $why; putting $OLD_V back failed too: it is at $PREV"
  exit 1
fi
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
keep_old
rm -rf "$FAILED" "$HOME_DIR/incoming"
result "rolled-back $NEW_V $why"
launch
exit 1
