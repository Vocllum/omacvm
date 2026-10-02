#!/bin/bash
# OmacVM, Mac side: Bridge (Wi-Fi, audio, media keys, display, wallpaper),
# Gestures (trackpad, scroll momentum, Cmd as Super on UTM), clipboard (VM -> Mac).
# Idempotent; `omacvm apply` runs it with what the VM's features need.
#   src/mac/install.sh [--no-bridge] [--skip-gestures | --no-gestures] [--force] [--quiet]
# --no-bridge leaves OmacVM Bridge out (one already installed stays, other VMs
# may use it). --skip-gestures leaves OmacVM Gestures out (likewise).
# --no-gestures installs it keys-only for every VM: macOS keeps its trackpad
# gestures, and on UTM Cmd still reaches Omarchy as Super. (Without it, each
# VM chooses for itself: gestures and scroll momentum are VM features.)
# An app whose sources and options did not change since it was installed is
# left as it is (--force rebuilds it); --quiet only reports what changed.
# macOS asks for Location Services (Bridge) and Accessibility + Input Monitoring
# (Bridge, Gestures) the first time.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
BRIDGE=1; GESTURES=1; FORCE=0; QUIET=0
for a in "$@"; do
  case $a in
    --no-bridge) BRIDGE=0 ;;
    --no-gestures) GESTURES=0 ;;
    --skip-gestures) GESTURES=-1 ;;
    --force) FORCE=1 ;;
    --quiet) QUIET=1 ;;
    *) echo "src/mac/install.sh: unknown option $a" >&2; exit 2 ;;
  esac
done
STAMPS=~/Library/Application\ Support/omacvm/installed
mkdir -p "$HOME/.local/share/omacvm/clip" "$STAMPS"

# install_app NAME LAUNCHD_LABEL DIR [ARGS...]: DIR/install.sh unless the same
# sources and options are already installed and running.
install_app() {
  local name=$1 label=$2 dir=$3; shift 3
  local sum
  # Paths relative to src/, so another copy of the same OmacVM matches too.
  sum=$( { cd "$R" && find "$dir" icon lib/sign.sh -type f -not -path '*/build/*' -not -name .DS_Store -print0 |
           sort -z | xargs -0 shasum; echo "args: $*"; } | shasum | cut -c1-16)
  if (( ! FORCE )) && [[ $(cat "$STAMPS/$name" 2>/dev/null) == "$sum" ]] &&
     launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    (( QUIET )) || echo "$name: up to date"
    return 0
  fi
  printf '\033[1;32m==>\033[0m \033[1m%s on the Mac\033[0m\n' "$name"
  "$R/$dir/install.sh" "$@"
  echo "$sum" > "$STAMPS/$name"
  INSTALLED+=("$name")
}
INSTALLED=()
(( BRIDGE )) && install_app "OmacVM Bridge" org.omacvm.bridge bridge/mac
case $GESTURES in
  1) install_app "OmacVM Gestures" org.omacvm.gestures gestures/mac ;;
  0) install_app "OmacVM Gestures" org.omacvm.gestures gestures/mac --keys-only ;;
esac
install_app "OmacVM clipboard" org.omacvm.clip-in clipboard/mac
# The permissions macOS asks for now, once per app (they stay with later updates).
if [[ " ${INSTALLED[*]:-} " == *" OmacVM Gestures "* || " ${INSTALLED[*]:-} " == *" OmacVM Bridge "* ]]; then
  printf '\n  \033[1mmacOS asks for permissions now (once): please allow them.\033[0m\n'
  printf '  In System Settings > Privacy & Security, turn on:\n'
  [[ " ${INSTALLED[*]} " == *" OmacVM Gestures "* ]] &&
    printf '    * Accessibility and Input Monitoring: OmacVM Gestures (trackpad gestures, scroll momentum, Cmd keys)\n'
  [[ " ${INSTALLED[*]} " == *" OmacVM Bridge "* ]] &&
    printf '    * Accessibility: OmacVM Bridge (media keys); Location Services: OmacVM Bridge (Wi-Fi names)\n'
  printf '  Until then those features wait; the build goes on either way.\n\n'
fi
(( QUIET )) || echo "OmacVM Mac side installed"
