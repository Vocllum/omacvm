#!/usr/bin/env python3
"""Boot a UEFI firmware without a disk and check that it shows the boot logo.

  test-boot-logo.py QEMU CODE.fd LOGO.bmp

QEMU starts the firmware as OmacVM.app does (virt, HVF, virtio-gpu at
1920 x 1080) but with no window and fresh boot variables. The screen is read
over QMP (screendump) until the logo is there: exactly LOGO.bmp's pixels,
centred as edk2's BootLogoLib draws it. Exit 0 when it is, 1 when it is not
there after 30 seconds.
"""
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

WIDTH, HEIGHT = 1920, 1080


def read_bmp(path):
    """A 24-bit bottom-up BMP as rows of (r, g, b) bytes."""
    data = open(path, "rb").read()
    offset, = struct.unpack_from("<I", data, 10)
    w, h, _, bits = struct.unpack_from("<iiHH", data, 18)
    if bits != 24 or h <= 0:
        raise SystemExit(f"test-boot-logo: {path} is not a 24-bit bottom-up BMP")
    stride = (w * 3 + 3) & ~3
    rows = []
    for y in range(h):
        line = data[offset + (h - 1 - y) * stride:][:w * 3]
        rows.append(bytes(c for i in range(0, len(line), 3) for c in line[i:i + 3][::-1]))
    return w, h, rows


def read_ppm(path):
    """QEMU's screendump (binary PPM, P6, maxval 255) as (w, h, rgb bytes)."""
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    if fields[0] != b"P6" or fields[3] != b"255":
        raise ValueError("unexpected screendump format")
    return int(fields[1]), int(fields[2]), data[pos + 1:]


def logo_shown(shot, logo):
    w, h, pixels = shot
    lw, lh, rows = logo
    if (w, h) != (WIDTH, HEIGHT):
        return False
    x0, y0 = (w - lw) // 2, (h - lh) // 2      # BootLogoLib's centre
    for y in range(lh):
        start = ((y0 + y) * w + x0) * 3
        if pixels[start:start + lw * 3] != rows[y]:
            return False
    return True


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(path)
        self.buffer = b""
        self.reply()                              # greeting
        self.call("qmp_capabilities")

    def reply(self):
        while True:
            while b"\n" not in self.buffer:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError("QMP closed")
                self.buffer += chunk
            line, self.buffer = self.buffer.split(b"\n", 1)
            message = json.loads(line)
            if "event" not in message:
                return message

    def call(self, command, **arguments):
        self.sock.sendall(json.dumps({"execute": command, "arguments": arguments}).encode() + b"\n")
        message = self.reply()
        if "error" in message:
            raise RuntimeError(f"{command}: {message['error']}")
        return message["return"]


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    qemu, code, logo_path = sys.argv[1:]
    logo = read_bmp(logo_path)
    work = tempfile.mkdtemp(prefix="omacvm-fw.")
    vars_fd = os.path.join(work, "vars.fd")
    qmp_path = os.path.join(work, "qmp")
    shot_path = os.path.join(work, "screen.ppm")
    with open(vars_fd, "wb") as f:
        f.truncate(64 * 1024 * 1024)               # as a new VM's efi-vars.fd
    vm = subprocess.Popen([
        qemu, "-machine", "virt,gic-version=3", "-accel", "hvf", "-cpu", "host,pmu=off",
        "-smp", "2", "-m", "1024", "-nodefaults",
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={vars_fd}",
        "-device", f"virtio-gpu-pci,max_outputs=1,xres={WIDTH},yres={HEIGHT},romfile=",
        "-display", "none", "-serial", "none", "-monitor", "none",
        "-qmp", f"unix:{qmp_path},server=on,wait=off",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 30
        qmp = None
        while time.monotonic() < deadline:
            if vm.poll() is not None:
                raise SystemExit("test-boot-logo: QEMU stopped: " + vm.stderr.read().decode(errors="replace").strip())
            try:
                qmp = qmp or QMP(qmp_path)
                qmp.call("screendump", filename=shot_path)
                if logo_shown(read_ppm(shot_path), logo):
                    print(f"test-boot-logo: the firmware shows the {logo[0]} x {logo[1]} logo, centred")
                    return 0
            except (OSError, ValueError, RuntimeError):
                pass                               # not up yet, or a half-written dump
            time.sleep(0.25)
        print("test-boot-logo: no boot logo on the screen after 30 seconds", file=sys.stderr)
        return 1
    finally:
        vm.kill()
        vm.wait()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
