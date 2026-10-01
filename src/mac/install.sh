#!/bin/bash
# OmacVM, Mac side: Bridge (Wi-Fi, audio, media keys, display, wallpaper),
# Gestures, clipboard (VM -> Mac). Idempotent; build.sh runs it.
#   src/mac/install.sh [--no-bridge] [--no-gestures | --skip-gestures]
# --no-bridge leaves OmacVM Bridge out (one already installed stays, other VMs
# may use it). --no-gestures installs OmacVM Gestures keys-only: macOS keeps
# its trackpad gestures, and on UTM Cmd still reaches Omarchy as Super.
# --skip-gestures leaves it out (Parallels with gestures off needs nothing).
# macOS asks for Location Services (Bridge) and Accessibility + Input Monitoring
# (Bridge, Gestures) the first time.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
BRIDGE=1; GESTURES=1
for a in "$@"; do
  case $a in
    --no-bridge) BRIDGE=0 ;;
    --no-gestures) GESTURES=0 ;;
    --skip-gestures) GESTURES=-1 ;;
    *) echo "src/mac/install.sh: unknown option $a" >&2; exit 2 ;;
  esac
done
mkdir -p ~/.local/share/omacvm/clip
(( BRIDGE )) && "$R/bridge/mac/install.sh"
case $GESTURES in
  1) "$R/gestures/mac/install.sh" ;;
  0) "$R/gestures/mac/install.sh" --keys-only ;;
esac
"$R/clipboard/mac/install.sh"
echo "OmacVM Mac side installed"
