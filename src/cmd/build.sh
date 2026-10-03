#!/bin/bash
# omacvm build: an Omarchy VM that feels like a native Mac, in Parallels
# Desktop, UTM or VMware Fusion, from nothing, in one go (30-70 minutes, mostly
# downloads; Fusion about 15 more, it builds Hyprland with a fix).
#
#   omacvm build             asks a few questions, shows a summary, then builds
#   omacvm build --dry-run   asks the questions and shows the summary only
#   omacvm build --plan --json   the summary as JSON, nothing built (agents)
#
# Everything can also be given up front (--yes skips the questions; the
# password then comes from OMACVM_PASSWORD):
#   --vm-type parallels|utm|fusion   --vm-name NAME   --hostname NAME
#   --resources low|balanced|high|best   --cpus N   --memory-gb N   --disk-gb N
#   --vm-dir PATH   where the VM goes (Parallels, Fusion; default: the app's own folder)
#   --graphics-gb N   VMware Fusion: graphics memory, part of the VM's memory (1-8)
#   --user NAME   --full-name "NAME"
#   --parallels-edition standard|pro   only while Parallels has no licence yet
#                (a fresh install; the trial is Pro): the limits to size the VM by
#   --feature NAME=on|off, or --FEATURE / --no-FEATURE (omacvm features lists
#   them: bridge wallpaper gestures scroll-momentum omanotch idle-lock autologin thp-kernel)
# The keyboard layout, timezone and language come from this Mac. Needs Apple
# Silicon, Parallels Desktop 19+, UTM 5 or VMware Fusion 13+, and Homebrew's
# zstd + e2fsprogs. Fusion VMs go to ~/Virtual Machines.localized, or
# $OMACVM_FUSION_DIR.
# Exit codes: 0 built, 1 failed, 2 usage (or a question without a terminal),
# 3 needs a person (an app to install, see the message).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/vm/utm.sh"
source "$R/src/vm/fusion.sh"
source "$R/src/lib/setup.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/ui.sh"
source "$R/src/lib/prereq.sh"
features_load

# The Linux user name suggested from the Mac's: lower case, letters, digits,
# - and _ only, starting with a letter ("Gilles.Goetsch" -> "gillesgoetsch").
linux_name() {
  local n; n=$(iconv -f UTF-8 -t ASCII//TRANSLIT <<<"$1" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
  n=${n#"${n%%[a-z_]*}"}
  printf '%s' "${n:0:32}"
}
TYPE=""; VM="Omarchy"; RES=""; CPUS=""; MEM_GB=""; DISK_GB=""; U=$(linux_name "$(id -un)"); FULL=""; HOST="omarchy"
[[ -n $U ]] || U=omarchy
BRIDGE=1; WALLPAPER=1; GESTURES=1; GLIDE=0; OMANOTCH=""; IDLE_LOCK=1; AUTOLOGIN=0; THP=0
CHANNEL=""; YES=0; DRY=0; PLAN=0; JSON=0
usage() { echo "omacvm build: $*" >&2; exit 2; }
needs_person() { printf '\033[1;31mneeds you:\033[0m %s\n' "$*" >&2; exit 3; }
feature_flag() {   # NAME on|off
  local v; [[ $2 == on ]] && v=1 || v=0
  case $1 in
    bridge) BRIDGE=$v; (( v )) || WALLPAPER=0 ;;
    wallpaper|mac-wallpaper) WALLPAPER=$v ;;
    gestures) GESTURES=$v ;;
    scroll-momentum|glide) GLIDE=$v ;;
    omanotch) OMANOTCH=$v ;;
    idle-lock) IDLE_LOCK=$v ;;
    autologin) AUTOLOGIN=$v ;;
    thp-kernel) THP=$v ;;
    *) usage "unknown feature '$1' (omacvm features lists them)" ;;
  esac
  [[ $2 == on || $2 == off ]] || usage "--feature $1=$2: on or off"
}
while (( $# )); do
  case $1 in
    --vm-type) TYPE=$2; shift 2 ;;
    --vm-name) VM=$2; NAME_GIVEN=1; shift 2 ;;
    --vm-dir) VM_DIR=$2; shift 2 ;;
    --graphics-gb) GFX_GB=$2; shift 2 ;;
    --resources) RES=$2; shift 2 ;;
    --cpus) CPUS=$2; shift 2 ;;
    --memory-gb) MEM_GB=$2; shift 2 ;;
    --disk-gb) DISK_GB=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --full-name) FULL=$2; shift 2 ;;
    --hostname) HOST=$2; shift 2 ;;
    --feature) feature_flag "${2%%=*}" "${2#*=}"; shift 2 ;;
    --parallels-edition) P_PLAN=$2; shift 2
      [[ $P_PLAN == standard || $P_PLAN == pro ]] || usage "--parallels-edition standard or pro" ;;
    --channel) CHANNEL=$2; shift 2 ;;          # rc|stable|edge, for testing omarchy-mac
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --plan) PLAN=1; DRY=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,21s/^# \{0,1\}//p' "$0"; exit 0 ;;
    --no-*) feature_flag "${1#--no-}" off; shift ;;
    --*) feature_flag "${1#--}" on; shift ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ $(uname -m) == arm64 ]] || die "OmacVM needs an Apple Silicon Mac"
