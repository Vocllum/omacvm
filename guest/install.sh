#!/bin/bash
# Omaparallels, guest side: everything that makes Omarchy feel native in
# Parallels. Run as root inside the VM from a copy of this repository
# (build.sh puts it in /usr/local/share/omaparallels):
#   guest/install.sh --user NAME --keyboard "LAYOUT [VARIANT]" [--no-thp-kernel] [--autologin]
# Idempotent: run it again after an update of this repository.
# Needs Parallels Tools (build.sh installs them first) and, for the bridge, the
# token from the Mac in ~/.config/omaparallels-bridge/token.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
U=""; KB="us"; THP=1; AUTOLOGIN=0
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --keyboard) KB=$2; shift 2 ;;
    --no-thp-kernel) THP=0; shift ;;
    --autologin) AUTOLOGIN=1; shift ;;
    *) echo "usage: guest/install.sh --user NAME --keyboard \"LAYOUT [VARIANT]\" [--no-thp-kernel] [--autologin]" >&2; exit 2 ;;
  esac
done
[[ -n $U ]] && id "$U" >/dev/null || { echo "guest/install.sh: --user must be the desktop user" >&2; exit 2; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
read -r layout variant <<<"$KB"

log "system: SSH from the Mac, bootable snapshots, DNS fallback"
# Omarchy's firewall denies everything inbound; the Mac (Parallels' shared
# network) may still reach SSH.
ufw allow from 10.211.55.0/24 to any port 22 proto tcp comment "omaparallels: ssh from the Mac" >/dev/null 2>&1 || true
# Snapshots (snapper, set up by omarchy-mac) appear in the GRUB menu.
pacman -S --needed --noconfirm grub-btrfs inotify-tools jq >/dev/null 2>&1
# Read-only snapshots picked in GRUB boot with a temporary writable overlay
# (Omarchy does this with Limine on x86; omarchy-mac uses GRUB).
cat > /etc/mkinitcpio.conf.d/zz-omaparallels.conf <<'EOF'
[[ " ${HOOKS[*]} " == *" grub-btrfs-overlayfs "* ]] || HOOKS+=(grub-btrfs-overlayfs)
EOF
systemctl enable --now grub-btrfsd >/dev/null 2>&1 || true
install -Dm644 /dev/stdin /etc/systemd/resolved.conf.d/10-omaparallels.conf <<'EOF'
[Resolve]
FallbackDNS=1.1.1.1 9.9.9.9 2606:4700:4700::1111 2620:fe::fe
EOF
systemctl try-restart systemd-resolved 2>/dev/null || true
if (( AUTOLOGIN )); then
  # The Mac is FileVault-encrypted and locked already; hyprlock still locks
  # the session after idle.
  install -Dm644 /dev/stdin /etc/sddm.conf.d/20-omaparallels-autologin.conf <<EOF
[Autologin]
User=$U
Session=hyprland-uwsm
Relogin=false
EOF
fi

log "display";    "$R/display/guest/install.sh" "$U"
log "clipboard";  "$R/clipboard/guest/install.sh" "$U"
log "memory";     "$R/memory/guest/install.sh"
log "keyboard";   "$R/keyboard/guest/install.sh" "$U" "$layout" "${variant:-}"
log "gestures";   "$R/gestures/guest/install.sh" "$U"
log "workspaces"; "$R/workspaces/guest/install.sh" "$U"
log "lock screen"; "$R/lock/guest/install.sh" "$U"
log "bridge";     "$R/bridge/guest/install.sh" "$U"
if (( THP )); then
  log "THP kernel (about 10 minutes)"
  "$R/kernel/build-thp-kernel.sh" "$U"
fi
mkinitcpio -P >/dev/null 2>&1 || true
grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
log "Omaparallels guest side installed for $U (reboot to apply everything)"
