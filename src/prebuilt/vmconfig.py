#!/usr/bin/env python3
"""VM configuration edits for prebuilt images (Parallels config.pvs, UTM
config.plist, VMware Fusion .vmx). The VM must be stopped.

  vmconfig.py pvs-generalize CONFIG NAME     image: no Mac paths, ids or shares of this Mac
  vmconfig.py utm-generalize CONFIG NAME
  vmconfig.py vmx-generalize VMX NAME
  vmconfig.py pvs-identity CONFIG NAME PVM CLIPDIR CPUS MEMORY_MB DISK_MB
                                            install: new ids and MAC, name, shares, resources
  vmconfig.py utm-identity CONFIG NAME CPUS MEMORY_MB
  vmconfig.py vmx-identity VMX NAME CPUS MEMORY_MB GRAPHICS_GB DISPLAYS WIDTH HEIGHT
  vmconfig.py pvs-seed CONFIG ISO|-           attach the seed as CD (- detaches)
  vmconfig.py utm-seed CONFIG ISO_NAME|-      a read-only VirtIO disk in Data/ (- removes it)
  vmconfig.py vmx-seed VMX ISO|-
  vmconfig.py qcow2-grow FILE MB              grow a qcow2 disk (UTM) in place, no snapshots
"""
import plistlib
import random
import re
import sys
import uuid
import xml.etree.ElementTree as ET

TEMPLATE_SERVER = "{a4c735ec-ac90-49ac-8555-0eff5a9e4eb6}"   # the live installer's template value


def new_uuid(braces=True):
    u = str(uuid.uuid4())
    return "{%s}" % u if braces else u.upper()


def parallels_mac():
    return "001C42" + "".join(random.choice("0123456789ABCDEF") for _ in range(6))


# ---------- Parallels ----------

def pvs_load(path):
    return ET.parse(path)


