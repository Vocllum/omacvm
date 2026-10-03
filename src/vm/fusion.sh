# VMware Fusion route helpers for build.sh (sourced, Mac side, after mac.sh).
# Fusion's own tools do the work: vmcli creates the VM, vmware-vdiskmanager its
# disk, vmrun starts it; the rest is the .vmx, a plain `key = "value"` file.
# VMs go to Fusion's default folder, or $OMACVM_FUSION_DIR (fusion_bundle, mac.sh).

vmx_set() {   # <vmx> <key> <value>: set or add one line
  local tmp
  tmp=$(mktemp)
  awk -v k="$2" -v v="$3" 'BEGIN { line = k " = \"" v "\"" }
    $1 == k && $2 == "=" { if (!done) print line; done = 1; next } { print } END { if (!done) print line }' "$1" > "$tmp"
  cat "$tmp" > "$1"; rm -f "$tmp"
}

vmx_del() { sed -i '' "/^$(sed 's/\./\\./g' <<<"$2")/d" "$1"; }   # <vmx> <key prefix>: drop those lines

# fusion_mac_displays -> "COUNT WIDTH HEIGHT": the Mac's displays and the
# pixel size of their whole arrangement (at least 2560x1600, Fusion's default).
fusion_mac_displays() {
  swift -e 'import AppKit
    let s = NSScreen.screens
    let px = s.map { $0.frame.applying(CGAffineTransform(scaleX: $0.backingScaleFactor, y: $0.backingScaleFactor)) }
    let w = Int(px.map { $0.maxX }.max()! - px.map { $0.minX }.min()!), h = Int(px.map { $0.maxY }.max()! - px.map { $0.minY }.min()!)
    print(s.count, max(w, 2560), max(h, 1600))' 2>/dev/null || echo "1 2560 1600"
}

# fusion_create NAME CPUS MEMORY_MB LIVE_IMAGE DISK_GB
# Like the VM the Fusion route was tested with: UEFI, 3D acceleration on the
# vmwgfx GPU, an Intel e1000e NIC on Fusion's NAT network (Arch Linux ARM's
# kernel has no vmxnet3), the live installer as a SATA disk and the system
# disk as NVMe (the base install takes the one NVMe disk). The live image stays
# a raw file: a "monolithicFlat" descriptor points Fusion at it.
fusion_create() {
  local name=$1 cpus=$2 mem=$3 live=$4 disk=$5 b x sectors
  b=$(fusion_bundle "$name")
  [[ -e $b ]] && die "$b already exists"
  mkdir -p "$b"
  "$FUSION_LIB/vmcli" VM Create -n "$name" -d "$b" -c arm-other6xlinux-64 >/dev/null || die "vmcli could not create the VM"
  x="$b/$name.vmx"
  [[ -f $x ]] || die "vmcli made no $x"
  rm -f "$b/$name.vmdk"
  vmx_set "$x" displayName "$name"
  vmx_set "$x" numvcpus "$cpus"
  vmx_set "$x" memsize "$mem"
  vmx_del "$x" memory.maxsize
  vmx_set "$x" firmware efi
  vmx_set "$x" mks.enable3d TRUE
  vmx_set "$x" svga.graphicsMemoryKB 4194304
  vmx_set "$x" annotation "Omarchy (omarchy-mac) on Arch Linux ARM, built by OmacVM"
  "$FUSION_LIB/vmware-vdiskmanager" -c -s "${disk}GB" -a lsilogic -t 0 "$b/omarchy.vmdk" >/dev/null || die "vmware-vdiskmanager could not create the disk"
  vmx_set "$x" nvme0.present TRUE
  vmx_set "$x" nvme0:0.present TRUE
  vmx_set "$x" nvme0:0.fileName omarchy.vmdk
  sectors=$(( $(stat -f %z "$live") / 512 ))
  cat > "$b/live.vmdk" <<EOF
# Disk DescriptorFile
version=1
encoding="UTF-8"
CID=fffffffe
parentCID=ffffffff
createType="monolithicFlat"

RW $sectors FLAT "live.img" 0

ddb.adapterType = "lsilogic"
ddb.virtualHWVersion = "22"
EOF
  vmx_set "$x" sata0.present TRUE
  vmx_set "$x" sata0:0.present TRUE
  vmx_set "$x" sata0:0.fileName live.vmdk
  vmx_set "$x" ethernet0.present TRUE
  vmx_set "$x" ethernet0.connectionType nat
  vmx_set "$x" ethernet0.virtualDev e1000e
  vmx_set "$x" ethernet0.addressType generated
  vmx_set "$x" usb.present TRUE
  vmx_set "$x" usb_xhci.present TRUE
  vmx_set "$x" usb:0.present TRUE
  vmx_set "$x" usb:0.deviceType hid
  vmx_set "$x" gui.fitGuestUsingNativeDisplayResolution TRUE
  # One guest display per Mac display in full screen; the framebuffer must
  # hold the whole arrangement.
  read -r n w h < <(fusion_mac_displays)
  vmx_set "$x" svga.numDisplays "$n"
  vmx_set "$x" svga.maxWidth "$w"
  vmx_set "$x" svga.maxHeight "$h"
  vmx_set "$x" gui.fullScreenOnAllHostDisplays TRUE
  echo "$x"
}

# fusion_drop_live NAME: keep only the NVMe system disk (the VM must be stopped).
fusion_drop_live() {
  local b x
  b=$(fusion_bundle "$1"); x="$b/$1.vmx"
  vmx_del "$x" sata0:0.
  rm -f "$b/live.vmdk"
}
