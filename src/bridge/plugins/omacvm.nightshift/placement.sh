#!/bin/bash
# Put omacvm.nightshift on the bar beside the Mac's other controls: after the
# Mac audio widget, else before Omarchy's display widget or the power menu.
# Idempotent: does nothing once the widget is on the bar.
set -euo pipefail

id=omacvm.nightshift
config=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json

in_bar() {
  [[ -f $config ]] && jq -e --arg id "$1" '[.bar.layout[]?[]?.id] | index($id) != null' "$config" >/dev/null
}

in_bar "$id" && exit 0

# A freshly copied plugin is unknown to the running shell until a rescan.
omarchy-shell -q shell rescanPlugins

if in_bar omacvm.audio; then
  omarchy plugin enable "$id" --after omacvm.audio
elif in_bar omarchy.monitor; then
  omarchy plugin enable "$id" --before omarchy.monitor
elif in_bar omarchy.power; then
  omarchy plugin enable "$id" --before omarchy.power
else
  omarchy plugin enable "$id" --section right
fi
