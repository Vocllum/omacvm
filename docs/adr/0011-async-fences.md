# 0011: Report GPU fences from a sync thread, not a timer

Status: accepted. Built on `gpu-native` (`qemu-cocoa-gl-async-fence.patch`,
`virgl-darwin-thread-sync.patch`), not merged. **Open: a fence that never
signals froze the guest in a 30 min soak; not shippable until fixed.**

## Context

Mesa throttles on the fence of the previous frame, so the time from "guest
submits" to "guest hears the fence is done" sets the frame rate of anything
light. virglrenderer can report fences from its own thread
(`VIRGL_RENDERER_THREAD_SYNC` + `ASYNC_FENCE_CB`), but it needs `eventfd`,
which macOS lacks, and QEMU only asked for it with an EGL display. With
Cocoa's CGL contexts QEMU polled fences from a 1 ms timer
(`qemu-darwin-gpu-fence-poll.patch`): median 1.56 ms fence-to-reply, glmark2
stuck near 1000-1250.

## Options

1. Poll faster (100 us timer). Costs CPU when idle, still a floor, and
   QEMU's virtual clock timer is millisecond based.
2. The sync thread on macOS with a stand-in for `eventfd`:
   a pipe, a kqueue `EVFILT_USER`, or an unlinked FIFO opened read-write.
3. Signal from Metal (`MTLSharedEvent`). Not possible while vrend runs on
   Apple's OpenGL; revisit with Zink/Venus.

## Decision

Option 2 with an unlinked FIFO opened `O_RDWR`: one fd that can be read and
written, survives `dup` and `SCM_RIGHTS`. A pipe was tried first and broke
Venus: its render server writes the fence fd it was passed, and a pipe's
read end cannot be written. A kqueue user event is not an fd that
`write()` and `read()` work on, so the server could not signal it.

## Consequences

- Fence-to-reply median 199 us (p90 412); glmark2 1259 -> 4006 together with
  present on flush; the fences are the whole gain (same binary with
  polling: 1246, 1855).
- Apple's `glClientWaitSync` spins: `vrend-sync` uses about half a core while
  the guest renders.
- One more thread with its own CGL context; it only waits, never touches
  vrend state.
- `OMACVM_VIRGL_POLL_FENCES=1` goes back to polling.
- The soak hang (vrend-sync blocked on a fence that never signals) must be
  understood before this becomes the default.
