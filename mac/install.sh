#!/bin/bash
# OmacVM, Mac side: Bridge (Wi-Fi, audio, media keys, display), Gestures,
# clipboard (VM -> Mac) and the Omarchy lock screen. Idempotent; build.sh runs it.
# macOS asks for Location Services (Bridge) and Accessibility + Input Monitoring
# (Bridge, Gestures) the first time.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p ~/.local/share/omacvm/clip ~/.local/share/omacvm/theme
"$R/bridge/mac/install.sh"
"$R/gestures/mac/install.sh"
"$R/clipboard/mac/install.sh"
"$R/lock/mac/install.sh"
echo "OmacVM Mac side installed"
