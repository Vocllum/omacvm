#!/bin/bash
# Install one Omarchy shell plugin folder for the desktop user. Run as root:
#   lib/install-plugin.sh <desktop-user> <plugin-folder>
# Copies it to ~/.config/omarchy/plugins/<id>/ and validates it. Enabling needs
# the running Omarchy shell: if it runs, the plugin is enabled now; otherwise
# (fresh build, nobody logged in yet) it is queued and omaparallels-plugins
# enables it at the next login. A plugin may ship placement.sh (run as the
# user) to choose its spot in the bar.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
U=${1:?usage: install-plugin.sh <desktop-user> <plugin-folder>}; dir=${2%/}
H=$(getent passwd "$U" | cut -d: -f6)
# Omarchy's commands need its environment (OMARCHY_PATH, ...), which a root
# shell does not have: load Omarchy's own bootstrap first.
as_user() {
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}

id=$(jq -r .id "$dir/manifest.json")
dest=$H/.config/omarchy/plugins/$id
install -d -o "$U" -g "$U" "$H/.config/omarchy/plugins"
rm -rf "$dest"
cp -r "$dir" "$dest"
chown -R "$U:$U" "$dest"
as_user omarchy plugin validate "$dest" >/dev/null

install -m755 "$here/omaparallels-plugins" /usr/local/bin/omaparallels-plugins
install -m644 "$here/omaparallels-plugins.service" /etc/systemd/user/omaparallels-plugins.service
Q=$H/.local/state/omaparallels/pending-plugins
install -d -o "$U" -g "$U" "$(dirname "$Q")"
grep -qx "$id" "$Q" 2>/dev/null || echo "$id" >> "$Q"
chown "$U:$U" "$Q"
if as_user omarchy-shell shell ping >/dev/null 2>&1; then
  as_user /usr/local/bin/omaparallels-plugins
else
  systemctl --user -M "$U@" enable omaparallels-plugins.service >/dev/null 2>&1 ||
    { install -d -o "$U" -g "$U" "$H/.config/systemd/user/graphical-session.target.wants"
      ln -sf /etc/systemd/user/omaparallels-plugins.service "$H/.config/systemd/user/graphical-session.target.wants/"; }
  echo "plugin $id installed (enabled at the next login)"
fi
