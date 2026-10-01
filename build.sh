#!/bin/bash
# Omaparallels: build an Omarchy VM in Parallels Desktop that feels like a
# native Mac, from nothing, in one go (about an hour, mostly downloads and the
# kernel build).
#
#   ./build.sh [--vm-name NAME] [--cpus N] [--memory-gb N] [--disk-gb N]
#              [--user NAME] [--full-name "NAME"] [--hostname NAME]
#              [--no-thp-kernel] [--autologin] [--omanotch] [--channel rc|stable] [--yes]
#
# Everything not given is taken from this Mac and shown for confirmation:
# the keyboard layout, timezone and language, and a CPU/RAM/disk size suggested
# from what the Mac has. Your user name (default: your Mac login), full name and
# password are asked for before anything is built (or --user/--full-name/--yes
# and OMAPARALLELS_PASSWORD); nothing needs answering in the VM window. Needs Apple Silicon, Parallels Desktop
# 19+ (Standard is enough) and Homebrew's zstd + e2fsprogs for the temporary
# live installer.
set -euo pipefail
R=$(cd "$(dirname "$0")" && pwd)
source "$R/lib/mac.sh"

VM="Omarchy"; CPUS=""; MEM_GB=""; DISK_GB=""; U=$(id -un); FULL=""; HOST="omarchy"
THP=1; AUTOLOGIN=0; OMANOTCH=0; CHANNEL=rc; YES=0
while (( $# )); do
  case $1 in
    --vm-name) VM=$2; shift 2 ;;
    --cpus) CPUS=$2; shift 2 ;;
    --memory-gb) MEM_GB=$2; shift 2 ;;
    --disk-gb) DISK_GB=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --full-name) FULL=$2; shift 2 ;;
    --hostname) HOST=$2; shift 2 ;;
    --no-thp-kernel) THP=0; shift ;;
    --autologin) AUTOLOGIN=1; shift ;;
    --omanotch) OMANOTCH=1; shift ;;
    --channel) CHANNEL=$2; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,17s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

# ---------- 1. this Mac ----------
[[ $(uname -m) == arm64 ]] || die "Omaparallels needs an Apple Silicon Mac"
[[ -x $PRLCTL ]] || die "Parallels Desktop is not installed"
for b in zstd e2fsck; do
  command -v "$b" >/dev/null || [[ -x $(brew --prefix e2fsprogs 2>/dev/null)/sbin/$b ]] ||
    die "missing $b: brew install zstd e2fsprogs"
done
command -v swiftc >/dev/null || die "missing the Swift compiler: xcode-select --install"
[[ -e "$HOME/Parallels/$VM.pvm" ]] && die "a VM bundle $HOME/Parallels/$VM.pvm already exists (choose --vm-name)"
free_gb=$(df -g "$HOME" | awk 'END { print $4 }')
(( free_gb >= 60 )) || die "need ~60 GB free disk space (have $free_gb GB)"

mac_cores=$(sysctl -n hw.ncpu); mac_perf=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "$mac_cores")
mac_mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
# Suggestion: every performance core (Parallels cannot pin vCPUs, so more than
# that only adds contention with macOS), half the memory (Parallels never hands
# touched guest memory back while the VM runs), 128 GB of expanding disk.
: "${CPUS:=$mac_perf}"
: "${MEM_GB:=$(( mac_mem_gb / 2 ))}"
: "${DISK_GB:=$(( free_gb >= 400 ? 200 : 128 ))}"
: "${FULL:=$(id -F 2>/dev/null || echo "$U")}"
KB=$("$R/keyboard/mac-layout.sh")
TZ_MAC=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
lang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z-]//gp')   # e.g. de-CH
region=$(defaults read -g AppleLocale 2>/dev/null | sed 's/@.*//')                 # e.g. de_CH
case $lang in
  en*|"") LANG_VM=en_US.UTF-8 ;;
  *-*) LANG_VM="${lang%%-*}_${lang##*-}.UTF-8" ;;
  *) LANG_VM="${lang}_${region##*_}.UTF-8" ;;
esac

if (( ! YES )); then
  echo
  echo "  Your user in Omarchy (Omarchy's own first-boot setup is not used):"
  read -r -p "    user name [$U]: " a; U=${a:-$U}
  read -r -p "    full name [$FULL]: " a; FULL=${a:-$FULL}
