# Frame pacing, latency, colour and HDR probes

Tools behind docs/architecture/graphics.md section 12 (`pacing-hdr`). They
measure what reaches the Mac's screen, not what the guest thinks it drew.

| File | Where | What |
|---|---|---|
| `pacing.html`, `srv.py`, `stats.py` | guest (`/opt/pacing`, `python3 srv.py` serves on 127.0.0.1:8765) | rAF loop that draws its frame number as 16 cells, a key-toggled marker; posts rAF intervals (`stats.py` summarises them) |
| `colors.html` | guest | six colour bars (red, green, blue, white, grey, black) |
| `hdrcss.html` | guest | CSS `color(rec2100-pq ...)` bars at 100/203/400/600/1000 nits and SDR white (Chrome HDR check; Chrome 154 still clips them at SDR white) |
| `sckpace.swift` | Mac | ScreenCaptureKit capture of the VM window; counts how far the frame number moved per WindowServer frame; with `QMP=` also key -> screen latency |
| `snapcolor.swift` | Mac | the colour bars as seen on screen, converted to Display P3 and sRGB |
| `snaphdr.swift` | Mac | one frame in extended linear Display P3 (1.0 = SDR white; `pq` as 2nd argument: in PQ), plus each screen's EDR headroom |

Build the Mac tools with `swiftc -O <file>.swift -o <name>` (the calling app
needs Screen Recording permission). Window ids: `CGWindowListCopyWindowInfo`
or `screencapture -l`.

Pacing run (Chrome kiosk on the page, 20 s; capture 12 s of it):

```
guest$ google-chrome-stable --ozone-platform=wayland --kiosk 'http://127.0.0.1:8765/pacing.html?secs=20'
mac$   ./sckpace <window id> 12 cap.jsonl
guest$ python3 stats.py /tmp/pacing-stats.json
```

Results are only comparable with `~/.omacvm-bench.lock` held, the other test
VMs paused and nothing else on that display. Control: the same page in the
Mac's own Chrome gives 120.2 shown frames/s, steps {1: 1192, 2: 4, 0: 6}.

Colour: open `colors.html` full screen in the guest, then `./snapcolor <id>`.
With tagged surfaces guest red is Display P3 (234,51,35); untagged (255,0,0).

HDR: guest at 10 bits with `cm = "hdr"` (see ADR 0021), QEMU with
`OMACVM_GL_HDR=1`, then `./snaphdr <id>`: values above 1.0 are HDR, and the
built-in screen's "edr now" rises above 1.0.
