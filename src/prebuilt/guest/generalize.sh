#!/bin/bash
# Turn a freshly built OmacVM VM into a prebuilt image. Runs as root in the
# VM (make-image.sh copies this folder to /root/omacvm-prebuilt):
#   generalize.sh --user PLACEHOLDER --type parallels|utm|fusion --audit-b64 LIST
# --audit-b64: base64 of strings (one per line) that must not be anywhere in
# the image: the build Mac's user, names, keys, token. A hit stops here.
# Ends with the VM powering off.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
U=""; TYPE=""; AUDIT=""
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --type) TYPE=$2; shift 2 ;;
    --audit-b64) AUDIT=$2; shift 2 ;;
    *) echo "generalize.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
[[ $(id -u "$U" 2>/dev/null) == 1000 ]] || { echo "generalize.sh: $U is not user 1000" >&2; exit 1; }
H=$(getent passwd "$U" | cut -d: -f6)
P=/var/lib/omacvm/prebuilt

[[ -d /usr/lib/parallels-tools || -e /etc/init.d/prltoolsd || -e /usr/lib/systemd/system/prltoolsd.service ]] &&
  { echo "generalize.sh: Parallels Tools are installed; an image must not contain them" >&2; exit 1; }

log "stopping $U's session"
loginctl terminate-user "$U" 2>/dev/null || true
for _ in $(seq 10); do pgrep -u "$U" >/dev/null || break; sleep 1; done
pkill -9 -u "$U" 2>/dev/null || true
systemctl stop "user@1000.service" 2>/dev/null || true

log "snapshots (snapper) and their contents"
if command -v snapper >/dev/null; then
  for c in $(snapper --csvout list-configs 2>/dev/null | tail -n +2 | cut -d, -f1); do
    ids=$(snapper -c "$c" --csvout list --columns number 2>/dev/null | tail -n +2 | grep -vx 0 || true)
    [[ -n $ids ]] && snapper -c "$c" delete $ids 2>/dev/null || true
  done
fi

log "home of $U -> $P/home (copied to the real user's home at first boot)"
mkdir -p "$P"
id -nG "$U" | tr ' ' '\n' | grep -vx "$U" | paste -sd, - > "$P/groups"
rm -rf "$P/home"
cp -a --reflink=auto "$H" "$P/home"
T=$P/home
rm -rf "$T/.cache" "$T/.ssh" "$T/.gnupg" "$T/.local/share/keyrings" "$T/.config/omacvm-bridge" \
  "$T/.local/share/recently-used.xbel" "$T/.bash_history" "$T/.python_history" "$T/.lesshst" \
  "$T/.local/share/fish/fish_history" "$T/.zsh_history" "$T/.wget-hsts" "$T/.viminfo" \
  "$T/.omacvm-install.log" "$T/.local/state/wireplumber" "$T/.local/share/Trash"
find "$T" -name '*.log' -path '*/.local/*' -delete 2>/dev/null || true
userdel "$U"
getent group "$U" >/dev/null && groupdel "$U"
rm -rf "$H" "/var/spool/mail/$U" "/var/lib/systemd/linger/$U" "/var/lib/AccountsService/users/$U" \
  /var/lib/sddm/state.conf /etc/sddm.conf.d/20-omacvm-autologin.conf
sed -i "s/^OMACVM_USER=.*/OMACVM_USER=$U/" /etc/omacvm/env 2>/dev/null || true

log "root's key, SSH host keys, machine id, network secrets"
rm -rf /root/.ssh /root/.cache /root/.bash_history /root/.lesshst /root/.viminfo /root/omacvm.env /root/omacvm.pub
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/NetworkManager/system-connections/* /var/lib/NetworkManager/* 2>/dev/null || true
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret
rm -f /etc/sudoers.d/zz-omacvm-install
rm -rf /var/lib/systemd/coredump/* /var/tmp/* /tmp/* 2>/dev/null || true

log "logs and caches"
journalctl --rotate >/dev/null 2>&1 || true
systemctl stop systemd-journald 2>/dev/null || true
rm -rf /var/log/journal/* /var/log/omacvm-omarchy-install.log /var/log/*.old /var/log/*.gz
for f in /var/log/*.log /var/log/btmp /var/log/wtmp /var/log/lastlog; do [[ -f $f ]] && : > "$f"; done
yes | pacman -Scc >/dev/null 2>&1 || true
rm -rf /var/cache/omacvm /var/cache/pacman/pkg/*

log "first-boot service"
install -Dm755 "$here/omacvm-firstboot" /usr/local/lib/omacvm/omacvm-firstboot
install -Dm644 "$here/omacvm-firstboot.service" /etc/systemd/system/omacvm-firstboot.service
systemctl enable omacvm-firstboot.service >/dev/null 2>&1
printf 'OMACVM_PREBUILT_TYPE=%s\nOMACVM_PREBUILT_USER=%s\nOMACVM_PREBUILT_DATE=%s\n' "$TYPE" "$U" "$(date -u +%F)" > "$P/image"
touch "$P/pending"

log "checking for personal data"
L=$(mktemp)
base64 -d <<<"$AUDIT" | awk 'length($0) >= 4' > "$L"
roots=(/etc /root /home /var /opt /srv /usr/local /boot)
[[ -d /.snapshots ]] && roots+=(/.snapshots)
if [[ -s $L ]] && hits=$(grep -rIlF -f "$L" "${roots[@]}" 2>/dev/null); then
  echo "$hits" | head -40 >&2
  echo "generalize.sh: the files above contain the build Mac's user, names, keys or token" >&2
  exit 1
fi
rm -f "$L"
echo "files naming the placeholder user (expected: the home template and OmacVM's own):"
grep -rIlF "$U" /etc /root /var /opt /srv /usr/local /boot 2>/dev/null | grep -v "^$P/home/" | head -20 || true

log "zeroing free space, so the disk compacts"
for d in / /boot; do
  z=$d/omacvm-zero.fill; z=${z//\/\//\/}
  rm -f "$z"; touch "$z"; chattr +C "$z" 2>/dev/null || true   # no copy-on-write = no compression on btrfs
  dd if=/dev/zero of="$z" bs=16M status=none 2>/dev/null || true
  sync; rm -f "$z"
done
sync
fstrim -av 2>/dev/null || true
rm -rf /root/omacvm-prebuilt
log "image ready, powering off"
systemd-run --on-active=3 --quiet systemctl poweroff
