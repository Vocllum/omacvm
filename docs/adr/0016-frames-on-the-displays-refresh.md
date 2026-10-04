# 0016: Show the guest's frames on the Mac display's refresh

Status: accepted. Built on `pacing-hdr` (`qemu-cocoa-gl-present-vsync.patch`,
on top of the IOSurface present of ADR 0010), not merged.

## Context

The guest's kernel (7.2, virtio-gpu) completes page flips on a DRM vblank
*timer* at the mode's refresh rate. QEMU puts the Mac display's rate into
the EDID, so the guest runs at 120.006 Hz on a 120 Hz MacBook and Chrome's
`requestAnimationFrame` is perfect inside the VM (120.01 fps, p99 8.4 ms).
But the timer's phase has nothing to do with the Mac's vsync. With the
IOSurface present (ADR 0010) a frame went on the layer as soon as the GPU
finished it; when the guest's frames arrive near Core Animation's latch,
two land in one refresh (one is never seen) and none in the next (a repeat).

Measured on the MacBook panel with the bench lock (pacing page counted per
WindowServer frame with ScreenCaptureKit): 107-110 distinct frames a second
on screen out of 120; 15-20 % of guest frames never shown, 5-10 % of
refreshes repeated. Native Chrome on the Mac: 120.2, 99.2 % shown once.

## Options

1. Guest paced by the host: the guest's flip completes when the Mac shows
   the frame (a fenced flush answered at the host's vsync, or a vblank event
   from the host). Best latency and pacing, but needs a guest kernel change
   and a QEMU protocol extension, and the guest blocks if the host stops
   answering (window hidden, display asleep).
2. Host side, frames assigned to refresh slots by their arrival phase.
   Tried: works with a Metal layer, but the phase estimate breaks down when
   arrivals spread (Chrome plus duplicate flushes), and commits right at the
   display link tick missed the latch.
3. Host side, a `CAMetalLayer` with display sync. Paced perfectly (Metal
   queues drawables to consecutive vsyncs) but 25-27 ms from QEMU's flush to
   the screen: Metal keeps two drawables in flight.
4. Host side, a jitter buffer: finished frames wait in a short FIFO; once
   per refresh, a fixed time before the vsync, the oldest goes on the layer.
   Late frames wait instead of pushing out a neighbour; the queue trims
   itself when frames are left over for a quarter second.

## Decision

Option 4 now, option 1 later. The display link runs on its own
user-interactive thread (on the main thread, event handling delayed ticks by
milliseconds and put two frames into one refresh), commits happen on a
high-priority queue 3 ms before the vsync (`OMACVM_GL_LEAD_MS`): 2 ms still
lost a frame now and then, 4.2 ms brought repeats. ProMotion is asked for the
panel's full rate.

## Consequences

- 98.3-99.8 % of guest frames shown exactly once on the 120 Hz panel
  (119.2-120.0 distinct frames a second), was 74-82 % (107.9-110.0).
- One refresh more delay: QEMU flush to screen 10-14 ms median, was 6-7 ms.
  Option 1 would win it back (the guest renders right after the latch).
- `OMACVM_GL_VSYNC=0` restores showing frames when drawn.
- Two more threads in QEMU (display link, commit queue); no BQL on either.
- glmark2 (quick set, 8 runs each, bench lock): median 2764 vs 2829, -2 %,
  inside the run-to-run spread; to be re-checked with the full set.
