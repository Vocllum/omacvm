#!/bin/bash
# A new OmacVM.app VM from a prebuilt image instead of building it: a few
# minutes plus the download. The same contract as create-vm.sh (the app runs
# one or the other):
#
#   prebuilt-vm.sh VM_DIR     the password on stdin (one line)
#   prebuilt-vm.sh --lookup   is there an image for this version? Prints
#                             "TAG BYTES OMARCHY_VERSION" (exit 1: none)
#
# VM_DIR/vm.env as for create-vm.sh. Progress lines start with "==>", steps
# with "STEP n/N". Exit 0 = the VM is ready and powered off. With no image for
# this OmacVM version (or no connection) it builds the VM with create-vm.sh
# instead and says so. OMACVM_CREATE_NO_MAC=1: without the Mac helpers.
# OMACVM_PREBUILT_SOURCE=DIR: an image from a folder (tests, see docs/prebuilt.md).
#
# How: the image's parts are downloaded and each checked against the
# manifest's SHA-256 (src/prebuilt/lib.sh, as for omacvm build --prebuilt),
# unpacked (disk.img stays sparse) and grown to DISK_GB. A small ISO labelled
# OMACVM-SEED carries the answers: user, full name, password hash, the SSH key
# for root, hostname, keyboard, timezone, language. The VM's first boot
# (omacvm-firstboot.service) applies them, without a window. Then OmacVM is
# applied as after a build, the VM shuts down and the seed is deleted.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
R=$(cd "$OMACVM_SRC/.." && pwd)
info() { log "$*"; }
source "$OMACVM_SRC/prebuilt/lib.sh"

if [[ ${1:-} == --lookup ]]; then
  prebuilt_lookup app 2>/dev/null || exit 1
  echo "$PB_TAG $PB_SIZE ${PB_OMARCHY%% *}"
  exit 0
fi

VM_DIR=${1:?usage: prebuilt-vm.sh VM_DIR | --lookup}
vm_load "$VM_DIR"
IFS= read -r PASSWORD || true
[[ -n $PASSWORD ]] || die "no password on stdin"
# OmacVM's Mac helpers and the clock format are built with Apple's tools.
clt_ok || die "Xcode's Command Line Tools are missing: run xcode-select --install, then build again"
[[ ! -e $VM_DIR/disk.img ]] || die "$VM_DIR already has a disk"

STEPS=7
step() { echo "STEP $1/$STEPS $2"; }
SEED=$VM_DIR/seed.iso
# The seed holds the password hash: gone however this ends.
trap 'qemu_running && qemu_quit; rm -f "$SEED"; rm -rf "$VM_DIR/.unpack"' EXIT

# ---------- 1. which image ----------
step 1 "Looking for a prebuilt VM"
if ! prebuilt_lookup app 2>/dev/null; then
  log "no prebuilt VM for OmacVM $(cat "$R/src/VERSION") (or no connection): building it here instead"
  trap - EXIT
  printf '%s\n' "$PASSWORD" | /bin/bash "$HERE/create-vm.sh" "$VM_DIR"
  exit 0
fi
log "release $PB_TAG: Omarchy $PB_OMARCHY, OmacVM $PB_VERSION"
HASH=$(printf '%s' "$PASSWORD" | python3 "$OMACVM_SRC/prebuilt/sha512crypt.py") || die "could not hash the password"
[[ $HASH == '$6$'* ]] || die "could not hash the password"
unset PASSWORD

# ---------- 2. download ----------
step 2 "Downloading the prebuilt VM ($(pb_gb "$PB_SIZE") GB)"
t0=$(date +%s)
prebuilt_download
log "downloaded and checked in $(( $(date +%s) - t0 )) s"

# ---------- 3. unpack ----------
step 3 "Unpacking the VM"
t0=$(date +%s)
prebuilt_unpack "$VM_DIR/.unpack"
[[ -f $VM_DIR/.unpack/$PB_BUNDLE/disk.img ]] || die "the image has no disk.img"
mv "$VM_DIR/.unpack/$PB_BUNDLE/disk.img" "$VM_DIR/disk.img"
rm -rf "$VM_DIR/.unpack"
prebuilt_cleanup
# The image's disk is the smallest the app offers; the first boot grows the
# file system into the rest.
(( DISK_GB > PB_DISK_GB )) && truncate_file "$VM_DIR/disk.img" $((DISK_GB * 1024 * 1024 * 1024))
efi_vars_create
# The answers for the first boot. QEMU's user network: SSH arrives from 10.0.2.2.
U=$VM_USER FULL=${VM_FULLNAME:-$VM_USER} HOST=${VM_HOSTNAME:-omarchy} KB=${KEYBOARD:-us}
TZ_MAC=${VM_TZ:-UTC} LANG_VM=${VM_LANG:-en_US.UTF-8} TYPE=app SEED_NET=10.0.2.0/24
prebuilt_seed "$SEED"
unset HASH
log "unpacked in $(( $(date +%s) - t0 )) s ($(du -sh "$VM_DIR/disk.img" | cut -f1) on disk)"

# ---------- 4. first boot ----------
step 4 "First boot: your user, keys, keyboard and timezone"
t0=$(date +%s)
qemu_headless firstboot "${QEMU_UEFI[@]}" \
  -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0 \
  -drive "if=none,id=seed,file=$(qe "$SEED"),format=raw,readonly=on" -device virtio-blk-pci,drive=seed
# The first boot puts the Mac's key in for root early on: SSH answers while it
# still sets up the user. Without the seed it would wait on its console.
wait_ssh 600 || die "the VM did not answer on SSH (log: $LOG/firstboot-console.log)"
for ((i = 0; i < 300; i += 3)); do
  vssh "test -e /var/lib/omacvm/prebuilt/pending" < /dev/null 2>/dev/null || break
  vssh "systemctl is-failed -q omacvm-firstboot" < /dev/null 2>/dev/null &&
    die "the first boot failed: $(vssh "tail -3 /var/log/omacvm-firstboot.log" < /dev/null 2>/dev/null | tr '\n' ' ')"
  sleep 3
done
vssh "test ! -e /var/lib/omacvm/prebuilt/pending" < /dev/null || die "the first boot did not finish in 5 minutes"
vssh "sed 's/\x1b\[[0-9;]*m//g' /var/log/omacvm-firstboot.log | grep '^==>'" < /dev/null 2>/dev/null || true
log "first boot done in $(( $(date +%s) - t0 )) s"

# ---------- 5. OmacVM in the VM ----------
step 5 "Adding OmacVM to the VM"
# New host keys from the first boot: forget an earlier VM's of this name.
OMA_PIN_RESET=1 run_logged "$LOG/omacvm-install.log" "$HERE/apply-vm.sh" "$VM_DIR" --no-mac ||
  die "OmacVM did not install (log: $LOG/omacvm-install.log)"
touch "$VM_DIR/ready"

# ---------- 6. OmacVM on the Mac ----------
step 6 "Adding OmacVM's helpers on the Mac"
if [[ ${OMACVM_CREATE_NO_MAC:-} == 1 ]]; then
  echo "==> Mac helpers skipped (OMACVM_CREATE_NO_MAC=1)"
else
  run_logged "$LOG/omacvm-mac.log" "$HERE/apply-vm.sh" "$VM_DIR" ||
    echo "WARN: the Mac helpers did not install (log: $LOG/omacvm-mac.log); the VM works without them"
fi

# ---------- 7. done ----------
step 7 "Shutting down"
vssh "systemctl poweroff" < /dev/null 2>/dev/null || true
qemu_wait_exit 120 || qemu_quit
rm -f "$SEED"
echo "READY $NAME"
