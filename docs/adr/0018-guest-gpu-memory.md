# 0018: Every GL context is flushed, and guest resources have a memory budget

Status: accepted. Built on `gpu-robust` (`qemu-cocoa-gl-view-flush.patch`,
`virgl-control-queue-flush.patch`, `virgl-resource-memory-budget.patch`).
The flushes are always on. The budget is on by default
(`OMACVM_GPU_MEMORY_MB`, 0 turns it off).

## Context

`gpu-native` found that a guest switching its screen between two large
modes grew QEMU's "IOAccelerator (graphics)" memory by about 1.1 GB per
switch (8000x6000 <-> 7000x5000, 20 GB after 18 switches), and never gave it
back. 2.6.0 and 2.7.0 have it too. Any guest program with access to the DRM
device could use up the Mac's memory: a denial of service from inside the VM.

Apple's OpenGL keeps the memory of textures made, deleted or uploaded on a
context until that context is flushed. Two contexts did such work on every
mode change and were never flushed:

- QEMU's Cocoa view context: `set_scanout` with a new size makes a new
  surface, and `cocoa_gl_switch` deletes the old surface texture and uploads
  a new one there. With virgl the window shows the guest's scanout texture,
  so nothing ever drew with (or flushed) that context.
- vrend's own context (ctx0): the guest's kernel uploads the whole new screen
  through QEMU's 2D path (`transfer_to_host_2d`) on every mode change, and
  QEMU creates and frees resources there. Guest contexts are flushed by their
  fences; ctx0 has none.

Separately, nothing limited the memory of virgl resources at all. QEMU's
`max_hostmem` covers only 2D resources without virgl; with virgl every 2D
and 3D resource goes to virglrenderer, which makes a GL texture or buffer of
the size the guest asks for. Each is bounded by the GL's maximum sizes, but
their number is not.

## Decision

1. `with_gl_view_ctx()` calls `glFlush()` before it leaves the view context
   (`qemu-cocoa-gl-view-flush.patch`).
2. virglrenderer calls `glFlush()` after QEMU's resource create, resource
   unref and transfer-to-host commands, on the context the work ran on
   (`virgl-control-queue-flush.patch`).
3. virglrenderer charges every resource its estimated size (all mip levels,
   layers, depth and samples; at least 4 KiB, so many tiny resources count
   too; staging buffers live in guest memory and cost 4 KiB) and refuses a
   resource that would take the total past the budget, like a failed
   allocation. Freeing a resource gives its bytes back. The budget is a
   quarter of the Mac's memory (16 GB on a 64 GB Mac, 4 GB on 16 GB, 2 GB on
   8 GB), or `OMACVM_GPU_MEMORY_MB`; 0 turns it off. The QEMU log says the
   budget at start and logs refusals at the 1st, 2nd, 4th, 8th ... one
   (`virgl-resource-memory-budget.patch`).

The budget is read from the Mac at run time, not from a model list
(STANDARDS 16): an 8 GB MacBook Air gets 2 GB.

## Why both flushes

Measured on a test VM (MacBook Pro M4 Max, `tests/graphics/scanout-churn.sh`,
3840x2160 <-> 2560x1440, IOAccelerator dirty memory from `footprint`):

| Runtime | Growth per switch |
|---|---|
| neither flush (2.7.0 state) | about 100 MB, stopped at the 2 GB guard after 20 |
| view flush only | about 16 MB (84 switches: +1.35 GB) |
| ctx0 flush only | about 80 MB |
| both | none: 657-688 MB over 120 switches, back to the start value when idle |

With both, 5120x2880 <-> 3840x2160 (60 switches) and gpu-native's
8000x6000 <-> 7000x5000 (16 switches) stay flat too (703-719 MB and 1180 MB).
The ctx0 cause was found by elimination with test builds of QEMU: no surface
texture at all, glFinish instead of glFlush, autorelease pools around the
virgl commands, and a window that draws nothing all kept growing; a flush of
ctx0 after every command stopped it. `Tests/display/view-texture-churn.c`
replays both contexts' GL calls on the GPU without a VM and shows the same
(4K, 40 switches: surface switch without flush 735 MB, with 342 MB; ctx0
upload without flush 718 MB, with 327 MB; everything with both flushes
flat at 680-694 MB; raw output in the track's results folder).

## Consequences

- A flush per resource create, unref and transfer command. These commands
  are not per draw; glmark2 and WebGL numbers before and after are in the
  track notes.
- A guest that goes past the budget sees resource creation fail. The guest
  kernel does not pass the error on, so the guest program typically sees its
  context fail at the next command that uses the resource (GL context lost
  with ADR 0016), not `GL_OUT_OF_MEMORY`. The host and the other guest
  programs keep running.
- The estimate is not the driver's real allocation (alignment, compression,
  renaming). It is close for large resources, which is what matters here.

## Not covered

- Work a guest context does in its own command stream without ever asking
  for a fence (inline uploads, copies) is flushed only by its fences. Mesa
  fences every frame; a hostile guest that never does was not measured.
- Venus: device memory a guest allocates with `vkAllocateMemory` is not in
  the budget (Venus is off by default).
- GL object counts (queries, samplers, surfaces) per context are not limited;
  each is small.
- A GPU *hang* (valid but endless work) is the GPU watchdog's job.

## Alternatives

- Lower `max_hostmem` or a resource count limit in QEMU: QEMU does not see
  the size of virgl resources on the GPU side, and a count does not bound
  memory.
- Flush ctx0 after every virtio-gpu command in QEMU: it worked in the test
  build, but it adds a flush per 3D submission too, and virglrenderer is
  where the GL work is.
- Asking the driver for its real allocation: Apple's GL has no query for it.
