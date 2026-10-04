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

## Consequences

- Conformance unchanged: dEQP GLES3 draw, instanced, vertex array, uniform
  block, transform feedback, primitive restart, buffer and indexing groups
  (9196 cases) give the same result per case before and after; no draw was
  skipped by a check.
- Apps that drew past their buffers (undefined in GL) now lose those draws
  instead of drawing garbage.
- GL buffers get up to 15 bytes of slack (rounded to 16) so a block declared
  as vec4 array fits a buffer sized to the C struct.
- Persistently mapped index buffers are refused (the guest could change the
  indices after the check). macOS' GL has no persistent buffers.
- Not covered: Venus. Vulkan has the same problem without robust buffer
  access; Venus is off by default (ADR 0012). Enabling `robustBufferAccess`
  on the host device where MoltenVK/KosmicKrisp offer it is the next step.
- Varying and output arrays (GPU registers) are not clamped.
