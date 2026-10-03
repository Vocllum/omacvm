#!/bin/bash
# Arch Linux ARM's own kernel (linux-aarch64) is /boot/Image. GRUB lists it
# but finds no initramfs for that name, and grub-btrfs (the snapshots menu)
# does not see it at all. So the VM booted without its initramfs (no
# Plymouth, no overlay for read-only snapshots) and, without the
# memory-optimized kernel, GRUB had no snapshots menu. A copy named
# /boot/vmlinuz-linux pairs with /boot/initramfs-linux.img in both; a pacman
# hook keeps it in step with the package.
# Run as root inside the VM: ./stock-kernel.sh
set -euo pipefail
[[ -f /boot/Image ]] || exit 0
# /boot is FAT: no chmod, so cp (not install -m), then one rename.
copy='cp /boot/Image /boot/vmlinuz-linux.omacvm && mv -f /boot/vmlinuz-linux.omacvm /boot/vmlinuz-linux'
cmp -s /boot/Image /boot/vmlinuz-linux 2>/dev/null || bash -c "$copy"
install -Dm644 /dev/stdin /etc/pacman.d/hooks/zz-omacvm-stock-kernel.hook <<EOF
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = boot/Image

[Action]
Description = OmacVM: Arch Linux ARM's kernel as /boot/vmlinuz-linux for GRUB
When = PostTransaction
Exec = /bin/sh -c '$copy'
EOF
install -Dm644 /dev/stdin /etc/pacman.d/hooks/zz-omacvm-stock-kernel-remove.hook <<'EOF'
[Trigger]
Type = Path
Operation = Remove
Target = boot/Image

[Action]
Description = OmacVM: remove /boot/vmlinuz-linux
When = PostTransaction
Exec = /bin/rm -f /boot/vmlinuz-linux
EOF
