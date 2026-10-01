#!/bin/bash
# Copy the bearer token into the VM and install the guest side (guest/install.sh).
#   ./push-guest.sh [root@<vm-ip>] [desktop-user]
# Token ends up at /home/<user>/.config/omaparallels-bridge/token (0600, owned by the user).
# Extra ssh options: SSH_OPTS="-i ~/.ssh/omarchy-parallels" ./push-guest.sh
set -euo pipefail
cd "$(dirname "$0")"
VM=${1:-root@$(grep -o '10\.211\.55\.[0-9]*' /Library/Preferences/Parallels/parallels_dhcp_leases | tail -1)}
U=${2:-$(id -un)}
TOKEN=~/Library/Application\ Support/omaparallels-bridge/token
[[ -f $TOKEN ]] || { echo "no token yet: run ./install.sh first" >&2; exit 1; }
# shellcheck disable=SC2086
ssh ${SSH_OPTS:-} "$VM" "set -e
  install -d -m700 -o '$U' -g '$U' /home/'$U'/.config/omaparallels-bridge
  cat > /home/'$U'/.config/omaparallels-bridge/token
  chown '$U:$U' /home/'$U'/.config/omaparallels-bridge/token; chmod 600 /home/'$U'/.config/omaparallels-bridge/token" < "$TOKEN"
# The guest side: CLI, OSD follower, Omarchy plugins (guest/install.sh does the work).
# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar --no-xattrs -C ../guest -czf - . | ssh ${SSH_OPTS:-} "$VM" "set -e
  rm -rf /tmp/omaparallels-bridge-guest; mkdir /tmp/omaparallels-bridge-guest; tar -C /tmp/omaparallels-bridge-guest -xzf -
  /tmp/omaparallels-bridge-guest/install.sh '$U'; rm -rf /tmp/omaparallels-bridge-guest"
echo "token -> $VM:/home/$U/.config/omaparallels-bridge/token"
