#!/usr/bin/env python3
"""Guest side of soak.sh: one line
"signalled emitted loops webgl_frames video_frame video_drops mem_avail_kb webgl_lit",
missing values as 0 so the fields never shift. The video frame comes from mpv's IPC socket."""
import glob, json, socket, sys

g = sys.argv[1]


def first(f, default="0"):
    try:
        return f()
    except Exception:
        return default


def fence():
    for p in glob.glob("/sys/kernel/debug/dri/*/virtio-gpu-irq-fence"):
        parts = open(p).read().split()
        if len(parts) >= 3:
            return parts[1], parts[2]
    return "0", "0"


def mpv(prop):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(2)
    s.connect(f"{g}/mpv.sock")
    s.sendall(json.dumps({"command": ["get_property", prop]}).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        buf += s.recv(4096)
    return str(int(json.loads(buf.split(b"\n")[0])["data"]))


sig, emit = first(fence, ("0", "0"))
loops = first(lambda: str(open(f"{g}/gpu.txt").read().count("LOOP")))
wf, lit = first(lambda: open(f"{g}/frames.txt").read().splitlines()[-1].split()[:2], ("0", "0"))
vf = first(lambda: mpv("estimated-frame-number"))  # restarts at 0 on each loop of the file
vd = first(lambda: mpv("frame-drop-count"))
mem = first(lambda: next(l.split()[1] for l in open("/proc/meminfo") if l.startswith("MemAvailable")))
print(sig, emit, loops, wf, vf, vd, mem, lit)