macos=$(sw_vers -productVersion 2>/dev/null)
(( ${macos%%.*} >= 14 )) || { printf '\033[1;31mneeds you:\033[0m OmacVM needs macOS 14 (Sonoma) or newer; this Mac runs %s\n' "$macos" >&2; exit 3; }
(( JSON )) && ! (( PLAN )) && usage "--json goes with --plan"
(( PLAN && JSON )) && YES=1   # a plan for an agent never asks
(( YES )) || { : < "$TTY"; } 2>/dev/null || usage "the setup questions need a terminal (or pass --yes and the answers as options, see --help)"
onoff() { (( $1 )) && echo on || echo off; }

mac_cores=$(sysctl -n hw.ncpu)
mac_perf=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "$mac_cores")
mac_eff=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo 0)
mac_mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
# Free space as Finder counts it (macOS frees caches and purgeable files when
# needed; df leaves those out), else df's.
free_gb=$(swift -e 'import Foundation; let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]); print((v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)' 2>/dev/null)
[[ $free_gb =~ ^[0-9]+$ && $free_gb -gt 0 ]] || free_gb=$(df -g "$HOME" | awk 'END { print $4 }')
NOTCH=$(swift "$R/src/display/mac-notch.swift" 2>/dev/null || echo none)
[[ -n $OMANOTCH ]] || { [[ $NOTCH == notch ]] && OMANOTCH=1 || OMANOTCH=0; }

if (( ! JSON )); then
  printf '\n  \033[1;36m⌘\033[0m \033[1mOmacVM %s\033[0m  Omarchy in a VM on your Mac, feeling native\n' "$(cat "$R/src/VERSION")"
  (( YES )) || prereq_screen
fi

# What the build needs: Xcode's command line tools and Homebrew (installed
# after asking), then Homebrew's zstd, e2fsprogs and OpenSSL. A plan only reports.
if (( PLAN )); then
  have_xcode_tools || needs_person "Xcode's command line tools are missing: xcode-select --install"
else
  ensure_xcode_tools
  ensure_swift_works
  ensure_brew_tools
fi
# A build peaks at about 25 GB (download, temporary installer, new disk); a
# finished VM takes 10-12 GB and grows as it is used.
(( free_gb >= 30 )) || needs_person "OmacVM needs about 30 GB free disk space to build (this Mac has $free_gb GB free)"
(( free_gb >= 50 )) || info "$free_gb GB free: enough to build; the VM grows as you use it, so keep some room."


# ---------- 1. Parallels, UTM or VMware Fusion ----------
if [[ -z $TYPE ]]; then
  (( YES )) && usage "--yes needs --vm-type parallels, utm or fusion"
  ui_select pick "Where should Omarchy run?" 0 \
    "Parallels Desktop|near-native speed, every display · paid" \
    "UTM|free · one display, slower desktop · UTM 5 (beta)" \
    "VMware Fusion|free · every display · slower desktop · OmacVM patches Hyprland for it (new)"
  case $pick in 0) TYPE=parallels ;; 1) TYPE=utm ;; *) TYPE=fusion ;; esac
  say "    Comparison: $README_ROUTES"
fi
# The app itself: installed now (after asking) when it is missing.
(( PLAN )) || ensure_vm_app "$TYPE"
CAP_CPUS=$mac_cores; CAP_MEM_GB=$mac_mem_gb; P_EDITION=""; P_TRIAL=""
case $TYPE in
  parallels)
    if (( YES )); then
      rc=1; [[ -x $PRLCTL ]] && { parallels_limits && rc=0 || rc=$?; }
      # A fresh install starts its trial when the VM starts: the planned edition.
      (( rc == 3 )) && { parallels_planned_limits "${P_PLAN:-standard}"; rc=0; }
      (( rc != 2 )) || needs_person "Parallels Desktop reports no active licence yet (${P_STATUS:-no status}): start the trial or sign in, then run this again"
      (( rc == 0 )) || needs_person "Parallels Desktop is not installed and set up: install it (https://www.parallels.com/products/desktop/ or brew install --cask parallels), open it once and sign in or start the trial"
    else wait_for_app parallels; fi
    vm_network_ok parallels || needs_person "Parallels' shared network is not its default (see above)"
    (( CAP_CPUS > mac_cores )) && CAP_CPUS=$mac_cores
    (( CAP_MEM_GB > mac_mem_gb )) && CAP_MEM_GB=$mac_mem_gb ;;
  utm)
    if (( YES )); then [[ -x $UTMCTL ]] && (( $(utm_major || echo 0) >= 5 )) || { utm_install_help >&2; needs_person "UTM 5 is not installed (brew install --cask utm@beta, then open UTM once)"; }
    else wait_for_app utm; fi
    : ;;
  fusion)
    if (( YES )); then have_fusion || needs_person "VMware Fusion is not installed: download it from support.broadcom.com (free, needs a sign-in), then open it once"
    else wait_for_app fusion; fi
    vm_network_ok fusion || needs_person "VMware Fusion's NAT network is missing (see above)" ;;
  *) usage "--vm-type parallels, utm or fusion" ;;
