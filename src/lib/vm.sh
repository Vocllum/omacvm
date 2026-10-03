# Finding and reaching VMs from the Mac (sourced after mac.sh; bash 3.2).
#   vms_list                 one line per VM: NAME<TAB>parallels|utm|fusion<TAB>running|stopped|...
#                            (Parallels' and UTM's other states as they name them)
#   vm_find_ip NAME TYPE [s] the VM's address (waits up to s seconds)
#   vm_probe IP              what the VM says about itself, as KEY=value lines:
#                            OMACVM_USER, OMACVM_VERSION (empty: no OmacVM yet),
#                            /etc/omacvm/env (OMACVM_VM_TYPE, OMACVM_FEATURE_*)
#   vm_boot NAME TYPE        start a stopped VM and wait for its address

UTM_PREFS=$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist

vms_list() {
  if [[ -x $PRLCTL ]]; then
    "$PRLCTL" list -a -o status,name 2>/dev/null | awk 'NR > 1 { s = $1; $1 = ""; sub(/^ /, ""); print $0 "\tparallels\t" s }'
  fi
  if [[ -x $UTMCTL ]] && pgrep -xq UTM; then
    "$UTMCTL" list 2>/dev/null | awk 'NR > 1 { s = $2; $1 = ""; $2 = ""; sub(/^  /, ""); print $0 "\tutm\t" (s == "started" ? "running" : s) }'
  elif [[ -f $UTM_PREFS ]]; then
    # UTM not running (utmctl would start it): its VMs, wherever they are, from
    # UTM's registry; all stopped.
    python3 - "$UTM_PREFS" <<'PY' 2>/dev/null
import os, plistlib, sys
for entry in plistlib.load(open(sys.argv[1], "rb")).get("Registry", {}).values():
    path = (entry.get("Package") or {}).get("Path", "")
    if not os.path.isdir(path):
        continue
    try:
        name = plistlib.load(open(os.path.join(path, "config.plist"), "rb"))["Information"]["Name"]
    except Exception:
        name = os.path.basename(path)[:-4]
    print(f"{name}\tutm\tstopped")
PY
  fi
  local n x
  while IFS=$'\t' read -r n x; do
    [[ -n $n ]] && printf '%s\tfusion\t%s\n' "$n" "$(fusion_state "$n")"
  done < <(fusion_list)
}

vm_find_ip() {   # NAME TYPE [seconds]
  case $2 in
    parallels) vm_ip "$(vm_bundle "$1")" "${3:-1}" ;;
    utm) utm_ip "$1" "${3:-1}" ;;
    fusion) fusion_ip "$1" "${3:-1}" ;;
    *) return 1 ;;
  esac
}

vm_probe() {
  gssh "$1" 'U=$(getent passwd 1000 | cut -d: -f1); H=$(getent passwd 1000 | cut -d: -f6)
    echo "OMACVM_USER=$U"
    echo "OMACVM_VERSION=$(cat /usr/local/share/omacvm/VERSION 2>/dev/null || { [ -r /etc/omacvm/env ] && echo 1.x; })"
    cat /etc/omacvm/env 2>/dev/null
    # set up before the choices were kept
    grep -q "^OMACVM_FEATURE_omanotch=" /etc/omacvm/env 2>/dev/null || { [ -x "$H/.local/bin/notchcast" ] && echo OMACVM_FEATURE_omanotch=on; }
    grep -q "^OMACVM_FEATURE_autologin=" /etc/omacvm/env 2>/dev/null || { [ -f /etc/sddm.conf.d/20-omacvm-autologin.conf ] && echo OMACVM_FEATURE_autologin=on; }
    grep -q "^OMACVM_FEATURE_thp_kernel=" /etc/omacvm/env 2>/dev/null || { pacman -Q linux-aarch64-thp >/dev/null 2>&1 && echo OMACVM_FEATURE_thp_kernel=on; }
    true' < /dev/null 2>/dev/null
}

vm_boot() {   # NAME TYPE
  case $2 in
    parallels) vm_start "$1" "$(vm_bundle "$1")" >&2; vm_ip "$(vm_bundle "$1")" 300 ;;
    utm) utm_start "$1" >&2; utm_ip "$1" 300 ;;
    fusion) fusion_start "$1" >&2; fusion_ip "$1" 300 ;;
    *) return 1 ;;
  esac
}

# The SSH access OmacVM needs, for a VM that was not built by OmacVM (an
# Omarchy installed by hand from omarchy-mac): one command to run in the VM.
ssh_setup_command() {
  local net h
  case $1 in
    parallels) net=10.211.55.0/24 ;;
    utm) net=192.168.64.0/24 ;;
    fusion) h=$(fusion_host) || return 1; net=${h%.*}.0/24 ;;
  esac
  printf "sudo bash -c 'install -d -m700 /root/.ssh && echo \"%s\" >> /root/.ssh/authorized_keys && pacman -S --needed --noconfirm openssh >/dev/null && systemctl enable --now sshd && { ufw allow from %s to any port 22 proto tcp comment \"omacvm: ssh from the Mac\" || true; }'" \
    "$(cat "${OMA_KEY:-$HOME/.ssh/omacvm}.pub")" "$net"
}

# resolve_vm [start]: VM (name) -> TYPE and IP. No name: "Omarchy", else the
# only running VM. With "start", a stopped VM is started; without, IP stays
# empty for it. Exits 2 when it cannot tell which VM.
resolve_vm() {
  local running
  if [[ -z ${VM:-} ]]; then
    if vms_list | cut -f1 | grep -qxF Omarchy; then VM=Omarchy
    else
      running=$(vms_list | awk -F'\t' '$3 == "running" { print $1 }')
      if [[ $(grep -c . <<<"$running") == 1 ]]; then VM=$running
      else
        echo "omacvm: which VM? pass --vm NAME (your VMs: $(vms_list | cut -f1 | paste -sd, - | sed 's/,/, /g'))" >&2
        exit 2
      fi
    fi
  fi
  [[ -n ${TYPE:-} ]] || TYPE=$(vm_type "$VM") || { echo "omacvm: no Parallels, UTM or VMware Fusion VM named '$VM'" >&2; exit 2; }
  IP=""
  # DHCP leases outlive a stopped VM: only a running one has an address.
  if vms_list | awk -F'\t' -v n="$VM" -v t="$TYPE" '$1 == n && $2 == t && $3 == "running" { f = 1 } END { exit !f }'; then
    IP=$(vm_find_ip "$VM" "$TYPE" 30 2>/dev/null) || IP=""
  fi
  if [[ -z $IP && ${1:-} == start ]]; then
    log "starting '$VM'" >&2
    IP=$(vm_boot "$VM" "$TYPE") || die "'$VM' did not get an address"
    wait_ssh "$IP" 300
  fi
}

# vm_type NAME -> parallels | utm | fusion (replaces mac.sh's, without starting UTM); a
# name in both: the running one, else a usable one (Parallels first), and an
# "invalid" Parallels VM (its files are gone) last.
vm_type() {
  vms_list | awk -F'\t' -v n="$1" '
    $1 == n { if ($3 == "running") run = $2
              else if ($3 == "invalid") bad = $2
              else if (!any || $2 == "parallels") any = $2 }
    END { if (run) print run; else if (any) print any; else if (bad) print bad; else exit 1 }'
}
