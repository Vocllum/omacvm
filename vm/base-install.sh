#!/bin/bash
# Install Arch Linux ARM onto the VM's NVMe disk. Runs as root in the live
# installer (build.sh copies it there with /root/omaparallels.env):
#   OMA_USER OMA_FULLNAME OMA_HASH OMA_TZ OMA_LANG OMA_XKB_LAYOUT OMA_XKB_VARIANT OMA_HOSTNAME
# plus /root/omaparallels.pub (SSH key for root, used by build.sh).
#
# Layout: GPT, 2 GiB EFI (/boot) + btrfs with @, @home, @log (omarchy-mac adds
# @factory and snapper); zstd:1, noatime, async discard. GRUB, because
# omarchy-mac's snapshot restore/reset tooling expects it.
set -euo pipefail
source /root/omaparallels.env
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

D=$(lsblk -dnpo NAME,TRAN | awk '$2 == "nvme" { print $1; exit }')
[[ -b ${D:-} ]] || { echo "base-install: no NVMe disk found" >&2; exit 1; }
P=${D}p

log "tools for the install"
pacman -Sy --noconfirm --needed arch-install-scripts dosfstools btrfs-progs gptfdisk >/dev/null

log "fastest Arch Linux ARM mirrors from here"
# The geo-DNS default can send you across the world and time out; rank a few
# mirrors by how fast they serve the core database, keep the default last.
ranked=$(for m in de3 de4 dk hu nl fl.us ca.us nj.us il.us tx.us sg tw au br za; do
  t=$(curl -o /dev/null -s -w '%{time_total}' --max-time 6 "https://$m.mirror.archlinuxarm.org/aarch64/core/core.db") &&
    printf '%s %s\n' "$t" "$m"
done | sort -n | head -4 | awk '{ print $2 }')
{
  for m in $ranked; do echo "Server = https://$m.mirror.archlinuxarm.org/\$arch/\$repo"; done
  echo 'Server = http://mirror.archlinuxarm.org/$arch/$repo'
} > /etc/pacman.d/mirrorlist
cat /etc/pacman.d/mirrorlist

log "partitions on $D"
sgdisk --zap-all "$D" >/dev/null
sgdisk -n1:1MiB:+2GiB -t1:ef00 -c1:EFI -n2:0:0 -t2:8300 -c2:omarchy "$D" >/dev/null
partprobe "$D"; sleep 1
mkfs.fat -F32 -n OMARCHYEFI "${P}1" >/dev/null
mkfs.btrfs -f -L omarchy "${P}2" >/dev/null
mount "${P}2" /mnt
for s in @ @home @log; do btrfs subvolume create "/mnt/$s" >/dev/null; done
umount /mnt
O=noatime,compress=zstd:1,space_cache=v2,discard=async
mount -o "$O,subvol=@" "${P}2" /mnt
mkdir -p /mnt/home /mnt/var/log /mnt/boot
mount -o "$O,subvol=@home" "${P}2" /mnt/home
mount -o "$O,subvol=@log" "${P}2" /mnt/var/log
mount -o umask=0077 "${P}1" /mnt/boot

log "pacstrap"
cat > /root/pacman.alarm.conf <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
CheckSpace
ParallelDownloads = 8
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
[alarm]
Include = /etc/pacman.d/mirrorlist
[aur]
Include = /etc/pacman.d/mirrorlist
EOF
pacstrap -C /root/pacman.alarm.conf /mnt base base-devel linux-aarch64 linux-aarch64-headers archlinuxarm-keyring \
  btrfs-progs dosfstools grub efibootmgr openssh sudo git networkmanager nano vim man-db 2>&1 | tail -3
cp /root/pacman.alarm.conf /mnt/etc/pacman.conf
sed -i 's/^\[options\]/[options]\nColor\nVerbosePkgLists/' /mnt/etc/pacman.conf
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
genfstab -U /mnt > /mnt/etc/fstab

log "base system: $OMA_TZ, $OMA_LANG, keyboard $OMA_XKB_LAYOUT${OMA_XKB_VARIANT:+ ($OMA_XKB_VARIANT)}, user $OMA_USER"
install -m600 /root/omaparallels.env /mnt/root/omaparallels.env
install -m600 /root/omaparallels.pub /mnt/root/omaparallels.pub
cat > /mnt/root/setup-base.sh <<'EOF'
set -euo pipefail
source /root/omaparallels.env
ln -sf "/usr/share/zoneinfo/$OMA_TZ" /etc/localtime
hwclock --systohc 2>/dev/null || true
grep -q "^${OMA_LANG} " /usr/share/i18n/SUPPORTED || OMA_LANG=en_US.UTF-8
sed -i "s/^#en_US.UTF-8/en_US.UTF-8/; s/^#${OMA_LANG}/${OMA_LANG}/" /etc/locale.gen
locale-gen >/dev/null
echo "LANG=$OMA_LANG" > /etc/locale.conf
# Console keymap: systemd's own X11 -> console table.
keymap=$(awk -v l="$OMA_XKB_LAYOUT" -v v="${OMA_XKB_VARIANT:-}" \
  '!/^#/ && $2 == l && ($4 == v || (v == "" && $4 == "-")) { print $1; exit }' /usr/share/systemd/kbd-model-map)
echo "KEYMAP=${keymap:-us}" > /etc/vconsole.conf
echo "$OMA_HOSTNAME" > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$OMA_HOSTNAME" "$OMA_HOSTNAME" > /etc/hosts
pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinuxarm >/dev/null 2>&1
useradd -m -G wheel -s /bin/bash -c "$OMA_FULLNAME" "$OMA_USER"
usermod -p "$OMA_HASH" "$OMA_USER"
passwd -l root >/dev/null
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel; chmod 440 /etc/sudoers.d/10-wheel
install -d -m700 /root/.ssh; install -m600 /root/omaparallels.pub /root/.ssh/authorized_keys
cat > /etc/ssh/sshd_config.d/10-omaparallels.conf <<EOT
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOT
systemctl enable NetworkManager sshd systemd-timesyncd fstrim.timer >/dev/null 2>&1
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/; s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet mitigations=off nowatchdog"/; s/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
grub-install --target=arm64-efi --efi-directory=/boot --bootloader-id=GRUB 2>&1 | tail -1
grub-install --target=arm64-efi --efi-directory=/boot --removable 2>&1 | tail -1
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -1
rm /root/omaparallels.pub
EOF
arch-chroot /mnt bash /root/setup-base.sh
rm -f /mnt/root/setup-base.sh
sync; umount -R /mnt
log "base system installed on $D"
