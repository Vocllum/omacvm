#!/bin/bash
# Install the guest side of omarchy-notch-bar. Run inside the Omarchy VM as the
# desktop user (not root), from a checkout of this repository.
#
#   ./guest/install.sh
#
# What it does (all under your home directory, nothing in /usr):
#   1. builds notchcast and installs it to ~/.local/bin
#   2. clones Omarchy's bar into ~/.config/omarchy/plugins/$USER.bar (Omarchy's
#      supported way to customise the bar) and applies the notch patch to it
#   3. installs ~/.config/hypr/notchbar.lua (hidden NOTCH output) and loads it
#      from ~/.config/hypr/hyprland.lua
#   4. installs and starts the systemd user service notchcast.service
# Undo with ./guest/uninstall.sh.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin=$HOME/.local/bin
plugins=$HOME/.config/omarchy/plugins
hypr=$HOME/.config/hypr
units=$HOME/.config/systemd/user
clone=$plugins/$USER.bar

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as your desktop user, not root"
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || die "run inside the Hyprland session (HYPRLAND_INSTANCE_SIGNATURE is unset)"
for c in gcc wayland-scanner python3 qs hyprctl omarchy-plugin-clone systemctl; do
  command -v "$c" >/dev/null || die "missing command: $c"
done
[[ -f /usr/include/lz4.h ]] || die "missing lz4 headers (pacman -S lz4)"
[[ -d /usr/share/wayland-protocols/staging/ext-image-copy-capture ]] || die "wayland-protocols too old (needs ext-image-copy-capture)"

say "building notchcast"
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
cp "$here/notchcast/notchcast.c" "$here/notchcast/build.sh" "$build/"
bash "$build/build.sh" "$build/out" >/dev/null
mkdir -p "$bin"
install -m 755 "$build/out/notchcast" "$bin/notchcast"

say "patching Omarchy's bar"
if [[ ! -f $clone/Bar.qml ]]; then
  omarchy-plugin-clone omarchy.bar >/dev/null
fi
[[ -f $clone/Bar.qml ]] || die "bar clone not found at $clone"
cp -n "$clone/Bar.qml" "$clone/Bar.qml.before-notchbar" 2>/dev/null || true
python3 "$here/bar/apply-patch.py" "$clone/Bar.qml"
if command -v omarchy-bar-use >/dev/null; then
  omarchy-bar-use "$USER.bar" >/dev/null 2>&1 || true
fi

say "installing Hyprland config"
mkdir -p "$hypr"
install -m 644 "$here/hypr/notchbar.lua" "$hypr/notchbar.lua"
if ! grep -q 'require("hypr.notchbar")' "$hypr/hyprland.lua"; then
  cp -p "$hypr/hyprland.lua" "$hypr/hyprland.lua.before-notchbar"
  printf '\n-- omarchy-notch-bar: hidden output for the macOS notch helper.\nrequire("hypr.notchbar")\n' >> "$hypr/hyprland.lua"
fi
hyprctl reload >/dev/null

say "installing the notchcast service"
mkdir -p "$units"
install -m 644 "$here/systemd/notchcast.service" "$units/notchcast.service"
systemctl --user daemon-reload
systemctl --user enable --now notchcast.service >/dev/null 2>&1
systemctl --user restart notchcast.service

sleep 2
if systemctl --user is-active --quiet notchcast.service; then
  say "done: notchcast is running (journalctl --user -u notchcast -f)"
else
  die "notchcast.service did not start; see journalctl --user -u notchcast"
fi
