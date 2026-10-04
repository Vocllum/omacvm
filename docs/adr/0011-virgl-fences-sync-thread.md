# 0011: Report virgl fences from virglrenderer's sync thread

## Context

Every light guest frame waits for the fence of the frame before it. In
OmacVM.app QEMU polled virglrenderer's fences from a 1 ms timer on its
millisecond virtual clock: fence to reply took 1.56 ms (median, QEMU trace),
and glmark2 stayed near 1250 while the GPU idled.

## Options

1. Poll faster. Tried 50 us and 20 us real-time timers: no change. QEMU's
   main loop on macOS has no `ppoll` and waits in whole milliseconds, so any
   timer below 1 ms rounds up.
2. Poll in a busy loop on the render thread. Burns a core all the time and
   blocks the BQL.
3. virglrenderer's sync thread (`VIRGL_RENDERER_THREAD_SYNC` +
   `ASYNC_FENCE_CB`), as QEMU already does with EGL: a thread with its own
   GL context waits for each fence and wakes QEMU through a bottom half.
   Needs an eventfd (macOS: an unlinked FIFO opened read-write) and a
   shared CGL context, which Cocoa's display can make.

## Decision

Option 3, on by default; `OMACVM_VIRGL_POLL_FENCES=1` (or the app's hidden
`gpuSafeMode`) goes back to polling. QEMU logs which path it took.

## Consequences

- Fence to reply 0.2 ms (median); glmark2 about 3x (1259 -> ~4000).
- Apple's `glClientWaitSync` spins: the sync thread costs about half a core
  while the guest renders, nothing when it is idle.
- Venus's render server writes its fence fd from its own thread; the FIFO
  stand-in supports that (a pipe did not: Venus hung).
- Freezes seen during testing were other tracks pausing all test VMs with
  SIGSTOP for their benchmarks, not this path; 30-minute soaks pass.
