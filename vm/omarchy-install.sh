#!/bin/bash
# Install Omarchy from omarchy-mac on the freshly booted base system. Runs as
# root in the VM (build.sh copies it with /root/omacvm.env); the
# installer itself runs as the desktop user, unattended, with a temporary
# password-less sudo that is removed again at the end.
#   OMARCHY_MAC_CHANNEL  rc (default) or stable, passed to `install.sh --channel`
set -euo pipefail
source /root/omacvm.env
U=$OMA_USER; H=$(getent passwd "$U" | cut -d: -f6)
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

printf 'Defaults:%s verifypw=any\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$U" "$U" > /etc/sudoers.d/zz-omacvm-install
chmod 440 /etc/sudoers.d/zz-omacvm-install
trap 'rm -f /etc/sudoers.d/zz-omacvm-install' EXIT

log "system update"
pacman -Syu --noconfirm >/dev/null 2>&1 || true

log "omarchy-mac (channel ${OMARCHY_MAC_CHANNEL:-rc})"
cat > "$H/.omacvm-install.sh" <<EOF
#!/bin/bash
set -o pipefail
cd ~
[[ -d ~/.local/share/omarchy/.git ]] || git clone https://github.com/omacom/omarchy-mac.git ~/.local/share/omarchy
cd ~/.local/share/omarchy
echo "omarchy-mac \$(cat version) \$(git rev-parse --short HEAD)"
export OMARCHY_USER_NAME="$OMA_FULLNAME"
export OMARCHY_USER_EMAIL="${OMA_EMAIL:-}"
bash install.sh --channel ${OMARCHY_MAC_CHANNEL:-rc} < /dev/null
echo "INSTALL-EXIT=\$?"
EOF
chown "$U:$U" "$H/.omacvm-install.sh"; chmod +x "$H/.omacvm-install.sh"
L=/var/log/omacvm-omarchy-install.log
systemctl reset-failed omacvm-omarchy-install 2>/dev/null || true
systemd-run --uid="$U" --gid="$U" --unit=omacvm-omarchy-install -p WorkingDirectory="$H" \
  -E HOME="$H" -E USER="$U" -E LANG=en_US.UTF-8 -E TERM=xterm-256color \
  /bin/bash -c "$H/.omacvm-install.sh > '$H/.omacvm-install.log' 2>&1"
while systemctl is-active -q omacvm-omarchy-install; do
  sleep 20
  sed 's/\x1b\[[0-9;]*m//g' "$H/.omacvm-install.log" | grep -E '^==>' | tail -1 || true
done
mv "$H/.omacvm-install.log" "$L"; rm -f "$H/.omacvm-install.sh"
grep -q 'INSTALL-EXIT=0' "$L" || { tail -30 "$L"; echo "omarchy-mac install failed, full log: $L" >&2; exit 1; }
# Omarchy turns on its firewall (deny inbound). This SSH session survives, the
# next ones from the Mac would not: let the Mac's Parallels network reach SSH.
ufw allow from 10.211.55.0/24 to any port 22 proto tcp comment "omacvm: ssh from the Mac" >/dev/null
log "Omarchy installed ($(cat "$H/.local/share/omarchy/version" 2>/dev/null))"
