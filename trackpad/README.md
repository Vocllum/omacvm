# trackpad-bridge

Mac trackpad gestures for the Omarchy VM in Parallels. Parallels gives a Linux
guest only a mouse (pointer, clicks, smooth wheel), so pinch and 3/4-finger
swipes never arrive. This tool reads the built-in trackpad's raw finger
contacts on the Mac (private MultitouchSupport framework) and replays them on a
virtual Apple touchpad in the guest, where libinput and Hyprland turn them into
real gestures.

**Capture mode** = Parallels is the frontmost app and its VM window fills a
display (full screen). Then:

- macOS trackpad gesture events are dropped (event tap): no Spaces / Mission
  Control / Exposé / Launchpad / pinch on the Mac side;
- 3+-finger frames and 2-finger pinches go to the guest;
- pointer, clicks and two-finger scrolling stay on Parallels' own path
  (`SmoothScrolling` = 1 in `config.pvs`).

**⌃⌥⌘ Esc** releases the trackpad to macOS (Omarchy shows a notification); it
re-arms when you come back to the full-screen VM, or press the combo again.
If the Mac helper stops, the tap goes with it and macOS has its gestures back.

| Part | Where |
|---|---|
| Mac helper | `mac/trackpad-bridge.c` → `~/Applications/TrackpadBridge.app` (ad-hoc signed, `org.omaparallels.trackpad-bridge`), LaunchAgent `org.omaparallels.trackpad-bridge`, log `~/Library/Logs/trackpad-bridge.log`. Listens on `10.211.55.2:47830`. Needs Accessibility + Input Monitoring (re-grant after every rebuild, the ad-hoc signature changes) |
| Guest daemon | `guest/trackpad-bridge` → `/usr/local/bin/trackpad-bridge` (python-evdev, root), `guest/trackpad-bridge.service` (systemd). Creates "Apple Inc. Magic Trackpad (trackpad-bridge)" (Apple vendor id, 156x96 mm) and connects to the Mac |
| Hyprland | `~/.config/hypr/input.lua`: `hl.gesture({ fingers = 3/4, direction = "horizontal", action = "workspace" })` |
| Probe | `probe/probe.c`: raw frame + event-tap feasibility probe (`./probe 30` observe, `./probe 30 block` drop gestures) |

Install / remove on the Mac: `mac/install.sh`, `mac/uninstall.sh`.
Guest: `guest/install.sh <user>` (root, in the VM).

Protocol (TCP, one line each): `F <n> [<id> <x> <y> <size>]…` (x/y 0..1, y
down; `F 0` = gesture over) and `S on|off|esc`.

Verified 2026-10-01 on macOS 15.7.4, Parallels 27.0.2, MacBook Pro M4 Max:
4-finger and 3-finger swipes switch workspaces, pinch zooms in Chrome, macOS
Spaces swipes blocked while captured, ⌃⌥⌘ Esc releases and re-arms.

Known rough edges: a 2-finger pinch is recognised on the Mac after ~3.5 % of
finger spread; libinput sometimes reads the first frames as a two-finger
scroll and misses the pinch (2 of 5 in the first test), and a few stray pointer
motions came from the virtual touchpad. Tuning candidates: per-device
`scroll_method`/sensitivity in Hyprland, earlier pinch detection.
