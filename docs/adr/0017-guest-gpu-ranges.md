# 0017: The host checks every buffer range a guest draw reaches

Status: accepted. Built on `gpu-robust` (`virgl-buffer-binding-checks.patch`,
`virgl-draw-range-checks.patch`, `virgl-uniform-buffer-checks.patch`,
`virgl-shader-index-clamp.patch`, and after the first review
`virgl-vertex-format-checks.patch`, `virgl-uniform-buffer-alignment.patch`,
`virgl-uniform-block-array.patch`, `virgl-draw-gl-error-check.patch`). On
always; there is deliberately no setting to turn it off.

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

The first review of this work found three more ways through, all of one kind:
the GL refuses a call and keeps what was there before. A vertex format the GL
refuses (`B8G8R8A8_UINT`: GL_BGRA is only for normalized bytes) left the
attribute on the previous, smaller buffer; an unaligned uniform buffer offset
left the binding on the previous buffer; and a uniform block array with a hole
(blocks 1 and 3) was named wrongly, so one element was never bound and read
binding 0, another stage's buffer. The checks judged what the guest asked for,
the GPU used what the GL still had.

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

3, with read-back: the GL buffer is the truth, whatever wrote it. The cost is
in "Consequences"; mapping instead of reading back would wait for the GPU
(95 us per draw).

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
- What the GL would refuse is refused first: vertex formats it does not take
  (`virgl-vertex-format-checks.patch`) and buffer offsets that break
  `GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT` and the storage and atomic counter
  rules (`virgl-uniform-buffer-alignment.patch`) lose the context, like other
  malformed bindings; Mesa never sends them (it reads the caps).
- Uniform block arrays (`virgl-uniform-block-array.patch`): a run-time block
  index sees one array from the first to the last block the shader declares,
  holes included, and the renderer names, binds and checks every element.
  Before vrend binds a program's blocks they all point at a binding vrend
  never fills; a block still there afterwards skips the program's draws.
- Anything else the GL refuses (`virgl-draw-gl-error-check.patch`): right
  before each GL draw call vrend asks for GL errors; one means some setup
  call was refused and older state is in place, so the draw is skipped. The
  two checks above close the known cases; this one is for the unknown ones.

A draw that fails a check is skipped and logged (three lines per context); the
context lives, like a refused shader (ADR 0016). A malformed binding (wrong
resource kind, misaligned stream output) loses the context, as upstream does
for bad handles.

Fuzzing never runs on the GPU again: the virgl tests and the fuzzer ask CGL for
Apple's software renderer and refuse to run on anything else (`soft-gl.h`), and
a GL oracle (`gl-oracle.c`) checks every GL draw call against the GL's own state
and aborts on any range a GPU would read or write outside a buffer, and on a GL
error pending at the draw (a refused call). Fuzzing is not proof of coverage:
about 900,000 inputs with no oracle abort never produced the three refused-call
cases above, which the review built by hand.

## Coverage

Every way a guest number reaches GPU memory on macOS' OpenGL 4.1, and who checks it:

| Path | Check |
|---|---|
| vertex buffers (offset, stride, divisor) and draw first/count/instances | `virgl-draw-range-checks.patch` |
| index buffer (size, offset, count) and the index values | `virgl-draw-range-checks.patch` (read back) |
| indirect draws (command, draw count) | read on the CPU, drawn as checked direct draws |
| vertex attribute formats the GL refuses | `virgl-vertex-format-checks.patch`; any other refusal: `virgl-draw-gl-error-check.patch` |
| uniform buffers (bound range, block size, run-time indexes) | `virgl-buffer-binding-checks`, `virgl-uniform-buffer-checks`, `virgl-shader-index-clamp` |
| uniform and storage buffer offset alignment | `virgl-uniform-buffer-alignment.patch` |
| uniform block arrays (element names, bindings) | `virgl-uniform-block-array.patch` |
| uniform store, sampler and temporary arrays (run-time indexes) | `virgl-shader-index-clamp.patch` |
| transform feedback ranges | `virgl-buffer-binding-checks.patch` (clamped, aligned) |
| query results into buffers | not on macOS (needs GL 4.4 query buffer objects); `virgl-buffer-binding-checks.patch` checks the range anyway |
| texture uploads and readbacks through buffers (PBO), `glCopyBufferSubData`, `glTexBufferRange` | the GL itself: the spec makes these errors, checked on the CPU; vrend also checks boxes (`resource_contains_box`, transfer bounds) |
| blits | vrend checks the boxes; the GL clips to the framebuffers |
| texture fetches, texel fetches from buffer textures | assumed bounded by the texture's size in hardware; not tested on Apple's GL |
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
    No draw was skipped by a check. After the review fixes: the 9196 cases
    again the same per case (final runtime, aefb119), the every-50th sample
    too (first version of the fixes); no draw skipped, no GPU fault.
  - WebGL 2 conformance (transform_feedback, vertex_arrays, buffers, rendering,
    uniforms, attribs; 33 pages): 30 pass after, 29 before (draw-buffers.html
    now passes).
  - Chrome WebGL with a shader the host refuses keeps drawing (context-loss
    contain test, 2841/2841 frames right).
