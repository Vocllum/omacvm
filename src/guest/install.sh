#!/bin/bash
# OmacVM, guest side: everything that makes Omarchy feel native in a VM on a
# Mac, in Parallels or UTM. Run as root inside the VM from a copy of this
# repository's src/ (apply.sh puts it in /usr/local/share/omacvm):
#   guest/install.sh --user NAME --keyboard "LAYOUT [VARIANT]" [--vm-type parallels|utm|fusion]
#                    [--display WxH@Hz] [--feature NAME=on|off]...
# Features: the list in ../features.tsv (bridge, wallpaper, gestures, scroll-momentum,
# omanotch, idle-lock, autologin, thp-kernel) with its defaults; a feature
# needing another one is off without it. Choices are kept in /etc/omacvm/env,
# so a later run without --feature keeps them. Old flags --no-thp-kernel,
# --thp-kernel and --autologin still work.
# --vm-type defaults to what the hardware says (Parallels or QEMU = UTM);
# --display (UTM: the fixed mode, from display/mac-display.swift) is required on UTM.
# Idempotent: run it again after an update of this repository.
# Needs, for the bridge, the token from the Mac in ~/.config/omacvm-bridge/token.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
U=""; KB="us"; TYPE=""; MODE=""
FEATURES=(); declare -A F=() NEEDS=() SET=()
while IFS=$'\t' read -r name def _ _ needs _; do
  [[ -z $name || $name == \#* ]] && continue
  FEATURES+=("$name"); NEEDS[$name]=$needs
  [[ $def == on ]] && F[$name]=on || F[$name]=off   # "notch": the Mac decides (build.sh, omacvm)
done < "$R/features.tsv"
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --keyboard) KB=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --display) MODE=$2; shift 2 ;;
    --host) HOST_GIVEN=$2; shift 2 ;;
    --feature) k=${2%%=*}; [[ $k == glide ]] && k=scroll-momentum; SET[$k]=${2#*=}; shift 2 ;;
    --no-thp-kernel) SET[thp-kernel]=off; shift ;;
    --thp-kernel) SET[thp-kernel]=on; shift ;;
    --autologin) SET[autologin]=on; shift ;;
    *) sed -n '5,6s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $U ]] && id "$U" >/dev/null || { echo "guest/install.sh: --user must be the desktop user" >&2; exit 2; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
read -r layout variant <<<"$KB"
H=$(getent passwd "$U" | cut -d: -f6)
user_ctl() { systemctl --user -M "$U@" "$@"; }

# Earlier choices, then this run's.
ENV=/etc/omacvm/env
AUTOLOGIN_CONF=/etc/sddm.conf.d/20-omacvm-autologin.conf
# Set up before choices were kept:
[[ -f $AUTOLOGIN_CONF ]] && F[autologin]=on
[[ -x $H/.local/bin/notchcast ]] && F[omanotch]=on
if [[ -r $ENV ]]; then
  # scroll-momentum was called glide in the experiment
  v=$(sed -n "s/^OMACVM_FEATURE_glide=//p" "$ENV" | tail -1); [[ -n $v ]] && F[scroll-momentum]=$v
  for f in "${FEATURES[@]}"; do
    v=$(sed -n "s/^OMACVM_FEATURE_${f//-/_}=//p" "$ENV" | tail -1)
    [[ -n $v ]] && F[$f]=$v
  done
fi
for f in "${!SET[@]}"; do
  [[ -n ${F[$f]+x} && ${SET[$f]} =~ ^(on|off)$ ]] || { echo "guest/install.sh: --feature $f=${SET[$f]}: unknown" >&2; exit 2; }
  F[$f]=${SET[$f]}
done
for f in "${FEATURES[@]}"; do
  n=${NEEDS[$f]}; [[ $n == - || -z $n ]] && continue
  [[ ${F[$n]} == on ]] || F[$f]=off
done

# Which VM, and where its Mac is: Parallels' Mac is 10.211.55.2 on its shared
# network; on UTM's shared network the Mac is the default gateway; on VMware
# Fusion's NAT network the gateway is .2 and the Mac is .1.
if [[ -z $TYPE ]]; then
  case $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) in
    Parallels*) TYPE=parallels ;;
    QEMU*) TYPE=utm ;;
    VMware*) TYPE=fusion ;;
    *) echo "guest/install.sh: unknown VM, pass --vm-type parallels|utm|fusion" >&2; exit 2 ;;
  esac