esac
[[ $VM =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]] || usage "--vm-name: letters, digits, spaces, dots, _ and - only (got '$VM')"
# A name is taken in any app: omacvm --vm NAME has to find one VM.
vm_taken() {
  [[ -e "$HOME/Parallels/$1.pvm" || -e $(fusion_bundle "$1") ]] || vms_list | awk -F'\t' -v n="$1" '$1 == n { f = 1 } END { exit !f }'
}
if vm_taken "$VM"; then
  n=2; while vm_taken "$VM $n"; do n=$((n + 1)); done
  if (( YES )); then
    [[ -n ${NAME_GIVEN:-} ]] && usage "a VM named '$VM' already exists (choose another --vm-name, e.g. '$VM $n')"
    VM="$VM $n"   # the default name, taken: the next free one
  fi
fi
if vm_taken "$VM"; then
  hd "You already have a VM named '$VM'"
  while :; do
    VM=$(ask_value "name for the new VM" "$VM $n" '^[A-Za-z0-9][A-Za-z0-9 ._-]*$')
    vm_taken "$VM" || break
    say "    '$VM' exists too"
  done
fi
# ---------- 2. resources ----------
LIMITED=""
if [[ $TYPE == parallels && $CAP_CPUS -le 4 ]]; then
  if [[ -n ${P_PLANNED:-} ]]; then
    LIMITED="You plan on Parallels Desktop Standard: $CAP_CPUS CPUs / $CAP_MEM_GB GB per VM; Pro raises this to 18 CPUs / 128 GB."
  else
    LIMITED="Parallels Desktop $(tr '[:lower:]' '[:upper:]' <<<"${P_EDITION:0:1}")${P_EDITION:1} allows $CAP_CPUS CPUs / $CAP_MEM_GB GB per VM; Pro raises this to 18 CPUs / 128 GB."
  fi
fi
case ${RES:-balanced} in low) tier=0 ;; balanced) tier=1 ;; high) tier=2 ;; best) tier=3 ;; *) die "--resources low|balanced|high|best" ;; esac
tier_values 0; low="$T_CPUS/$T_MEM"; tier_values 3
if [[ $low == "$T_CPUS/$T_MEM" && -n $LIMITED ]]; then
  (( YES )) || { hd "Resources"; say "    $LIMITED"; say "    The VM gets that: $T_CPUS CPUs, $T_MEM GB memory."; }
  tier=3
elif (( ! YES )) && [[ -z $CPUS && -z $MEM_GB && -z $RES ]]; then
  say ""
  say "    The VM keeps memory it has touched until it stops; Best leaves macOS and the"
  say "    GPU a buffer of $(( mac_mem_gb / 4 > 8 ? mac_mem_gb / 4 : 8 )) GB.${LIMITED:+ $LIMITED}"
  opts=()
  for t in 0 1 2 3; do tier_values "$t"; rec=""; (( t == 1 )) && rec="  (recommended)"; opts+=("${TIERS[$t]}|$T_CPUS CPUs, $T_MEM GB memory$rec"); done
  opts+=("Custom|choose CPUs, memory and the disk size")
  ui_select tier "How much of this Mac ($mac_cores CPUs, $mac_mem_gb GB) should the VM get?" 1 "${opts[@]}"
  (( tier == 4 )) && { custom=1; tier=1; }
fi
tier_values "$tier"
: "${CPUS:=$T_CPUS}"; : "${MEM_GB:=$T_MEM}"
: "${DISK_GB:=$(( free_gb >= 400 ? 200 : 128 ))}"
if (( ${custom:-0} )); then
  CPUS=$(ask_value "CPUs (1-$CAP_CPUS)" "$CPUS" '^[0-9]+$')
  MEM_GB=$(ask_value "memory in GB (4-$CAP_MEM_GB)" "$MEM_GB" '^[0-9]+$')
  DISK_GB=$(ask_value "disk size limit in GB (64 or more; it only takes what it holds)" "$DISK_GB" '^[0-9]+$')
fi
(( CPUS >= 1 && CPUS <= CAP_CPUS )) || die "CPUs: 1 to $CAP_CPUS${LIMITED:+ ($LIMITED)}"
(( MEM_GB >= 4 && MEM_GB <= CAP_MEM_GB )) || die "memory: 4 to $CAP_MEM_GB GB${LIMITED:+ ($LIMITED)}"
(( DISK_GB >= 64 )) || die "disk: at least 64 GB"
# VMware Fusion: the GPU's memory comes out of the VM's own. A quarter of it,
# up to Fusion's 8 GB (two Retina displays need several GB).
if [[ $TYPE == fusion ]]; then
  gfx_auto=$(( MEM_GB / 4 )); (( gfx_auto > 8 )) && gfx_auto=8; (( gfx_auto < 1 )) && gfx_auto=1
  if (( ${custom:-0} )) && [[ -z ${GFX_GB:-} ]]; then
    GFX_GB=$(ask_value "graphics memory in GB, part of the VM's memory (1-8)" "$gfx_auto" '^[0-9]+$')
  fi
  : "${GFX_GB:=$gfx_auto}"
  (( GFX_GB >= 1 && GFX_GB <= 8 && GFX_GB < MEM_GB )) || die "graphics memory: 1 to 8 GB, less than the VM's memory"
fi

