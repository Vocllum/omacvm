#!/bin/bash
# Put omacvm.bluetooth on the bar where Omarchy's Bluetooth widget sits (in
# Omarchy's default bar: right before the network widget).
# Idempotent: does nothing once the widget is on the bar.
set -euo pipefail

id=omacvm.bluetooth
config=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json

in_bar() {
  [[ -f $config ]] && jq -e --arg id "$1" '[.bar.layout[]?[]?.id] | index($id) != null' "$config" >/dev/null
}

in_bar "$id" && exit 0

# A freshly copied plugin is unknown to the running shell until a rescan.
omarchy-shell -q shell rescanPlugins

if in_bar omarchy.bluetooth; then
  # clonedFrom omarchy.bluetooth: enabling takes over the stock widget's slot.
  omarchy plugin enable "$id"
elif in_bar omacvm.wifi; then
  omarchy plugin enable "$id" --before omacvm.wifi
elif in_bar omarchy.network; then
  omarchy plugin enable "$id" --before omarchy.network
elif in_bar omacvm.audio; then
  omarchy plugin enable "$id" --before omacvm.audio
elif in_bar omarchy.power; then
  omarchy plugin enable "$id" --before omarchy.power
else
  omarchy plugin enable "$id" --section right
fi
