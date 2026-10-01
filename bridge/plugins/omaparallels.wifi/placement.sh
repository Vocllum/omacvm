#!/bin/bash
# Put omaparallels.wifi on the bar where Omarchy's network widget sits.
# Idempotent: does nothing once the widget is on the bar. Works with the stock
# bar and with custom bars that use the same shell.json layout.
set -euo pipefail

id=omaparallels.wifi
config=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json

in_bar() {
  [[ -f $config ]] && jq -e --arg id "$1" '[.bar.layout[]?[]?.id] | index($id) != null' "$config" >/dev/null
}

in_bar "$id" && exit 0

# A freshly copied plugin is unknown to the running shell until a rescan.
omarchy-shell -q shell rescanPlugins

if in_bar omarchy.network; then
  # clonedFrom omarchy.network: enabling takes over the stock widget's slot.
  omarchy plugin enable "$id"
elif in_bar omaparallels.audio; then
  omarchy plugin enable "$id" --before omaparallels.audio
elif in_bar omarchy.audio; then
  omarchy plugin enable "$id" --before omarchy.audio
elif in_bar omarchy.power; then
  omarchy plugin enable "$id" --before omarchy.power
else
  omarchy plugin enable "$id" --section right
fi
