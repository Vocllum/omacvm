# 0023: The refresh rate follows the guest (ProMotion)

Status: accepted. Built on `pacing-hdr` (`qemu-cocoa-gl-present-vsync.patch`,
on top of ADR 0020), not merged. Power on a quiet Mac still to measure.

## Context

ADR 0020 shows the guest's frames on the display link's ticks and asked
ProMotion for the panel's full rate while frames came. A native macOS app
asks only for what it draws: macOS then lowers the panel's refresh (down to
24 Hz on a MacBook Pro) for video, typing or an idle window, which saves
power. The user asked for the same.

What the guest sends: an idle Omarchy desktop sends no frames at all (the
link was already paused then); a 24 fps video in mpv sends exactly 24 a
second, a 60 fps one 60; a terminal or a clock sends single frames.

The guest's own rate cannot follow: virtio-gpu has no adaptive-sync
property, so Hyprland's VRR stays off and the guest's vblank timer runs at
the EDID rate. Only the host side can adapt.

## Options

1. Keep the full rate while frames come (ADR 0020).
2. Ask for the guest's measured frame rate (CADisplayLink
   `preferredFrameRateRange`), whatever it is.
3. Ask for the slowest whole fraction of the full rate that is a whole
   multiple of the guest's frame rate, and do not run the link at all for
   frames that come one at a time.

## Decision

Option 3. Per one-second window: the frame rate from the first to the last
frame (not a count, so the window's edges do not matter), extra flushes
that replaced a frame not counted; candidates 120/k (60, 40, 30, 24) down to
the screen's slowest rate (NSScreen `maximumRefreshInterval`); the rate must
be a whole multiple of the frame rate within 3 %, and at most one gap in the
window shorter than half a tick. Lower needs two windows in a row; two extra
frames in a row or a full queue bring the full rate back at once. Frames more
than 52 ms apart are shown when ready without the link; the third close frame
starts it at the full rate. Screens with one rate keep it (STANDARDS 16).
Option 2 would show 25 fps on a 25 Hz tick the panel cannot hit and 20 fps
at 20 Hz instead of 40.

## Consequences

- Virtual 120 Hz display with the screen's floor faked at 24 Hz (dev build
  only), bench lock: the link ticks 23.8 times a second for a 24 fps page
  (fixed: 120.6), 60.5 for 60 fps, 0 for a page changing 5 times a second
  (fixed: 114); QEMU's CPU 0-4 points lower; frames held exactly as long as
  they should: 24 fps 84 % (fixed 72 %), 60 fps 98.5 % (77 %): a slow link
  absorbs more arrival jitter than a fast one.
- testufo (120 fps) unchanged: 119.6-119.9 new frames a second.
- The first frames of an animation after single frames are shown when
  ready (as gpu-native did), the link takes over from the third.
- On the MacBook's ProMotion panel macOS grants the request: for a 24 fps
  video the link ticked 24-26 times a second (fixed: 120.5), for a page
  changing 5 times a second not at all (fixed: 120.6).
- Power is not settled: a 10-minute check on the panel (brightness 50 %,
  2 minutes per row) read 14.4-20.7 W with the VM and 26.9 W without it,
  because other tracks' VMs (not paused by the bench lock) loaded the Mac
  more than the difference being measured. The full matrix (adaptive vs
  fixed, several rounds, a quiet Mac) is left for the end of the pipeline.
- `OMACVM_GL_REFRESH=fixed` restores option 1. Trace events
  `cocoa_present_*` show the rate and counters.
