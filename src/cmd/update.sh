#!/bin/bash
# omacvm update [--vm NAME] [--no-pull]: OmacVM up to date everywhere. This
# checkout (git pull, when it is a clean clone), the Mac side that is
# installed, Omanotch on the Mac (when its clone is clean), then OmacVM in
# every running VM that has it (or only --vm NAME; a stopped one is started).
# Each VM keeps its feature choices. Stopped VMs are listed, not started.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
VM=""; PULL=1; ARGS=("$@")
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --no-pull) PULL=0; shift ;;
    -h|--help) sed -n '2,6s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm update: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
export OMA_KEY=~/.ssh/omacvm

# ---------- this checkout ----------
if (( PULL )) && git -C "$R" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  if [[ -n $(git -C "$R" status --porcelain --untracked-files=no) ]]; then
    info "this checkout has local changes: not pulling ($R)"
  else
    before=$(git -C "$R" rev-parse HEAD)
    log "OmacVM: git pull"
    git -C "$R" pull -q --ff-only || die "git pull failed in $R"
    if [[ $(git -C "$R" rev-parse HEAD) != "$before" ]]; then
      info "$(cat "$R/src/VERSION"): $(git -C "$R" log --oneline "$before..HEAD" | wc -l | tr -d ' ') new commits"
      exec "$R/omacvm" update --no-pull ${ARGS[@]+"${ARGS[@]}"}
    fi
    info "already up to date ($(cat "$R/src/VERSION"))"
  fi
fi

# ---------- the Mac ----------
args=()
launchctl print "gui/$(id -u)/org.omacvm.bridge" >/dev/null 2>&1 || args+=(--no-bridge)
if launchctl print "gui/$(id -u)/org.omacvm.gestures" 2>/dev/null | grep -q -- --keys-only; then args+=(--no-gestures)
elif ! launchctl print "gui/$(id -u)/org.omacvm.gestures" >/dev/null 2>&1; then args+=(--skip-gestures); fi
log "OmacVM on the Mac"
"$R/src/mac/install.sh" ${args[@]+"${args[@]}"}
if [[ -d $HOME/omanotch/.git && -d $HOME/Applications/Omanotch.app ]]; then
  if [[ -n $(git -C "$HOME/omanotch" status --porcelain --untracked-files=no) ]]; then
    info "Omanotch: ~/omanotch has local changes, left as it is"
  else
    before=$(git -C "$HOME/omanotch" rev-parse HEAD)
    git -C "$HOME/omanotch" pull -q --ff-only 2>/dev/null || info "Omanotch: git pull failed, left as it is"
    if [[ $(git -C "$HOME/omanotch" rev-parse HEAD) != "$before" ]]; then
      log "Omanotch on the Mac"
      "$HOME/omanotch/mac/install.sh"
    fi
  fi
fi

# ---------- the VMs ----------
if [[ -n $VM ]]; then
  "$R/src/cmd/apply.sh" --vm "$VM" --no-mac
  exit
fi
done_any=0; stopped=()
while IFS=$'\t' read -r name type state; do
  [[ -n $name ]] || continue
  if [[ $state != running ]]; then stopped+=("$name"); continue; fi
  ip=$(vm_find_ip "$name" "$type" 3 2>/dev/null) || continue
  v=$(vm_probe "$ip" | sed -n 's/^OMACVM_VERSION=//p')
  [[ -n $v ]] || continue
  log "VM '$name' (OmacVM $v)"
  "$R/src/cmd/apply.sh" --vm "$name" --vm-type "$type" --ip "$ip" --no-mac < /dev/null
  done_any=1
done < <(vms_list)
(( done_any )) || info "no running VM with OmacVM"
if (( ${#stopped[@]} )); then
  info "not running, so not updated: $(printf '%s, ' "${stopped[@]}" | sed 's/, $//')"
  info "start one and run: omacvm update --vm NAME"
fi