fi
case $TYPE in
  parallels) HOST=10.211.55.2 ;;
  utm) HOST=$(ip route show default | awk '{ print $3; exit }'); : "${HOST:=192.168.64.1}"
       [[ -n $MODE ]] || { echo "guest/install.sh: UTM needs --display WxH@Hz" >&2; exit 2; } ;;
  fusion) HOST=${HOST_GIVEN:-}   # from the Mac (apply.sh): the gateway's network may not be Fusion's
          [[ $HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.1$ ]] || { echo "guest/install.sh: VMware Fusion needs --host (the Mac's address on Fusion's network)" >&2; exit 2; }
          [[ -n $MODE ]] || { echo "guest/install.sh: VMware Fusion needs --display WxH@Hz" >&2; exit 2; } ;;
  *) echo "guest/install.sh: --vm-type parallels, utm or fusion" >&2; exit 2 ;;
esac
{
  printf 'OMACVM_VM_TYPE=%s\nOMACVM_HOST=%s\n' "$TYPE" "$HOST"
  for f in "${FEATURES[@]}"; do printf 'OMACVM_FEATURE_%s=%s\n' "${f//-/_}" "${F[$f]}"; done
} | install -Dm644 /dev/stdin "$ENV"
log "$TYPE VM, the Mac is $HOST"
log "features: $(for f in "${FEATURES[@]}"; do printf '%s=%s ' "$f" "${F[$f]}"; done)"

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
if [[ ${F[autologin]} == on ]]; then
  # The Mac is FileVault-encrypted and locked already; hyprlock still locks
  # the session after idle (unless idle-lock is off).
  install -Dm644 /dev/stdin "$AUTOLOGIN_CONF" <<EOF
[Autologin]
User=$U
Session=hyprland-uwsm
Relogin=false
EOF
else
  rm -f "$AUTOLOGIN_CONF"
fi

# Omarchy's idle screensaver and lock: its own "Stay Awake" switch turns both
# off (the shell watches the file). The marker remembers that OmacVM set it, so
# turning the feature back on never undoes a Stay Awake the user chose.
STAY=$H/.local/state/omarchy/indicators/stay-awake
MARK=$H/.local/state/omacvm/stay-awake-by-omacvm
if [[ ${F[idle-lock]} == off ]]; then
  log "idle screensaver and lock: off (the Mac's lock protects the VM)"
  install -d -o "$U" -g "$U" "$(dirname "$STAY")" "$(dirname "$MARK")"
  sudo -u "$U" touch "$STAY" "$MARK"
elif [[ -f $MARK ]]; then
  rm -f "$STAY" "$MARK"
fi

case $TYPE in
  parallels)
    log "display";    "$R/display/guest/install.sh" "$U"
    log "clipboard";  "$R/clipboard/guest/install.sh" "$U" ;;
  utm)
    log "UTM";        "$R/utm/guest/install.sh" "$U" "$MODE" ;;
  fusion)
    log "VMware Fusion"; "$R/fusion/guest/install.sh" "$U" "$MODE" ;;
esac
log "memory";     "$R/memory/guest/install.sh"
log "keyboard";   "$R/keyboard/guest/install.sh" "$U" "$layout" "${variant:-}"
# On UTM the gestures daemon also types Cmd shortcuts as Super, so it stays.
if [[ ${F[gestures]} == on || $TYPE == utm ]]; then
  log "gestures";   "$R/gestures/guest/install.sh" "$U"
elif systemctl is-enabled -q omacvm-gestures 2>/dev/null; then
  log "gestures: off"; systemctl disable --now omacvm-gestures >/dev/null 2>&1 || true
fi
if [[ ${F[scroll-momentum]} == on ]]; then
  log "macOS-native scroll momentum (experimental)"; "$R/gestures/guest/glide.sh" "$U" on
elif [[ -f $H/.config/hypr/omacvm_glide.lua ]]; then
  log "scroll momentum: off"; "$R/gestures/guest/glide.sh" "$U" off
fi
log "workspaces"; "$R/workspaces/guest/install.sh" "$U"
if [[ ${F[bridge]} == on ]]; then
  log "bridge";     "$R/bridge/guest/install.sh" "$U"
elif [[ -x /usr/local/bin/omacvm-bridge ]]; then
  # Disabling the clones brings Omarchy's own Bluetooth, Wi-Fi and audio widgets back.
  log "bridge: off"
  user_ctl disable --now omacvm-bridge-osd.service >/dev/null 2>&1 || true
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" bash -c \
    'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null
     for p in omacvm.bluetooth omacvm.wifi omacvm.audio omacvm.wifiqr omacvm.nightshift; do omarchy plugin disable "$p" >/dev/null 2>&1; done' || true
  # Omarchy's own night light indicator, as it was before the Bridge.
  NL=$H/.local/state/omacvm/nightlight-indicator C=$H/.config/omarchy/shell.json
  if [[ -f $NL && -f $C ]]; then
    tmp=$(mktemp)
    jq --argjson items "$(cat "$NL")" '(.bar.layout[]?[]? | select(.id == "omarchy.indicators")) |= (if $items == null then del(.items) else .items = $items end)' "$C" > "$tmp" &&
      install -o "$U" -g "$U" -m600 "$tmp" "$C"
    rm -f "$tmp" "$NL"
  fi
  rm -f /usr/local/bin/omarchy-toggle-nightlight /usr/local/bin/omarchy-network-qr /usr/local/bin/omarchy-network-password