fi
[[ $U =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "user name '$U': lower-case letters, digits, - and _ only"

cat <<EOF

  Omaparallels will build this VM:

    VM name        $VM   (bundle ~/Parallels/$VM.pvm)
    CPUs / memory  $CPUS of $mac_cores cores / $MEM_GB of $mac_mem_gb GB
    disk           $DISK_GB GB, expanding (uses only what the VM stores)
    user           $U ($FULL), hostname $HOST
    keyboard       $KB   (from the Mac)
    timezone       $TZ_MAC, language $LANG_VM
    Omarchy        omarchy-mac, channel $CHANNEL
    extras         THP kernel: $( ((THP)) && echo yes || echo no ), autologin: $( ((AUTOLOGIN)) && echo yes || echo no ), Omanotch: $( ((OMANOTCH)) && echo yes || echo no )

EOF
if (( ! YES )); then
  read -r -p "  Go ahead? [Y/n] " a; [[ ${a:-y} =~ ^[Yy] ]] || exit 1
fi
if [[ -n ${OMAPARALLELS_PASSWORD:-} ]]; then
  PW=$OMAPARALLELS_PASSWORD
else
  read -r -s -p "  Password for $U in the VM: " PW; echo
  read -r -s -p "  Again: " PW2; echo
  [[ $PW == "$PW2" && -n $PW ]] || die "passwords differ or are empty"
fi
HASH=$(printf '%s' "$PW" | openssl passwd -6 -stdin)
unset PW PW2

KEY=~/.ssh/omaparallels
[[ -f $KEY ]] || { log "SSH key for the VM: $KEY"; ssh-keygen -t ed25519 -N "" -C "omaparallels" -f "$KEY" -q; }
export OMA_KEY=$KEY
started=$(date +%s)

# ---------- 2. temporary live installer + the real disk ----------
log "temporary live installer (try-omarchy, about 1.4 GB download)"
"$R/vm/live/build-live.sh" --vm-name "$VM" --root-size-gib 16 --skip-boot --ssh-key "$KEY.pub"
PVM="$HOME/Parallels/$VM.pvm"
"$PRLCTL" unregister "$VM" >/dev/null
log "VM settings and a ${DISK_GB} GB NVMe disk"
/usr/local/bin/prl_disk_tool create --hdd "$PVM/omarchy.hdd" --size "${DISK_GB}G" >/dev/null
P="$R/vm/pvs.py"
python3 "$P" "$PVM/config.pvs" omaparallels --cpus "$CPUS" --memsize $((MEM_GB * 1024)) \
  --description "Omarchy (omarchy-mac) on Arch Linux ARM, built by Omaparallels"
python3 "$P" "$PVM/config.pvs" add-nvme omarchy.hdd $((DISK_GB * 1024)) >/dev/null
python3 "$P" "$PVM/config.pvs" boot-from 0
mkdir -p ~/.local/share/omaparallels/clip ~/.local/share/omaparallels/theme
python3 "$P" "$PVM/config.pvs" add-share vmlog "$PVM" ro                       # display layout (parallels.log)
python3 "$P" "$PVM/config.pvs" add-share clip ~/.local/share/omaparallels/clip rw     # clipboard VM -> Mac
python3 "$P" "$PVM/config.pvs" add-share theme ~/.local/share/omaparallels/theme rw   # lock screen theme
cp "$PVM/config.pvs" "$PVM/config.pvs.backup"
"$PRLCTL" register "$PVM" >/dev/null
vm_start "$VM" "$PVM"
IP=$(vm_ip "$PVM" 300) || die "the live installer got no IP address"
wait_ssh "$IP"

# ---------- 3. Arch Linux ARM onto the NVMe disk ----------
log "Arch Linux ARM onto the NVMe disk ($IP)"
{
  printf 'OMA_USER=%q\nOMA_FULLNAME=%q\nOMA_HASH=%q\nOMA_TZ=%q\nOMA_LANG=%q\nOMA_HOSTNAME=%q\n' \
    "$U" "$FULL" "$HASH" "$TZ_MAC" "$LANG_VM" "$HOST"
  read -r l v <<<"$KB"; printf 'OMA_XKB_LAYOUT=%q\nOMA_XKB_VARIANT=%q\n' "$l" "${v:-}"
} | gssh "$IP" "umask 077; cat > /root/omaparallels.env"
gssh "$IP" "cat > /root/omaparallels.pub" < "$KEY.pub"
gssh "$IP" "bash -s" < "$R/vm/base-install.sh"
gssh "$IP" "systemctl poweroff" 2>/dev/null || true
wait_stopped "$VM"

log "boot from the NVMe disk, drop the live installer"
"$PRLCTL" unregister "$VM" >/dev/null
live=$(python3 - "$PVM/config.pvs" <<'PY'
import sys, xml.etree.ElementTree as ET
for h in ET.parse(sys.argv[1]).getroot().find("Hardware").findall("Hdd"):
    if h.findtext("InterfaceType") != "3": print(h.findtext("Index"), h.findtext("SystemName"))
PY
)
read -r live_idx live_disk <<<"$live"
nvme_idx=$(python3 - "$PVM/config.pvs" <<'PY'
import sys, xml.etree.ElementTree as ET
print(next(h.findtext("Index") for h in ET.parse(sys.argv[1]).getroot().find("Hardware").findall("Hdd") if h.findtext("InterfaceType") == "3"))
PY
)
python3 "$P" "$PVM/config.pvs" remove-hdd "$live_idx"
python3 "$P" "$PVM/config.pvs" boot-from "$nvme_idx"
rm -rf "${PVM:?}/$live_disk" "$PVM"/*.mem "$PVM"/*.mem.sh "$PVM/vm.lock"
cp "$PVM/config.pvs" "$PVM/config.pvs.backup"
"$PRLCTL" register "$PVM" >/dev/null
vm_start "$VM" "$PVM"
sleep 20
IP=$(vm_ip "$PVM" 300) || die "the new system got no IP address"
wait_ssh "$IP"

# ---------- 4. Omarchy + Parallels Tools ----------
log "Omarchy from omarchy-mac (the longest step)"
gssh "$IP" "OMARCHY_MAC_CHANNEL=$CHANNEL bash -s" < "$R/vm/omarchy-install.sh"
log "Parallels Tools"
gssh "$IP" "cat > /root/prl-tools-lin-arm.iso" < "/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin-arm.iso"
gssh "$IP" "set -e; mkdir -p /mnt/tools; mount -o loop,ro /root/prl-tools-lin-arm.iso /mnt/tools
  /mnt/tools/installer/install-cli.sh --install >/dev/null 2>&1 || /mnt/tools/installer/install-cli.sh --install
  umount /mnt/tools; rm -f /root/prl-tools-lin-arm.iso /root/omaparallels.env"

# ---------- 5. Omaparallels ----------
log "Omaparallels on the Mac"
"$R/mac/install.sh"
log "Omaparallels in the VM"
args=(--vm "$VM" --ip "$IP" --user "$U" --keyboard "$KB")
((THP)) || args+=(--no-thp-kernel)
((AUTOLOGIN)) && args+=(--autologin)
"$R/apply.sh" "${args[@]}"
if (( OMANOTCH )); then
  log "Omanotch (the bar beside the notch)"
  gssh "$IP" "sudo -u '$U' git clone -q https://github.com/gillesgoetsch/omanotch.git /home/'$U'/.local/share/omanotch"
  info "Omanotch's VM side installs at your first login: run ~/.local/share/omanotch/guest/install.sh in the VM"
  [[ -d ~/omanotch ]] || git clone -q https://github.com/gillesgoetsch/omanotch.git ~/omanotch
  ~/omanotch/mac/install.sh
fi
gssh "$IP" "systemctl reboot" 2>/dev/null || true

cat <<EOF

  Done in $(( ($(date +%s) - started) / 60 )) minutes. VM '$VM' is rebooting into Omarchy.

  One-time steps on the Mac:
    * Allow WiFi names: Location Services for Omaparallels Bridge (prompt).
    * Allow media keys and gestures: Accessibility for Omaparallels Bridge and
      Omaparallels Gestures, Input Monitoring for Omaparallels Gestures.
    * Parallels Desktop > Settings > Shortcuts > macOS System Shortcuts >
      "Send macOS system shortcuts: Always" (Cmd+Space etc. reach Omarchy).
    * Optional: System Settings > Screen Saver > Omarchy Lock, and
      Lock Screen > require password immediately.
  SSH: ssh -i $KEY root@$IP
EOF