- Speed: not shown either way. glmark2 subset with the bench lock, runtimes
  alternating, one run each (four other QEMUs outside the pause rule kept
  running): before 554, 477, 476 and 354, 313, 350; after 576, 521, 510 and
  612, 600, 615. The spread is larger than any effect: no slowdown is
  visible, a few percent cannot be ruled out. The dEQP range run took 216 s
  before, 273 s with this series and 183 s after the review fixes, all
  without the lock; those times say nothing about speed.
- Index read-back (`glGetBufferSubData` and a scan for the largest index
  before every indexed draw) grows with the index count. Measured on the M4
  Max with the bench lock (2 test QEMUs paused, 3 outside the pause rule
  running), median of 3, extra time per draw: 12 KB of indices: not
  measurable (under 1 us); 1 MB: 0.03 ms; 4 MB: 0.11 ms (about 0.03 ms per
  MB). A frame that draws 40 MB of indices would pay about 1 ms. Tool:
  `app/runtime/Tests/virgl/bench-index-readback.c`. (The first version of
  this ADR quoted "1.01 vs 1.01-1.15 ms per 1000 draws" from an unlocked run
  of 12 KB draws only.)
- The draw-state check adds one `glGetError` per GL draw call; vrend already
  calls it after every guest command.
- 30-minute soak (glmark2 loop, Chrome WebGL page, mpv 1080p60): pass, 77675
  WebGL frames, no GPU fault. After the review fixes: pass, 83572 WebGL
  frames, 0 heartbeat misses, no draw skipped, no GPU fault. mpv dropped
  frames in both (up to about 750 per 20-second loop; the Mac was loaded with
  other VMs and the fuzzer); the soak summary shows only the last loop, which
  the first version of this ADR read as "0 dropped".
- Fuzzing after the review fixes (software renderer, oracle with the pending
  error check): 30 minutes, about 355,000 inputs, no oracle abort, no crash;
  one slow input (shader parsing under ASan, 1.4 s without it).
- Venus (gpu-venus's tree with this whole series, robust buffer access on,
  MoltenVK): 30-minute soak with vkmark, Chrome WebGL and mpv passes (twice);
  the Venus context-loss test passes. (The soak first hung the guest after
  6-10 minutes. Removing a socket peek from the round-1 Venus fence patch made
  it pass; why the peek hung the guest is not known. It consumes nothing and,
  tested, does not drop passed file descriptors. An empirical fix, open until
  the cause is found.)
- Apps that drew past their buffers (undefined in GL) now lose those draws
  instead of drawing garbage.
- GL buffers get up to 15 bytes of slack (rounded to 16) so a block declared
  as vec4 array fits a buffer sized to the C struct.
- Persistently mapped index buffers are refused (the guest could change the
  indices after the check). macOS' GL has no persistent buffers.
- Venus: Vulkan has the same exposure. `virgl-venus-robust-buffer-access.patch`
  turns on `robustBufferAccess` for every device whose host driver offers it
  (MoltenVK does), whatever the guest asked; without it the log says so once.
  It is not shown to protect anything: MoltenVK reports the feature on every
  Apple GPU, and no test has made an out-of-range Vulkan access to see it
  contained (that test would have to run on the real GPU). Its cost was not
  measured. Venus is off by default (ADR 0012).
- Varying and output arrays are not clamped; they are assumed to live in GPU
  registers, which was not tested.