fi
if [[ ${F[wallpaper]} == on ]]; then
  log "wallpaper";  "$R/wallpaper/guest/install.sh" "$U"
elif user_ctl is-enabled -q omacvm-wallpaper.path 2>/dev/null; then
  log "wallpaper: off"; user_ctl disable --now omacvm-wallpaper.path omacvm-wallpaper.service >/dev/null 2>&1 || true
fi
# Omanotch's VM side (github.com/gillesgoetsch/omanotch) builds and installs in
# the desktop session: omacvm-omanotch.service runs it at the next login, or
# right away when the session is running.
in_session() {
  local run; run=/run/user/$(id -u "$U")
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="$run" WAYLAND_DISPLAY=wayland-1 \
    HYPRLAND_INSTANCE_SIGNATURE="$(ls -t "$run/hypr" 2>/dev/null | head -1)" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}
if [[ ${F[omanotch]} == on ]]; then
  if [[ ! -x $H/.local/bin/notchcast ]]; then
    log "Omanotch (the bar beside the notch)"
    pacman -S --needed --noconfirm base-devel lz4 wayland wayland-protocols git >/dev/null 2>&1
    [[ -d $H/.local/share/omanotch ]] ||
      sudo -u "$U" git clone -q https://github.com/gillesgoetsch/omanotch.git "$H/.local/share/omanotch"
    install -m644 "$R/guest/omacvm-omanotch.service" /etc/systemd/user/
    systemctl --global enable omacvm-omanotch.service >/dev/null 2>&1
    if pgrep -u "$U" -x Hyprland >/dev/null; then
      user_ctl daemon-reload 2>/dev/null || true
      user_ctl start omacvm-omanotch.service 2>/dev/null || log "Omanotch: installs at the next login"
    else
      log "Omanotch: installs at the first login"
    fi
  fi
elif [[ -x $H/.local/bin/notchcast ]]; then
  log "Omanotch: off"
  systemctl --global disable omacvm-omanotch.service >/dev/null 2>&1 || true
  if [[ -f $H/.local/share/omanotch/guest/uninstall.sh ]]; then
    in_session bash "$H/.local/share/omanotch/guest/uninstall.sh" >/dev/null 2>&1 || true
  else
    user_ctl disable --now notchcast.service >/dev/null 2>&1 || true
  fi
fi
if [[ ${F[thp-kernel]} == on ]]; then
  if command -v grub-mkconfig >/dev/null; then
    log "memory-optimized kernel (about 10 minutes)"
    "$R/kernel/build-thp-kernel.sh" "$U"
  else
    log "memory-optimized kernel skipped: this VM does not boot with GRUB"
  fi
fi
# Updated bar widgets only load in a new shell: restart it once if any changed.
# Never while the session is locked: Omarchy's lock screen lives in the shell,
# and a restart leaves Hyprland's "lockscreen app died" screen behind. Locked:
# a background job restarts it right after the next unlock.
RS=$H/.local/state/omacvm/restart-shell
if [[ -f $RS ]]; then
  rm -f "$RS"
  sudo -u "$U" env XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" bash -c '
    source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null
    omarchy-shell shell ping >/dev/null 2>&1 || exit 0
    if [[ $(omarchy-shell lock isLocked 2>/dev/null) != true ]]; then
      omarchy-restart-shell >/dev/null 2>&1
    else
      systemd-run --user --quiet --collect --unit=omacvm-restart-shell bash -c "
        source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null
        while [[ \$(omarchy-shell lock isLocked 2>/dev/null) == true ]]; do sleep 5; done
        sleep 2; omarchy-restart-shell" 2>/dev/null || true
      echo "the Omarchy shell restarts after the next unlock (new bar widgets)"
    fi' || true
fi
mkinitcpio -P >/dev/null 2>&1 || true
grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
[[ $TYPE == fusion ]] && "$R/fusion/guest/dns.sh" off   # back to Fusion's DNS, which follows the Mac's
log "OmacVM guest side installed for $U (reboot to apply everything)"
