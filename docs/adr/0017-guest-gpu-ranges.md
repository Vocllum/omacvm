# 0017: The host checks every buffer range a guest draw reaches

Status: accepted. Built on `gpu-robust` (`virgl-buffer-binding-checks.patch`,
`virgl-draw-range-checks.patch`, `virgl-uniform-buffer-checks.patch`,
`virgl-shader-index-clamp.patch`). On always; there is deliberately no setting to
turn it off.

## Context

On 2026-10-04 at 15:12 the command-stream fuzzer ran on the MacBook's GPU. A
random stream made the GPU read address 0 (`gpuEvent`: "BIF0 page fault",
read, address 0). macOS reset the GPU, the reset hung WindowServer, and after
120 s the watchdog panicked the Mac. Everything running was lost.

A guest that can make the host GPU fault can take the whole Mac down: a
denial of service from inside the VM. On Linux hosts virglrenderer leans on
the host driver's robust buffer access (`ARB_robust_buffer_access_behavior`,
robust EGL contexts): out-of-range fetches return zero. Apple's OpenGL 4.1 has
no robust buffer access. Its GPU fetches what it is told: a vertex past the
end of a buffer, an index past the end of the index buffer, a uniform block
with no buffer bound (address 0), a transform feedback range past the buffer
(Apple's GL takes `glBindBufferRange` past the end; the fuzzer found that in
75 draws once it could see it).

