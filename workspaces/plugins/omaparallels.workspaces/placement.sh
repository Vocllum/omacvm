#!/bin/bash
# Put omaparallels.workspaces where Omarchy's workspaces widget sits.
# Idempotent: does nothing once the widget is on the bar.
set -euo pipefail
id=omaparallels.workspaces
config=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json
in_bar() {
  [[ -f $config ]] && jq -e --arg id "$1" '[.bar.layout[]?[]?.id] | index($id) != null' "$config" >/dev/null
}
in_bar "$id" && exit 0
omarchy-shell -q shell rescanPlugins
if in_bar omarchy.workspaces; then
  omarchy plugin enable "$id"            # clonedFrom: takes over the stock widget's slot
else
  omarchy plugin enable "$id" --section left
fi