# ---------- where the VM goes ----------
# Parallels and Fusion take any folder (an external drive, say); UTM keeps its
# VMs in its own library (moving one there is not safe through its scripting).
default_dir() { case $TYPE in parallels) echo "$HOME/Parallels" ;; fusion) echo "$FUSION_DIR" ;; utm) echo "UTM's library" ;; esac; }
free_gb_at() {   # free GB on the drive of a folder, as Finder counts it
  local g
  g=$(swift -e 'import Foundation; let v = try? URL(fileURLWithPath: CommandLine.arguments[1]).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]); print((v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)' "$1" 2>/dev/null)
  [[ $g =~ ^[0-9]+$ && $g -gt 0 ]] || g=$(df -g "$1" | awk 'END { print $4 }')
  echo "$g"
}
vm_dir_problem() {   # DIR -> a reason it does not work, or nothing
  local mp fs dev
  [[ -d $1 && -w $1 ]] || { echo "not a folder you can write to"; return; }
  mp=$(df -P "$1" | awk 'END { print $6 }')
  fs=$(mount | awk -v m="$mp" '$3 == m { sub(/^\(/, "", $4); sub(/,$/, "", $4); print $4; exit }')
  case $fs in apfs|hfs) ;; *) echo "its drive is ${fs:-unknown}: a VM disk needs APFS or Mac OS Extended (Disk Utility can erase it as APFS)"; return ;; esac
  (( $(free_gb_at "$1") >= 30 )) || echo "only $(free_gb_at "$1") GB free on that drive (the VM needs about 30)"
}
if [[ -n ${VM_DIR:-} && $TYPE == utm ]]; then usage "--vm-dir: UTM keeps its VMs in its own library"; fi
if [[ -z ${VM_DIR:-} && $TYPE != utm ]] && (( ! YES )); then
  ui_select loc "Where should the VM go?" 0 "Default|$(default_dir | sed "s|^$HOME|~|")" \
    "Another folder…|an external drive, for example (a Finder window opens)"
  while (( loc == 1 )); do
    VM_DIR=$(osascript -e 'POSIX path of (choose folder with prompt "Where should the Omarchy VM go?")' 2>/dev/null) ||
      VM_DIR=$(ask_value "folder for the VM" "" '^/')
    VM_DIR=${VM_DIR%/}
    p=$(vm_dir_problem "$VM_DIR")
    [[ -z $p ]] && break
    say "    $VM_DIR: $p"
    ui_select loc "Where should the VM go?" 1 "Default|$(default_dir | sed "s|^$HOME|~|")" "Another folder…|pick again"
    (( loc == 0 )) && VM_DIR=""
  done
fi
if [[ -n ${VM_DIR:-} ]]; then
  VM_DIR=${VM_DIR%/}
  p=$(vm_dir_problem "$VM_DIR"); [[ -z $p ]] || needs_person "--vm-dir $VM_DIR: $p"
  dev=$(df -P "$VM_DIR" | awk 'END { print $1 }')
  if diskutil info "$dev" 2>/dev/null | grep -qE "Device Location: +External|Removable Media: +Removable"; then
    EXTERNAL=1
    (( PLAN && JSON )) || info "On an external drive: connect it before you start the VM, and never unplug it while the VM runs."
  fi
  [[ $TYPE == fusion ]] && FUSION_DIR=$VM_DIR
fi
[[ -n ${VM_DIR:-} || $TYPE == utm ]] || VM_DIR=$(default_dir)
case $TYPE in
  parallels) [[ ! -e $VM_DIR/$VM.pvm ]] || usage "$VM_DIR/$VM.pvm already exists (choose another --vm-name)" ;;
  fusion) [[ ! -e $(fusion_bundle "$VM") ]] || usage "$(fusion_bundle "$VM") already exists (choose another --vm-name)" ;;
esac

