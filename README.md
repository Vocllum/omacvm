# omarchy-notch-bar

Use the MacBook notch strip for the real [Omarchy](https://omarchy.org) bar when
Omarchy runs full screen in a Parallels Desktop VM.

Parallels keeps its full-screen window below the camera housing, so the top
43 points of a notched MacBook display stay black. This project renders
Omarchy's own Quickshell bar inside the VM on a hidden output the size of that
strip, streams its pixels to a small native macOS panel drawn in the strip, and
forwards the mouse back. The VM window keeps its full height without a bar;
external monitors keep the normal bar.

Status: work in progress.

## Parts

- `guest/` — runs inside the Omarchy VM: hidden output setup, bar placement,
  frame capture and streaming, input injection.
- `mac/` — the macOS helper panel (Swift, builds with the Command Line Tools).
- `docs/` — design notes and measurements.

## License

MIT
