#!/bin/bash
# Install one Omarchy shell plugin folder for the desktop user. Run as root:
#   lib/install-plugin.sh <desktop-user> <plugin-folder>
# Copies it to ~/.config/omarchy/plugins/<id>/, validates it, and enables it.
# A plugin may ship placement.sh (run as the user) to choose its spot in the
# bar; otherwise `omarchy plugin enable` puts it where its manifest says.
set -euo pipefail
U=${1:?usage: install-plugin.sh <desktop-user> <plugin-folder>}; dir=${2%/}
H=$(getent passwd "$U" | cut -d: -f6)
as_user() { sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" "$@"; }

id=$(jq -r .id "$dir/manifest.json")
dest=$H/.config/omarchy/plugins/$id
install -d -o "$U" -g "$U" "$H/.config/omarchy/plugins"
rm -rf "$dest"
cp -r "$dir" "$dest"
chown -R "$U:$U" "$dest"
as_user omarchy plugin validate "$dest" >/dev/null
as_user omarchy-shell -q shell rescanPlugins
if [[ -x $dest/placement.sh ]]; then
  (cd "$dest" && as_user ./placement.sh)
else
  as_user omarchy plugin enable "$id" >/dev/null
fi
echo "plugin $id installed"