vrend checked little of this: resource handles were checked for a non-zero GL
name only (a texture's name was then used as a buffer name), the index range
check wrapped at 32 bits and ignored the index size, vertex ranges, instance
ranges, uniform blocks and indirect commands were not checked at all, and a
shader's run-time array indexes went to the GPU as they came.

## Options

1. Robust contexts: not available on Apple's GL.
2. Translate GL to Metal ourselves with bounds-checked vertex pulling (what
   ANGLE does for WebGL on Metal): a new renderer, months of work.
3. Check on the CPU in vrend, before any GL call, that every range a draw
   reaches lies inside its buffers, and clamp run-time array indexes in the
   generated GLSL. Indexed draws need the largest index: read the indices
   back from the GL buffer, or keep a CPU shadow of index buffers with a cache
   (cheaper per draw, but every way a buffer can change, GPU writes included,
   must invalidate it; one missed path is a hole).
4. Patch the guest's Mesa to validate: the guest is untrusted, so no.

## Decision

3, with read-back: the GL buffer is the truth, whatever wrote it.
`glGetBufferSubData` of 12 KB of indices before each of 1000 draws cost
nothing measurable on an M4 Max (1.01 vs 1.01-1.15 ms per 1000 draws; mapping
instead would cost 95 us per draw, it waits for the GPU).

- Bindings (`virgl-buffer-binding-checks.patch`): only GL buffers at buffer
  binding points; uniform and stream output ranges clamped to the buffer;
  a buffer whose GL storage was not created fails to create.
- Draws (`virgl-draw-range-checks.patch`): vertices, instances and indices
  inside their buffers (64-bit math, index bias, primitive restart); indirect
  commands are read and drawn as checked direct draws.
- Uniform blocks (`virgl-uniform-buffer-checks.patch`): every active block has
  a buffer that covers its data size from the bound offset; all used blocks
  are bound on every draw.
- Shaders (`virgl-shader-index-clamp.patch`): run-time indexes into uniform
  blocks, the uniform store, sampler, image and temporary arrays are clamped,
  as WebGL implementations do.

A draw that fails a check is skipped and logged (three lines per context); the
context lives, like a refused shader (ADR 0016). A malformed binding (wrong
resource kind, misaligned stream output) loses the context, as upstream does
for bad handles.

Fuzzing never runs on the GPU again: the virgl tests and the fuzzer ask CGL for
Apple's software renderer and refuse to run on anything else (`soft-gl.h`), and
a GL oracle (`gl-oracle.c`) checks every GL draw call against the GL's own state
and aborts on any range a GPU would read or write outside a buffer.

## Coverage

Every way a guest number reaches GPU memory on macOS' OpenGL 4.1, and who checks it:

| Path | Check |
|---|---|
| vertex buffers (offset, stride, divisor) and draw first/count/instances | `virgl-draw-range-checks.patch` |
| index buffer (size, offset, count) and the index values | `virgl-draw-range-checks.patch` (read back) |
| indirect draws (command, draw count) | read on the CPU, drawn as checked direct draws |
| uniform buffers (bound range, block size, run-time indexes) | `virgl-buffer-binding-checks`, `virgl-uniform-buffer-checks`, `virgl-shader-index-clamp` |
| uniform store, sampler and temporary arrays (run-time indexes) | `virgl-shader-index-clamp.patch` |
| transform feedback ranges | `virgl-buffer-binding-checks.patch` (clamped, aligned) |
| query results into buffers | `virgl-buffer-binding-checks.patch` |
| texture uploads and readbacks through buffers (PBO), `glCopyBufferSubData`, `glTexBufferRange` | the GL itself: the spec makes these errors, checked on the CPU; vrend also checks boxes (`resource_contains_box`, transfer bounds) |
| blits | vrend checks the boxes; the GL clips to the framebuffers |
| texture fetches, texel fetches from buffer textures | bounded by the texture's size in hardware |
| storage buffers, atomic counters, images, compute | not on macOS' GL 4.1; bind ranges checked anyway, shader-side storage indexing is not |

Not covered: work that is valid but long (a draw of billions of vertices, a
shader that loops) can still trip the GPU's watchdog; that is a hang, handled by
the GPU's own recovery, not a memory fault.

## Consequences

- Conformance unchanged or better (test VM, M4 Max, 2026-10-04, runtime before
  = the previous gpu-robust runtime, after = this series):
  - dEQP GLES3 draw, instanced, vertex array, uniform block, transform
    feedback, primitive restart, buffer and indexing groups: 9196 cases, the
    same result per case; dEQP GLES3 every 50th case (896): the same per case.
    No draw was skipped by a check.
  - WebGL 2 conformance (transform_feedback, vertex_arrays, buffers, rendering,
    uniforms, attribs; 33 pages): 30 pass after, 29 before (draw-buffers.html
    now passes).
  - Chrome WebGL with a shader the host refuses keeps drawing (context-loss
    contain test, 2841/2841 frames right).
- Speed: glmark2 subset with the bench lock, runtimes alternating (others'
  VMs outside the pause rule kept running, so noisy): before 554, 477, 476 and
  354, 313, 350; after 576, 521, 510 and 612, 600, 615. No slowdown
  measurable.
- 30-minute soak (glmark2 loop, Chrome WebGL page, mpv 1080p60): pass, 77675
  WebGL frames, 0 dropped video frames, no GPU fault.
- Venus (gpu-venus's tree with this whole series, robust buffer access on,
  MoltenVK): 30-minute soak with vkmark, Chrome WebGL and mpv passes (twice);
  the Venus context-loss test passes. (The soak first hung the guest after
  6-10 minutes; the cause was a socket peek in the round-1 Venus fence patch,
  removed.)
- Apps that drew past their buffers (undefined in GL) now lose those draws
  instead of drawing garbage.
- GL buffers get up to 15 bytes of slack (rounded to 16) so a block declared
  as vec4 array fits a buffer sized to the C struct.
- Persistently mapped index buffers are refused (the guest could change the
  indices after the check). macOS' GL has no persistent buffers.
- Venus: Vulkan has the same exposure. `virgl-venus-robust-buffer-access.patch`
  turns on `robustBufferAccess` for every device whose host driver offers it
  (MoltenVK does), whatever the guest asked; without it the log says so once.
  Venus is off by default (ADR 0012).
- Varying and output arrays (GPU registers) are not clamped.
