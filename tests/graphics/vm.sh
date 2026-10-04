#!/bin/bash
# vm.sh start|stop|ssh|session ...: drive one app test VM for the graphics suites.
# Env: VM (name, default "OmacVM T-conf"), RT (runtime dir), PORT (ssh, 52291),
#      GUSER (guest desktop user, gilles), KEY (~/.ssh/omacvm), CPUS (6), MEM_MB (8192),
#      GPUX (extra virtio-gpu options, e.g. ",blob=true,venus=true,hostmem=4G").
set -u
VM=${VM:-OmacVM T-conf}; PORT=${PORT:-52291}; GUSER=${GUSER:-gilles}; KEY=${KEY:-$HOME/.ssh/omacvm}
RT=${RT:-/Users/gillesgoetsch/omacvm-rc/app/runtime/.build/qemu-gpu-runtime}
D="$HOME/Library/Application Support/OmacVM/VMs/$VM"
RUN=$(getconf DARWIN_USER_TEMP_DIR)omacvm-${VM// /_}
SSH=(ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)

qpid() { pgrep -f "qemu-system-aarch64 -name $VM -machine" | head -1; }

case ${1:-} in
start)
  [ -n "$(qpid)" ] && { echo "already running"; exit 0; }
  FW=$(dirname "$RT")/firmware/edk2-aarch64-code.fd
  mkdir -p "$RUN" "$D/logs"
  OMACVM_PRODUCT_NAME="$VM" OMACVM_NOTCH=0 nohup "$RT/bin/qemu-system-aarch64" -name "$VM" \
    -machine virt,gic-version=3 -accel hvf -cpu host,pmu=off -smp "${CPUS:-6}" -m "${MEM_MB:-8192}M" -nodefaults \
    -action reboot=reset,shutdown=poweroff \
    -drive "if=pflash,format=raw,readonly=on,file=$FW" -drive "if=pflash,format=raw,file=$D/efi-vars.fd" \
    -drive "if=none,id=disk,file=$D/disk.img,format=raw,cache=writeback,discard=unmap" \
    -device nvme,serial=omacvm,drive=disk,bootindex=0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
    -device "virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,romfile=${GPUX:-}" \
    -display cocoa,gl=on,show-cursor=on,zoom-to-fit=on,full-screen=off \
    -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
    -msg timestamp=on -serial none -monitor none -qmp "unix:$RUN/qmp,server=on,wait=off" \
    > "$D/logs/qemu-graphics.log" 2>&1 &
  sleep 2; [ -z "$(qpid)" ] && { echo "QEMU exited"; tail -5 "$D/logs/qemu-graphics.log"; exit 1; }
  for _ in $(seq 120); do
    "${SSH[@]}" "ls /run/user/1000/hypr/*/.socket.sock" >/dev/null 2>&1 && { echo "session up"; exit 0; }
    [ -z "$(qpid)" ] && { echo "QEMU exited"; tail -5 "$D/logs/qemu-graphics.log"; exit 1; }
    sleep 3
  done
  echo "timeout waiting for the session"; exit 1 ;;
stop)
  "${SSH[@]}" systemctl poweroff >/dev/null 2>&1
  for _ in $(seq 60); do [ -z "$(qpid)" ] && exit 0; sleep 1; done
  kill "$(qpid)" 2>/dev/null; exit 0 ;;
pid) qpid ;;
log) echo "$D/logs/qemu-graphics.log" ;;
ssh) shift; exec "${SSH[@]}" "$@" ;;
session)
  shift; q=$(printf '%q ' "$@")
  exec "${SSH[@]}" "SIG=\$(ls -t /run/user/1000/hypr | head -1); cd /tmp; sudo -u $GUSER env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=\$SIG $q" ;;
*) echo "usage: vm.sh start|stop|pid|log|ssh CMD|session CMD"; exit 2 ;;
esac
