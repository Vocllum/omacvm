#!/bin/bash
# The Mac's camera in Omarchy, guest side. Run as root inside the VM:
#   ./install.sh <desktop-user> <vm-type> on|off
# UTM, VMware Fusion and OmacVM.app: /dev/video42 "Mac Camera" (v4l2loopback,
# built by DKMS for each kernel), fed by the user service omacvm-camera from
# the Bridge (UTM, Fusion) or the app's virtio port, only while an app reads it.
# Parallels passes the Mac's camera itself: nothing to install there.
# off: the service, the module and our files go; the packages stay.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> <vm-type> on|off}; TYPE=${2:?vm type}; ON=${3:?on or off}
user_ctl() { systemctl --user -M "$U@" "$@"; }
FILES=(/etc/systemd/user/omacvm-camera.service /usr/local/bin/omacvm-camera /etc/modprobe.d/90-omacvm-camera.conf
       /etc/modules-load.d/90-omacvm-camera.conf /etc/udev/rules.d/70-omacvm-camera.rules)

if [[ $ON != on || $TYPE == parallels ]]; then
  [[ -e /usr/local/bin/omacvm-camera ]] || exit 0
  systemctl --global disable omacvm-camera.service >/dev/null 2>&1 || true
  user_ctl stop omacvm-camera.service 2>/dev/null || true
  systemctl --user -M root@ stop omacvm-camera.service >/dev/null 2>&1 || true
  rm -f "${FILES[@]}"
  rmmod v4l2loopback 2>/dev/null || true
  echo "camera: off"
  exit 0
fi

# v4l2loopback is built by DKMS against the headers of each installed kernel.
# Arch Linux ARM's headers must be the kernel's own version: from the
# repository when it has that version, else from pacman's cache (as
# battery/guest/install.sh, from try-omarchy). The memory-optimized kernel
# brings its own (kernel/build-thp-kernel.sh).
pacman -S --needed --noconfirm python dkms >/dev/null 2>&1
headers() {   # KERNEL_PACKAGE
  local k=$1 have want f
  have=$(pacman -Q "$k" 2>/dev/null | awk '{ print $2 }') || return 0
  [[ -n $have ]] || return 0
  [[ $(pacman -Q "$k-headers" 2>/dev/null | awk '{ print $2 }') == "$have" ]] && return 0
  want=$(pacman -Si "$k-headers" 2>/dev/null | awk '/^Version/ { print $3; exit }') || true
  if [[ $want == "$have" ]]; then
    pacman -S --needed --noconfirm "$k-headers" >/dev/null 2>&1 && return 0
  fi
  f=$(ls /var/cache/pacman/pkg/"$k-headers-$have"-*.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | head -1) || true
  [[ -n $f ]] && pacman -U --noconfirm "$f" >/dev/null 2>&1 && return 0
  echo "camera: no $k-headers $have to build v4l2loopback with (Arch Linux ARM has ${want:-none}): omarchy update, reboot, then omacvm apply" >&2
}
headers linux-aarch64
pacman -S --needed --noconfirm v4l2loopback-dkms >/dev/null 2>&1
# Headers that came after the module (or a new kernel): build it for them too.
[[ -n $(modinfo -k "$(uname -r)" -F filename v4l2loopback 2>/dev/null) ]] ||
  dkms autoinstall -k "$(uname -r)" >/dev/null 2>&1 || true
install -Dm644 90-omacvm-camera.conf /etc/modprobe.d/90-omacvm-camera.conf
echo v4l2loopback | install -Dm644 /dev/stdin /etc/modules-load.d/90-omacvm-camera.conf
install -Dm644 70-omacvm-camera.rules /etc/udev/rules.d/70-omacvm-camera.rules
install -m755 omacvm-camera /usr/local/bin/
install -m644 omacvm-camera.service /etc/systemd/user/
usermod -aG video "$U"
udevadm control --reload 2>/dev/null || true

# Loaded with our options (another loopback device would take /dev/video42's place).
if [[ ! -e /sys/class/video4linux/video42 ]] && lsmod | grep -q '^v4l2loopback '; then
  rmmod v4l2loopback 2>/dev/null || true
fi
if ! modprobe v4l2loopback 2>/dev/null; then
  if [[ -z $(modinfo -k "$(uname -r)" -F filename v4l2loopback 2>/dev/null) ]]; then
    echo "camera: no v4l2loopback for the running kernel $(uname -r) (headers for another one?): reboot after the next kernel update, then omacvm apply" >&2
  fi
fi
udevadm trigger --subsystem-match=video4linux --subsystem-match=virtio-ports 2>/dev/null || true

systemctl --global enable omacvm-camera.service >/dev/null 2>&1
# root's own manager (an SSH login) may run one from before ConditionUser.
systemctl --user -M root@ stop omacvm-camera.service >/dev/null 2>&1 || true
if user_ctl daemon-reload 2>/dev/null; then
  user_ctl restart omacvm-camera.service 2>/dev/null || true
fi
echo "camera: /dev/video42 (Mac Camera)$( [[ -e /sys/class/video4linux/video42 ]] || echo ", after a reboot")"
