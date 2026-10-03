#!/bin/bash
# Google Chrome for Linux ARM in an Omarchy VM, for the browser benchmarks
# (Arch's Chromium is slower than Chrome, so it would not compare with the Mac).
# Arch Linux ARM has no Chrome package: this unpacks Google's own .deb to
# /opt/google/chrome. Run as root in the VM. Again to update.
set -euo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
curl -fsSL -o "$d/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb
cd "$d"
bsdtar -xf chrome.deb
rm -rf /opt/google/chrome
tar -xf data.tar.* -C / ./opt/google/chrome
ln -sf /opt/google/chrome/google-chrome /usr/local/bin/google-chrome-stable
missing=$(ldd /opt/google/chrome/chrome | awk '/not found/ { print $1 }')
[[ -z $missing ]] || { echo "install-chrome: missing libraries: $missing" >&2; exit 1; }
/usr/local/bin/google-chrome-stable --version
