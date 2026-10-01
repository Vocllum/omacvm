#!/bin/bash
# OmacVM, guest side: everything that makes Omarchy feel native in a VM on a
# Mac, in Parallels or UTM. Run as root inside the VM from a copy of this
# repository (apply.sh puts it in /usr/local/share/omacvm):
#   guest/install.sh --user NAME --keyboard "LAYOUT [VARIANT]" [--vm-type parallels|utm]
#                    [--display WxH@Hz] [--no-thp-kernel] [--autologin]
# --vm-type defaults to what the hardware says (Parallels or QEMU = UTM);
# --display (UTM: the fixed mode, from display/mac-display.swift) is required on UTM.
# Idempotent: run it again after an update of this repository.
# Needs, for the bridge, the token from the Mac in ~/.config/omacvm-bridge/token.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
U=""; KB="us"; THP=1; AUTOLOGIN=0; TYPE=""; MODE=""
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --keyboard) KB=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --display) MODE=$2; shift 2 ;;
    --no-thp-kernel) THP=0; shift ;;
    --autologin) AUTOLOGIN=1; shift ;;
    *) sed -n '5,6s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $U ]] && id "$U" >/dev/null || { echo "guest/install.sh: --user must be the desktop user" >&2; exit 2; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
read -r layout variant <<<"$KB"

# Which VM, and where its Mac is: Parallels' Mac is 10.211.55.2 on its shared
# network; on UTM's shared network the Mac is the default gateway.
if [[ -z $TYPE ]]; then
  case $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) in
    Parallels*) TYPE=parallels ;;
    QEMU*) TYPE=utm ;;
    *) echo "guest/install.sh: unknown VM, pass --vm-type parallels|utm" >&2; exit 2 ;;
  esac
fi
case $TYPE in
  parallels) HOST=10.211.55.2 ;;
  utm) HOST=$(ip route show default | awk '{ print $3; exit }'); : "${HOST:=192.168.64.1}"
       [[ -n $MODE ]] || { echo "guest/install.sh: UTM needs --display WxH@Hz" >&2; exit 2; } ;;
  *) echo "guest/install.sh: --vm-type parallels or utm" >&2; exit 2 ;;
esac
printf 'OMACVM_VM_TYPE=%s\nOMACVM_HOST=%s\n' "$TYPE" "$HOST" | install -Dm644 /dev/stdin /etc/omacvm/env
log "$TYPE VM, the Mac is $HOST"

log "system: SSH from the Mac, bootable snapshots, DNS fallback"
# Omarchy's firewall denies everything inbound; the Mac (Parallels' shared
# network) may still reach SSH.
ufw allow from "${HOST%.*}.0/24" to any port 22 proto tcp comment "omacvm: ssh from the Mac" >/dev/null 2>&1 || true
pacman -S --needed --noconfirm jq >/dev/null 2>&1
if command -v grub-mkconfig >/dev/null; then
  # Snapshots (snapper, set up by omarchy-mac) appear in the GRUB menu.
  pacman -S --needed --noconfirm grub-btrfs inotify-tools >/dev/null 2>&1
  # Read-only snapshots picked in GRUB boot with a temporary writable overlay
  # (Omarchy does this with Limine on x86; omarchy-mac uses GRUB).
  printf '%s\n' '[[ " ${HOOKS[*]} " == *" grub-btrfs-overlayfs "* ]] || HOOKS+=(grub-btrfs-overlayfs)' \
    > /etc/mkinitcpio.conf.d/zz-omacvm.conf
  systemctl enable --now grub-btrfsd >/dev/null 2>&1 || true
fi
install -Dm644 /dev/stdin /etc/systemd/resolved.conf.d/10-omacvm.conf <<'EOF'
[Resolve]
FallbackDNS=1.1.1.1 9.9.9.9 2606:4700:4700::1111 2620:fe::fe
EOF
systemctl try-restart systemd-resolved 2>/dev/null || true
if (( AUTOLOGIN )); then
  # The Mac is FileVault-encrypted and locked already; hyprlock still locks
  # the session after idle.
  install -Dm644 /dev/stdin /etc/sddm.conf.d/20-omacvm-autologin.conf <<EOF
[Autologin]
User=$U
Session=hyprland-uwsm
Relogin=false
EOF
fi

if [[ $TYPE == parallels ]]; then
  log "display";    "$R/display/guest/install.sh" "$U"
  log "clipboard";  "$R/clipboard/guest/install.sh" "$U"
else
  log "UTM";        "$R/utm/guest/install.sh" "$U" "$MODE"
fi
log "memory";     "$R/memory/guest/install.sh"
log "keyboard";   "$R/keyboard/guest/install.sh" "$U" "$layout" "${variant:-}"
log "gestures";   "$R/gestures/guest/install.sh" "$U"
log "workspaces"; "$R/workspaces/guest/install.sh" "$U"
log "wallpaper";  "$R/wallpaper/guest/install.sh" "$U"
log "bridge";     "$R/bridge/guest/install.sh" "$U"
if (( THP )) && ! command -v grub-mkconfig >/dev/null; then
  log "THP kernel skipped: this VM does not boot with GRUB"
elif (( THP )); then
  log "THP kernel (about 10 minutes)"
  "$R/kernel/build-thp-kernel.sh" "$U"
fi
# Updated bar widgets only load in a new shell: restart it once if any changed.
F=$(getent passwd "$U" | cut -d: -f6)/.local/state/omacvm/restart-shell
if [[ -f $F ]]; then
  rm -f "$F"
  sudo -u "$U" env XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; omarchy-shell shell ping >/dev/null 2>&1 && omarchy-restart-shell >/dev/null 2>&1' || true
fi
mkinitcpio -P >/dev/null 2>&1 || true
grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
log "OmacVM guest side installed for $U (reboot to apply everything)"