# ---------- 3. features ----------
# The build's switches by feature name (src/features.tsv).
fvar() {
  case $1 in
    bridge) echo BRIDGE ;; wallpaper) echo WALLPAPER ;; gestures) echo GESTURES ;;
    scroll-momentum) echo GLIDE ;; omanotch) echo OMANOTCH ;; idle-lock) echo IDLE_LOCK ;;
    autologin) echo AUTOLOGIN ;; thp-kernel) echo THP ;;
  esac
}
fget() { local v; v=$(fvar "$1"); echo "${!v:-0}"; }
fput() { local v; v=$(fvar "$1"); [[ -n $v ]] && printf -v "$v" '%s' "$2"; return 0; }
explain_features() {
  local i v state
  for ((i = 0; i < ${#FN[@]}; i++)); do
    v=$(fget "${FN[$i]}")
    state=$( ((v)) && echo on || echo off)
    [[ ${FN[$i]} == idle-lock ]] && state=$( ((v)) && echo kept || echo "off, the Mac's lock")
    [[ ${FN[$i]} == omanotch && $NOTCH != notch ]] && state="off (no notch)"
    printf '    %-48s %s%s\n' "${FTITLE[$i]}" "$state" "$(feature_has_tag "$i" experimental && echo "  (experimental)")"
  done
}
if (( ! YES )); then
  UI_KEYS=(); UI_LABELS=(); UI_DETAILS=(); UI_ON=(); UI_TAG=(); UI_OFF_REASON=(); UI_NEEDS=()
  for ((i = 0; i < ${#FN[@]}; i++)); do
    UI_KEYS+=("${FN[$i]}"); UI_LABELS+=("${FTITLE[$i]}"); UI_DETAILS+=("${FSUM[$i]}")
    UI_ON+=("$(fget "${FN[$i]}")")
    t=""; feature_has_tag "$i" experimental && t=experimental; feature_has_tag "$i" slow && t=slow
    UI_TAG+=("$t")
    r=""; feature_has_tag "$i" notch && [[ $NOTCH != notch ]] && r="needs a MacBook with a notch"
    UI_OFF_REASON+=("$r")
    n=${FNEEDS[$i]}; [[ $n == - ]] && n=""; UI_NEEDS+=("$n")
  done
  ui_checklist "Features (the recommended ones are on; switch any later with omacvm features)"
  for ((i = 0; i < ${#UI_KEYS[@]}; i++)); do fput "${UI_KEYS[$i]}" "${UI_ON[$i]}"; done
fi
(( GESTURES )) || GLIDE=0
(( BRIDGE )) || WALLPAPER=0

# ---------- 4. you ----------
: "${FULL:=$(id -F 2>/dev/null || echo "$U")}"
if (( ! YES )); then
  hd "Your user in Omarchy"
  U=$(ask_value "user name" "$U" '^[a-z_][a-z0-9_-]{0,31}$')
  FULL=$(ask_value "full name" "$FULL" '.')
fi
[[ $U =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "user name '$U': lower-case letters, digits, - and _ only"

KB_NOTE=$("$R/src/keyboard/mac-layout.sh" 2>&1 >/dev/null)
KB=$("$R/src/keyboard/mac-layout.sh" 2>/dev/null)
KB_SHOWN="$KB   (from the Mac)"
[[ -n $KB_NOTE ]] && KB_SHOWN="$KB   (no Linux match for your Mac's layout yet: set yours in Omarchy's keyboard settings)"
TZ_MAC=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
lang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z-]//gp')   # e.g. de-CH
region=$(defaults read -g AppleLocale 2>/dev/null | sed 's/@.*//')                 # e.g. de_CH
case $lang in
  en*|"") LANG_VM=en_US.UTF-8 ;;
  *-*) LANG_VM="${lang%%-*}_${lang##*-}.UTF-8" ;;
  *) LANG_VM="${lang}_${region##*_}.UTF-8" ;;
esac
[[ -n $CHANNEL ]] || CHANNEL=$(omarchy_channel)

FEATS=(bridge "$BRIDGE" wallpaper "$WALLPAPER" gestures "$GESTURES" scroll-momentum "$GLIDE" omanotch "$OMANOTCH"
       idle-lock "$IDLE_LOCK" autologin "$AUTOLOGIN" thp-kernel "$THP")
# The one-time steps only a person can do on the Mac, one per line.
human_steps() {
  (( ${EXTERNAL:-0} )) && echo "The VM is on an external drive: connect it before you start the VM, and never unplug it while the VM runs."
  if (( BRIDGE )); then
    echo "Allow Wi-Fi names: Location Services for OmacVM Bridge (macOS asks)."
    echo "Allow media keys: Accessibility for OmacVM Bridge."
    echo "Allow Bluetooth devices: Bluetooth for OmacVM Bridge (macOS asks)."
  fi
  if (( GESTURES )) || [[ $TYPE == utm || $TYPE == fusion ]]; then
    local what="the trackpad"
    [[ $TYPE == utm || $TYPE == fusion ]] && { (( GESTURES )) && what="the trackpad and Cmd keys" || what="the Cmd keys"; }
    echo "Allow $what: Accessibility and Input Monitoring for OmacVM Gestures."
  fi
  case $TYPE in
  parallels)
    [[ -n ${P_PLANNED:-} ]] && echo "Parallels has no licence yet: when the build starts the VM, start the free trial or sign in in the window Parallels shows."
    parallels_profile_emptied || echo "Let Cmd+C/V/X reach Omarchy as Super: quit Parallels Desktop, run src/mac/parallels-shortcuts.sh (app-wide: every Linux VM in Parallels)."
    parallels_sends_shortcuts || echo "Let Cmd+Space etc. reach Omarchy: Parallels Desktop > Settings > Shortcuts > macOS System Shortcuts > \"Send macOS system shortcuts: Always\" (an alert shows where)." ;;
  utm)
    echo "UTM: put the VM in full screen on the built-in display (gestures and media keys need it); keep UTM in the foreground, a backgrounded UTM runs slower." ;;
  fusion)
    echo "VMware Fusion asks for Accessibility on its first start: click OK, then turn on VMware Fusion in System Settings > Privacy & Security > Accessibility (keyboard and mouse in the VM)."
    echo "VMware Fusion: put the VM in full screen (View > Full Screen; gestures and media keys need it)." ;;
  esac
}
if (( PLAN && JSON )); then
  cmd="OMACVM_PASSWORD=… omacvm build --yes --vm-type $TYPE --vm-name $(printf %q "$VM") --cpus $CPUS --memory-gb $MEM_GB --disk-gb $DISK_GB --user $U --full-name $(printf %q "$FULL") --hostname $HOST"
  [[ -n ${VM_DIR:-} && $VM_DIR != "$(default_dir)" ]] && cmd+=" --vm-dir $(printf %q "$VM_DIR")"
  [[ -n ${GFX_GB:-} ]] && cmd+=" --graphics-gb $GFX_GB"
  printf '{\n  "omacvm": %s,\n' "$(json_str "$(cat "$R/src/VERSION")")"
  printf '  "vm": {"name": %s, "type": "%s", "app_version": %s, "cpus": %s, "memory_gb": %s, "disk_gb": %s, "hostname": %s, "dir": %s},\n' \
    "$(json_str "$VM")" "$TYPE" "$(json_str "$(case $TYPE in
      (parallels) echo "Parallels Desktop $P_EDITION${P_TRIAL:+ trial=$P_TRIAL}${P_PLANNED:+ (planned: no licence yet, Parallels asks for the trial or a sign-in when the VM starts)}" ;;
      (utm) echo "UTM $(defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null)" ;;
      (fusion) echo "VMware Fusion $(fusion_version)" ;;
    esac)")" \
    "$CPUS" "$MEM_GB" "$DISK_GB" "$(json_str "$HOST")" "$(json_str "${VM_DIR:-UTM library}")"
  printf '  "limits": {"cpus": %s, "memory_gb": %s},\n' "$CAP_CPUS" "$CAP_MEM_GB"
  [[ -n ${GFX_GB:-} ]] && printf '  "graphics_gb": %s,\n' "$GFX_GB"
  printf '  "resource_tiers": {'   # what --resources gives on this Mac
  for t in 0 1 2 3; do
    tier_values "$t"
    printf '%s"%s": {"cpus": %s, "memory_gb": %s}' "$( ((t)) && echo ', ')" "$(tr '[:upper:]' '[:lower:]' <<<"${TIERS[$t]}")" "$T_CPUS" "$T_MEM"
  done
  printf '},\n'

  printf '  "user": {"name": %s, "full_name": %s},\n' "$(json_str "$U")" "$(json_str "$FULL")"
  printf '  "from_the_mac": {"keyboard": %s, "timezone": %s, "language": %s, "notch": %s},\n' \
    "$(json_str "$KB")" "$(json_str "$TZ_MAC")" "$(json_str "$LANG_VM")" "$( [[ $NOTCH == notch ]] && echo true || echo false)"
  printf '  "features": {'
  for ((k = 0; k < ${#FEATS[@]}; k += 2)); do
    printf '%s"%s": %s' "$( ((k)) && echo ', ')" "${FEATS[$k]}" "$( ((FEATS[k+1])) && echo true || echo false)"
    cmd+=" --feature ${FEATS[$k]}=$( ((FEATS[k+1])) && echo on || echo off)"
  done
  printf '},\n  "minutes": "30-70",\n  "needs_human": ['
  first=1
  while IFS= read -r step; do
    printf '%s\n    %s' "$( ((first)) || echo ,)" "$(json_str "$step")"; first=0
  done < <(echo "Choose the password for $U in Omarchy (OMACVM_PASSWORD for --yes)."; human_steps)
  printf '\n  ],\n  "command": %s\n}\n' "$(json_str "$cmd")"
  exit 0
fi
# What the VM runs in, for the summary.
if [[ $TYPE == parallels ]]; then
  APP_LINE="Parallels Desktop $(tr '[:lower:]' '[:upper:]' <<<"${P_EDITION:0:1}")${P_EDITION:1}"
  if [[ -n ${P_PLANNED:-} ]]; then APP_LINE+=" (planned; no licence yet, the trial starts with the VM)"
  elif [[ $P_TRIAL == yes ]]; then APP_LINE+=" (trial)"; fi
  APP_LINE+=" ($(sed "s|^$HOME|~|" <<<"$VM_DIR/$VM.pvm"))"
elif [[ $TYPE == utm ]]; then
  APP_LINE="UTM $(defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
else
  APP_LINE="VMware Fusion $(fusion_version) ($(fusion_bundle "$VM" | sed "s|^$HOME|~|"))"
fi
box=("OmacVM will build this VM" ""
     "VM         $VM, in $APP_LINE"
     "resources  $CPUS of $mac_cores CPUs, $MEM_GB of $mac_mem_gb GB memory${GFX_GB:+ ($GFX_GB GB of it for graphics)}, $DISK_GB GB disk (expanding)"
     "user       $U ($FULL), hostname $HOST"
     "keyboard   $KB_SHOWN"
     "timezone   $TZ_MAC, language $LANG_VM"
     "Omarchy    omarchy-mac, $CHANNEL packages" "")
while IFS= read -r l; do box+=("${l#    }"); done < <(explain_features)
if (( UI_FANCY )) && ! (( YES )); then ui_box "${box[@]}"
else printf '\n'; for l in "${box[@]}"; do printf '  %s\n' "$l"; done; fi
echo
if (( DRY )); then echo "  $( ((PLAN)) && echo Plan || echo "Dry run"): nothing was built."; exit 0; fi
if (( ! YES )); then
  ask_yn "Go ahead?" y || exit 1
fi
if [[ -n ${OMACVM_PASSWORD:-} ]]; then
  PW=$OMACVM_PASSWORD
elif (( YES )) && ! { : < "$TTY"; } 2>/dev/null; then
  usage "--yes without a terminal needs OMACVM_PASSWORD (the password for $U in Omarchy)"
else
  read -r -s -p "  Password for $U in Omarchy: " PW < "$TTY"; echo
  read -r -s -p "  Again: " PW2 < "$TTY"; echo
  [[ $PW == "$PW2" && -n $PW ]] || die "passwords differ or are empty"
fi
HASH=$(printf '%s' "$PW" | "$(sha512_openssl)" passwd -6 -stdin) || die "could not hash the password (openssl passwd -6)"
[[ $HASH == '$6$'* ]] || die "could not hash the password (openssl passwd -6)"
unset PW PW2

# Cmd as Super in Parallels: its Linux keyboard profile turns Cmd+C/V/X into
# Ctrl. Emptying it needs Parallels Desktop closed: done now when no VM runs.
if [[ $TYPE == parallels ]] && ! parallels_profile_emptied; then
  if ! "$PRLCTL" list -o status 2>/dev/null | grep -q running; then
    if pgrep -xq prl_client_app; then
      osascript -e 'quit app "Parallels Desktop"' >/dev/null 2>&1 || true
      for _ in $(seq 20); do pgrep -xq prl_client_app || break; sleep 1; done
    fi
    if ! pgrep -xq prl_client_app && "$R/src/mac/parallels-shortcuts.sh" >/dev/null; then
      log "Cmd reaches Omarchy as Super (Parallels' Linux keyboard profile emptied)"
    fi
  fi
fi

# From here on: numbered steps, and everything also into a log file.
STEP=0; STEPS=$( [[ $TYPE == parallels ]] && echo 6 || echo 5)
step() { STEP=$((STEP + 1)); ui_step "$STEP" "$STEPS" "$*"; }
BUILD_LOG=~/Library/Logs/omacvm-build-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$HOME/Library/Logs"
exec > >(tee -a "$BUILD_LOG") 2>&1
UI_LOG=$BUILD_LOG
build_end() {
  local rc=$?
  (( rc == 0 )) && return
  printf '\n\033[1;31mThe build stopped\033[0m in step %s of %s. The whole log:\n  open "%s"\n' "$STEP" "$STEPS" "$BUILD_LOG"
  printf 'Fix what it says and run omacvm again (a half-built VM can be deleted in %s first).\n' \
    "$(case $TYPE in (parallels) echo "Parallels Desktop" ;; (utm) echo UTM ;; (fusion) echo "VMware Fusion" ;; esac)"
}
trap 'build_end; ui_restore' EXIT

KEY=~/.ssh/omacvm
[[ -f $KEY ]] || { log "SSH key for the VM: $KEY"; mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")"; ssh-keygen -t ed25519 -N "" -C "omacvm" -f "$KEY" -q; }
export OMA_KEY=$KEY
started=$(date +%s)

# ---------- 2. temporary live installer + the real disk ----------
step "Temporary live installer (try-omarchy, about 1.4 GB download)"
if [[ $TYPE == parallels ]]; then
  info "Parallels Desktop may show its own windows on the way (sign in, continue the trial,"
  info "allow access): click through them, the build waits for the VM to start."
fi
if [[ $TYPE == parallels ]]; then
  "$R/src/vm/live/build-live.sh" --vm-name "$VM" --vm-dir "$VM_DIR" --root-size-gib 16 --skip-boot --ssh-key "$KEY.pub"
  PVM="$VM_DIR/$VM.pvm"
  "$PRLCTL" unregister "$VM" >/dev/null
  log "VM settings and a ${DISK_GB} GB NVMe disk"
  /usr/local/bin/prl_disk_tool create --hdd "$PVM/omarchy.hdd" --size "${DISK_GB}G" >/dev/null
  P="$R/src/vm/pvs.py"
  python3 "$P" "$PVM/config.pvs" omacvm --cpus "$CPUS" --memsize $((MEM_GB * 1024)) \
    --description "Omarchy (omarchy-mac) on Arch Linux ARM, built by OmacVM"
  python3 "$P" "$PVM/config.pvs" add-nvme omarchy.hdd $((DISK_GB * 1024)) >/dev/null
  python3 "$P" "$PVM/config.pvs" boot-from 0
  mkdir -p "$HOME/.local/share/omacvm/clip"
  python3 "$P" "$PVM/config.pvs" add-share vmlog "$PVM" ro                       # display layout (parallels.log)
  python3 "$P" "$PVM/config.pvs" add-share clip "$HOME/.local/share/omacvm/clip" rw     # clipboard VM -> Mac
  cp "$PVM/config.pvs" "$PVM/config.pvs.backup"
  "$PRLCTL" register "$PVM" >/dev/null
  vm_start "$VM" "$PVM"
  ui_spin_val IP "The live installer gets its address" vm_ip "$PVM" 300 || die "the live installer got no IP address"
elif [[ $TYPE == fusion ]]; then
  # The raw live image goes inside the VM's folder; Fusion reads it in place.
  LIVE="$(fusion_bundle "$VM").live.img"
  "$R/src/vm/live/build-live.sh" --root-size-gib 16 --raw-image "$LIVE" --ssh-key "$KEY.pub"
  log "VMware Fusion VM with a ${DISK_GB} GB NVMe disk"
  VMX=$(fusion_create "$VM" "$CPUS" $((MEM_GB * 1024)) "$LIVE" "$DISK_GB" "$GFX_GB")
  mv "$LIVE" "$(fusion_bundle "$VM")/live.img"; LIVE="$(fusion_bundle "$VM")/live.img"   # live.vmdk points here
  fusion_start "$VM"
  ui_spin_val IP "The live installer gets its address" fusion_ip "$VM" 300 || die "the live installer got no IP address"
else
  LIVE="$HOME/Library/Caches/omacvm/live/$VM-live.img"
  "$R/src/vm/live/build-live.sh" --root-size-gib 16 --raw-image "$LIVE" --ssh-key "$KEY.pub"
  utm_tune_app
  log "UTM VM with a ${DISK_GB} GB NVMe disk"
  pgrep -xq UTM || { open -a UTM; sleep 3; }
  utm_create "$VM" "$CPUS" $((MEM_GB * 1024)) "$LIVE" $((DISK_GB * 1024)) >/dev/null
  rm -f "$LIVE"
  utm_start "$VM"
  ui_spin_val IP "The live installer gets its address" utm_ip "$VM" 300 || die "the live installer got no IP address"
fi
ui_spin "Waiting for SSH on $IP" wait_ssh "$IP" || die "no SSH on $IP"

# ---------- 3. Arch Linux ARM onto the NVMe disk ----------
step "Arch Linux ARM onto the VM's disk ($IP)"
{
  printf 'OMA_USER=%q\nOMA_FULLNAME=%q\nOMA_HASH=%q\nOMA_TZ=%q\nOMA_LANG=%q\nOMA_HOSTNAME=%q\n' \
    "$U" "$FULL" "$HASH" "$TZ_MAC" "$LANG_VM" "$HOST"
  read -r l v <<<"$KB"; printf 'OMA_XKB_LAYOUT=%q\nOMA_XKB_VARIANT=%q\n' "$l" "${v:-}"
} | gssh "$IP" "umask 077; cat > /root/omacvm.env"
gssh "$IP" "cat > /root/omacvm.pub" < "$KEY.pub"
gssh "$IP" "bash -s" < "$R/src/vm/base-install.sh" 2>&1 | ui_follow "Arch Linux ARM onto the disk"
gssh "$IP" "systemctl poweroff" 2>/dev/null || true

step "Booting from the new disk"
if [[ $TYPE == utm ]]; then
  ui_spin "The live installer shuts down" utm_wait_stopped "$VM"
  utm_drop_live "$VM"
  utm_set_icon "$VM"
  utm_start "$VM"
  sleep 20
  ui_spin_val IP "The new system starts and gets its address" utm_ip "$VM" 300 || die "the new system got no IP address"
elif [[ $TYPE == fusion ]]; then
  ui_spin "The live installer shuts down" fusion_wait_stopped "$VM"
  fusion_drop_live "$VM"
  rm -f "$LIVE"
  fusion_start "$VM"
  sleep 20
  ui_spin_val IP "The new system starts and gets its address" fusion_ip "$VM" 300 || die "the new system got no IP address"
else
ui_spin "The live installer shuts down" wait_stopped "$VM"
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
ui_spin_val IP "The new system starts and gets its address" vm_ip "$PVM" 300 || die "the new system got no IP address"
fi
ui_spin "Waiting for SSH on $IP" wait_ssh "$IP" || die "no SSH on $IP"

# ---------- 4. Omarchy + Parallels Tools ----------
step "Omarchy from omarchy-mac (the longest step)"
[[ $TYPE == fusion ]] && gssh "$IP" "bash -s" < "$R/src/fusion/guest/dns.sh"   # Fusion's own DNS fails the install
gssh "$IP" "OMARCHY_MAC_CHANNEL=$CHANNEL bash -s" < "$R/src/vm/omarchy-install.sh" 2>&1 | ui_follow "Installing Omarchy (20-40 minutes)"
if [[ $TYPE == parallels ]]; then
  step "Parallels Tools"
  gssh "$IP" "cat > /root/prl-tools-lin-arm.iso" < "/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin-arm.iso"
  gssh "$IP" "set -e; mkdir -p /mnt/tools; mount -o loop,ro /root/prl-tools-lin-arm.iso /mnt/tools
    /mnt/tools/installer/install-cli.sh --install >/dev/null 2>&1 || /mnt/tools/installer/install-cli.sh --install
    umount /mnt/tools; rm -f /root/prl-tools-lin-arm.iso"
fi
gssh "$IP" "rm -f /root/omacvm.env"   # it holds the password hash

# ---------- 5. OmacVM ----------
step "OmacVM: the Mac side, then the VM side"
args=(--vm "$VM" --vm-type "$TYPE" --ip "$IP" --user "$U" --keyboard "$KB")
for ((k = 0; k < ${#FEATS[@]}; k += 2)); do
  args+=(--feature "${FEATS[$k]}=$( ((FEATS[k+1])) && echo on || echo off)")
done
"$R/src/cmd/apply.sh" "${args[@]}"
gssh "$IP" "systemctl reboot" 2>/dev/null || true

mac_steps=$(human_steps | sed 's/^/    * /')
cat <<EOF

  Done in $(( ($(date +%s) - started) / 60 )) minutes. VM '$VM' ($TYPE) is rebooting into Omarchy.

  One-time steps on the Mac:
$mac_steps
  In full screen, the trackpad and ⌘ shortcuts belong to Omarchy.
  ${UB}⌃⌥⌘ Esc (Control + Option + Command + Escape) gives them back to macOS.${UR}

  SSH: ssh -i "$KEY" root@$IP
  Check everything: omacvm check --vm "$VM"
  Switch features later: omacvm features --vm "$VM"
EOF
