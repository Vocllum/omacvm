# omarchy-notch-bar

Use the MacBook notch strip for the real [Omarchy](https://omarchy.org) bar
when Omarchy runs full screen in a Parallels Desktop VM.

Parallels keeps its full-screen window below the camera housing, so the top
43 points of a notched MacBook display stay black, and Omarchy's own bar takes
another 26 points below that. With this project the VM uses the whole area
below the notch for windows, and Omarchy's bar — the real one, rendered by
Omarchy, not a look-alike — appears in the strip beside the camera, where the
macOS menu bar would be. Clicking and scrolling on it work as in the VM, and
panels (clock, audio, network, …) open right below it.

External monitors are unaffected and keep the normal bar.

## How it works

```
 Omarchy VM (Hyprland)                                   macOS
 ─────────────────────                                   ─────
 Omarchy bar, patched clone ── renders on ──► NOTCH       Omarchy Notch Bar.app
   │                                          (hidden     ┌──────────────────────┐
   │  parked copy on the built-in             output,     │ panel in the notch   │
   │  display: invisible, no space,           2056x26)    │ strip, above the     │
   │  receives the clicks                        │        │ menu bar, never      │
   │                                         notchcast    │ takes focus          │
   └──── qs ipc "notchbar" ◄── commands ◄──── (C) ◄── TCP ─┤                      │
                                    frames ──────────────► │ draws frames, sends  │
                                                           │ clicks / scrolling   │
                                                           └──────────────────────┘
```

- **Hidden output.** Hyprland gets a headless output named `NOTCH`, exactly
  as wide as the built-in display and as tall as the bar. It overlaps the top
  edge of the built-in display, which keeps it inside the monitor layout, so
  Parallels' absolute mouse keeps its mapping and the pointer never lands on it.
- **Bar.** Omarchy's bar is cloned with Omarchy's own `omarchy plugin clone`
  and patched (`guest/bar/apply-patch.py`). The copy on `NOTCH` is what the Mac
  shows; its centre widgets move out from under the camera housing. While the
  strip is shown, the copy on the built-in display is *parked*: 1 px tall, just
  off screen, reserving no space. Clicks from the Mac are pressed on that parked
  copy, so Omarchy opens its panels on the visible display, right below the
  strip.
- **notchcast** (guest, C). Captures `NOTCH` with `ext-image-copy-capture-v1`.
  A capture only completes when Hyprland repaints the output, so an idle bar
  costs nothing; changes are sent as LZ4-compressed rectangles (typically
  0.5–3 KB). It relays the helper's commands to the bar, masks the software
  cursor (Hyprland draws it into every output that contains it), sends the
  guest's cursor images, and keeps the `NOTCH` output present and correctly
  sized, including after `hyprctl reload`.
- **Omarchy Notch Bar.app** (macOS, Swift, builds with the Command Line Tools).
  Shows a borderless, non-activating panel over the strip while the VM is full
  screen on the built-in display, draws the frames, and forwards clicks and
  scrolling. Over the strip it shows the guest's own cursor and hides the
  guest's, so there is only ever one cursor.
- **Fail-safe.** The helper re-asserts "parked" every second. If it stops,
  quits, or the VM leaves full screen, the guest brings its bar back on the
  built-in display within 5 seconds.

## Requirements

- MacBook with a notch, macOS 14 or later, Xcode Command Line Tools.
- Parallels Desktop running an Omarchy (Arch Linux ARM, Hyprland 0.56+) VM in
  full screen on the built-in display, with Parallels' shared network
  (host `10.211.55.2`).
- In the guest: `gcc`, `wayland`, `wayland-protocols` (with
  `ext-image-copy-capture`), `lz4`, `python3` — all present on Omarchy.

## Install

In the VM, as your desktop user, from a checkout of this repository:

```bash
./guest/install.sh
```

On the Mac:

```bash
./mac/install.sh
```

This builds `~/Applications/Omarchy Notch Bar.app` and starts it at login
(LaunchAgent `ch.gillesgoetsch.notchbar`, log `~/Library/Logs/notchbar.log`).

## Uninstall

```bash
./guest/uninstall.sh          # in the VM; add --remove-bar-clone to also drop the bar clone
./mac/uninstall.sh            # on the Mac
```

## Configuration

macOS helper (`defaults write ch.gillesgoetsch.notchbar <key> <value>`, then
restart it with `launchctl kickstart -k gui/$(id -u)/ch.gillesgoetsch.notchbar`):

| Key | Default | Meaning |
|---|---|---|
| `listenHost` | `10.211.55.2` | Host side of the Parallels shared network |
| `port` | `47811` | TCP port |
| `guestPrefix` | `10.211.55.` | Only guests whose address starts with this are accepted |
| `vmOwner` | `Parallels Desktop` | Owner name of the VM's full-screen window |

Guest (`systemctl --user edit notchcast`, `Environment=`):

| Variable | Default | Meaning |
|---|---|---|
| `NOTCHBAR_HOST` | `10.211.55.2` | Where the helper listens |
| `NOTCHBAR_PORT` | `47811` | TCP port |
| `NOTCHBAR_OUTPUT` | `NOTCH` | Name of the hidden output |
| `NOTCHBAR_SCREEN` | `Virtual-1` | The built-in display's output name |

## Limitations

- Hover effects of the bar (tooltips, hover highlights) are not mirrored;
  clicks, right/middle clicks and scrolling are.
- Tray icons are shown in the strip but cannot be clicked there (they handle
  input themselves rather than through the bar's click targets).
- Only a bar at the top edge is mirrored.
- The bar clone is a fork of Omarchy's `Bar.qml`. After an Omarchy update that
  changes the bar, re-clone and re-run `./guest/install.sh` (the patch refuses
  to apply if the code it expects has moved).
- Omarchy's shell caches plugin code: after changing the patch, restart the
  shell with `omarchy restart shell`.
- Other tools that manage Hyprland monitors must ignore the `NOTCH` output.
- The cursor handling uses the window server property
  `SetsCursorInBackground`, which is not public API: over the strip the helper
  shows the guest's own cursor images, and over the VM's full-screen windows it
  hides the macOS cursor (Parallels does not reliably do so when the pointer
  arrives from another window, which otherwise leaves a macOS arrow on top of
  the guest cursor).
- Hyprland warns whenever monitors overlap. The overlap of `NOTCH` with the
  built-in display is deliberate; `notchbar.lua` dismisses that one warning.

## Troubleshooting

| Symptom | Check |
|---|---|
| Strip stays black | `~/Library/Logs/notchbar.log` shows "guest connected"? In the VM: `systemctl --user status notchcast`, `journalctl --user -u notchcast` |
| Bar visible in the VM *and* in the strip | `omarchy-shell notchbar state` — `parked` should be true while the strip shows |
| Mouse offset in the VM | `hyprctl monitors` — `NOTCH` must be at the built-in display's position and width |
| Panels open on the wrong screen | `NOTCHBAR_SCREEN` must name the built-in display's output |

## License

MIT — see [LICENSE](LICENSE). Omarchy's bar code is not included; it is
cloned from your own Omarchy installation and patched at install time.
