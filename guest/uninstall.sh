#!/bin/bash
# Remove the guest side of omarchy-notch-bar. Run inside the Omarchy VM as the
# desktop user. The bar clone in ~/.config/omarchy/plugins/$USER.bar is kept
# (switch back with `omarchy bar use omarchy.bar`, then delete it if you like),
# unless you pass --remove-bar-clone.
set -euo pipefail

hypr=$HOME/.config/hypr
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

say "stopping notchcast"
systemctl --user disable --now notchcast.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/notchcast.service" "$HOME/.local/bin/notchcast"
systemctl --user daemon-reload

say "removing Hyprland config"
if [[ -f $hypr/hyprland.lua ]]; then
  sed -i '/-- omarchy-notch-bar: hidden output for the macOS notch helper./d; /require("hypr.notchbar")/d' "$hypr/hyprland.lua"
fi
rm -f "$hypr/notchbar.lua"
hyprctl output remove NOTCH >/dev/null 2>&1 || true
hyprctl eval 'hl.config({ cursor = { invisible = false } })' >/dev/null 2>&1 || true
hyprctl reload >/dev/null 2>&1 || true

say "restoring Omarchy's bar"
omarchy-shell -q notchbar setParked false || true
if [[ ${1:-} == --remove-bar-clone ]]; then
  if command -v omarchy-bar-use >/dev/null; then omarchy-bar-use omarchy.bar >/dev/null 2>&1 || true; fi
  rm -rf "$HOME/.config/omarchy/plugins/$USER.bar"
fi
say "done"