def pvs_save(tree, path):
    ET.indent(tree, space="   ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)


def settext(root, path, value):
    e = root.find(path)
    if e is not None:
        e.text = str(value)


def pvs_generalize(path, name):
    tree = pvs_load(path)
    r = tree.getroot()
    for p in ("Identification/VmUuid", "Identification/SourceVmUuid"):
        settext(r, p, "{00000000-0000-0000-0000-000000000000}")
    settext(r, "Identification/VmName", name)
    settext(r, "Identification/ServerUuid", TEMPLATE_SERVER)
    for e in r.iter("ServerUuid"):
        if e is not r.find("Identification/ServerUuid"):
            e.text = ""
    for e in r.iter("LastServerUuid"):
        e.text = ""
    # Shared folders point into this Mac; the installer adds them again.
    hs = r.find("Settings/Tools/SharedFolders/HostSharing")
    if hs is not None:
        for f in hs.findall("SharedFolder"):
            hs.remove(f)
    for n in r.iter("NetworkAdapter"):
        settext(n, "MAC", "001C42000000")
        settext(n, "HostMAC", "001C42000001")
    pvs_seed(r, None)
    pvs_save(tree, path)


def add_share(r, name, path, ro):
    hs = r.find("Settings/Tools/SharedFolders/HostSharing")
    for f in hs.findall("SharedFolder"):
        if f.findtext("Name") == name:
            hs.remove(f)
    folders = hs.findall("SharedFolder")
    fid = max((int(f.get("id")) for f in folders), default=-1) + 1
    f = ET.Element("SharedFolder", {"dyn_lists": "", "id": str(fid)})
    for tag, val in [("Name", name), ("Path", path), ("FolderDescription", ""),
                     ("ReadOnly", 1 if ro else 0), ("Enabled", 1), ("SuidEnabled", 0)]:
        ET.SubElement(f, tag).text = str(val)
    kids = list(hs)
    pos = max((kids.index(x) for x in folders), default=None)
    if pos is None:
        pos = next((i for i, k in enumerate(kids) if k.tag == "SharedCloud"), len(kids)) - 1
    hs.insert(pos + 1, f)
    settext(r, "Settings/Tools/SharedFolders/HostSharing/Enabled", 1)


def pvs_identity(path, name, pvm, clipdir, cpus, mem, disk_mb):
    tree = pvs_load(path)
    r = tree.getroot()
    vu = new_uuid()
    settext(r, "Identification/VmUuid", vu)
    settext(r, "Identification/SourceVmUuid", vu)
    settext(r, "Identification/VmName", name)
    for n in r.iter("NetworkAdapter"):
        settext(n, "MAC", parallels_mac())
        settext(n, "HostMAC", parallels_mac())
    for h in r.find("Hardware").findall("Hdd"):
        settext(h, "Uuid", new_uuid())
        if h.findtext("InterfaceType") == "3":
            settext(h, "Size", disk_mb)
    settext(r, "Hardware/Cpu/Number", cpus)
    settext(r, "Hardware/Memory/RAM", mem)
    add_share(r, "vmlog", pvm, True)
    add_share(r, "clip", clipdir, False)
    pvs_save(tree, path)


def pvs_seed(r, iso):
    for c in r.find("Hardware").findall("CdRom"):
        settext(c, "SystemName", iso or "")
        settext(c, "UserFriendlyName", iso or "")
        settext(c, "Connected", 1 if iso else 0)
        settext(c, "EmulatedType", 1)
        settext(c, "Enabled", 1)
        return


# ---------- UTM ----------

def utm_generalize(path, name):
    c = plistlib.load(open(path, "rb"))
    c["Information"]["Name"] = name
    c["Information"]["UUID"] = "00000000-0000-0000-0000-000000000000"
    for n in c.get("Network", []):
        n["MacAddress"] = "02:00:00:00:00:00"
    c["Drive"] = [d for d in c["Drive"] if d.get("ImageType") == "Disk" and d.get("Interface") == "NVMe"]
    plistlib.dump(c, open(path, "wb"))


def utm_identity(path, name, cpus, mem):
    c = plistlib.load(open(path, "rb"))
    c["Information"]["Name"] = name
    c["Information"]["UUID"] = new_uuid(False)
    for n in c.get("Network", []):
        n["MacAddress"] = "02:" + ":".join("%02X" % random.randrange(256) for _ in range(5))
    # A built-in icon until OmacVM's own is set: UTM's scripting cannot update
    # a VM with a custom icon.
    c["Information"]["Icon"] = "arch-linux"
    c["Information"]["IconCustom"] = False
    c["System"]["CPUCount"] = int(cpus)
    c["System"]["MemorySize"] = int(mem)
    plistlib.dump(c, open(path, "wb"))


def utm_seed(path, iso_name):
    c = plistlib.load(open(path, "rb"))
    c["Drive"] = [d for d in c["Drive"] if d.get("ImageName") != "omacvm-seed.iso"]
    if iso_name:
        c["Drive"].append({"Identifier": new_uuid(False), "ImageName": iso_name, "ImageType": "Disk",
                           "Interface": "VirtIO", "InterfaceVersion": 1, "ReadOnly": True})
    plistlib.dump(c, open(path, "wb"))


# ---------- VMware Fusion ----------

def vmx_read(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    return [l for l in lines if l.strip()]


def vmx_write(path, lines):
    open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")


def vmx_set(lines, key, value):
    out, done = [], False
    for l in lines:
        k = l.split("=", 1)[0].strip()
        if k == key:
            if not done:
                out.append('%s = "%s"' % (key, value))
                done = True
            continue
        out.append(l)
    if not done:
        out.append('%s = "%s"' % (key, value))
    return out


def vmx_del(lines, prefix):
    return [l for l in lines if not l.split("=", 1)[0].strip().startswith(prefix)]


def vmx_generalize(path, name):
    l = vmx_read(path)
    l = [x for x in l if x.split("=", 1)[0].strip() != "ethernet0.address"]
    for p in ("uuid.", "ethernet0.generatedAddress", "vc.uuid", "sata0:1.",
              "extendedConfigFile", "nvram", "displayName", "checkpoint.", "sata0:0.", "gui.lastPowered",
              "vmxstats.", "toolsInstallManager.", "tools.syncTime", "guestInfo.", "migrate.", "cleanShutdown",
              "softPowerOff", "usb:1.", "usb_xhci:", "monitor.phys_bits_used", "vmotion.", "svga.guestBackedPrimaryAware"):
        l = vmx_del(l, p)
    l = vmx_set(l, "displayName", name)
    l = vmx_set(l, "nvram", name + ".nvram")
    l = vmx_set(l, "svga.numDisplays", "1")
    l = vmx_set(l, "svga.maxWidth", "3840")
    l = vmx_set(l, "svga.maxHeight", "2400")
    l = vmx_set(l, "uuid.action", "create")
    for x in l:
        if "/Users/" in x:
            sys.exit("vmx-generalize: a Mac path is left: " + x)
    vmx_write(path, l)


def vmx_identity(path, name, cpus, mem, gfx, n, w, h):
    l = vmx_read(path)
    for p in ("uuid.bios", "uuid.location", "ethernet0.generatedAddress", "vc.uuid"):
        l = vmx_del(l, p)
    l = vmx_set(l, "uuid.action", "create")
    l = vmx_set(l, "displayName", name)
    l = vmx_set(l, "numvcpus", cpus)
    l = vmx_set(l, "memsize", mem)
    l = vmx_set(l, "svga.graphicsMemoryKB", int(gfx) * 1048576)
    l = vmx_set(l, "svga.numDisplays", n)
    l = vmx_set(l, "svga.maxWidth", w)
    l = vmx_set(l, "svga.maxHeight", h)
    vmx_write(path, l)


def vmx_seed(path, iso):
    l = vmx_del(vmx_read(path), "sata0:1.")
    if iso:
        l = vmx_set(l, "sata0.present", "TRUE")
        l = vmx_set(l, "sata0:1.present", "TRUE")
        l = vmx_set(l, "sata0:1.deviceType", "cdrom-image")
        l = vmx_set(l, "sata0:1.fileName", iso)
        l = vmx_set(l, "sata0:1.startConnected", "TRUE")
    vmx_write(path, l)


def qcow2_grow(path, mb):
    """Raise the virtual size. The L1 table must already have room for it
    within its clusters (one 64 KB cluster maps 4 TB), so nothing moves:
    only the header's size and L1 length change."""
    import struct
    with open(path, "r+b") as f:
        h = f.read(104)
        if h[:4] != b"QFI\xfb":
            sys.exit("qcow2-grow: not a qcow2 file")
        version, = struct.unpack(">I", h[4:8])
        cluster_bits, = struct.unpack(">I", h[20:24])
        size, = struct.unpack(">Q", h[24:32])
        crypt, l1_size = struct.unpack(">II", h[32:40])
        l1_off, = struct.unpack(">Q", h[40:48])
        nb_snap, = struct.unpack(">I", h[60:64])
        incompat = struct.unpack(">Q", h[72:80])[0] if version >= 3 else 0
        if crypt or nb_snap or incompat & ~0x1 & ~0x8 or version not in (2, 3):
            sys.exit("qcow2-grow: encrypted, snapshots or unknown features")
        new = int(mb) * 1048576
        if new <= size:
            return
        cs = 1 << cluster_bits
        per_l2 = cs * (cs // 8)
        need = -(-new // per_l2)
        room = (-(-l1_size * 8 // cs)) * cs // 8
        if need > room:
            sys.exit("qcow2-grow: the L1 table has no room for that size")
        f.seek(l1_off + l1_size * 8)
        if any(f.read((need - l1_size) * 8)):
            sys.exit("qcow2-grow: unexpected data after the L1 table")
        f.seek(24)
        f.write(struct.pack(">Q", new))
        f.seek(36)
        f.write(struct.pack(">I", need))


def main(a):
    if len(a) < 3:
        sys.exit(__doc__)
    cmd, path, rest = a[1], a[2], a[3:]
    if cmd == "pvs-generalize":
        pvs_generalize(path, rest[0])
    elif cmd == "utm-generalize":
        utm_generalize(path, rest[0])
    elif cmd == "vmx-generalize":
        vmx_generalize(path, rest[0])
    elif cmd == "pvs-identity":
        pvs_identity(path, *rest[:3], *(int(x) for x in rest[3:6]))
    elif cmd == "utm-identity":
        utm_identity(path, rest[0], rest[1], rest[2])
    elif cmd == "vmx-identity":
        vmx_identity(path, *rest[:8])
    elif cmd == "pvs-seed":
        tree = pvs_load(path)
        pvs_seed(tree.getroot(), None if rest[0] == "-" else rest[0])
        pvs_save(tree, path)
    elif cmd == "utm-seed":
        utm_seed(path, None if rest[0] == "-" else rest[0])
    elif cmd == "qcow2-grow":
        qcow2_grow(path, rest[0])
    elif cmd == "vmx-seed":
        vmx_seed(path, None if rest[0] == "-" else rest[0])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
