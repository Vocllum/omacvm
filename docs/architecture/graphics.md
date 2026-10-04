# Graphics in OmacVM.app

How a frame gets from an app in Omarchy to the Mac's screen in OmacVM.app,
which thread does what, and where the time goes. One document for every
graphics track; each track keeps its own section current.

## The chain

```
app in the VM (OpenGL ES / GL, Chrome, Hyprland)
  -> Mesa virgl driver (Gallium, TGSI)            guest user space
  -> virtio-gpu kernel driver                     guest kernel: SUBMIT_3D, fences
  -> virtio-gpu-gl-pci in QEMU                    QEMU main loop, holds the BQL
  -> virglrenderer (vrend): TGSI -> GLSL          same thread
  -> Apple OpenGL 4.1 core (runs on Metal)        CGL contexts, one per guest context
  -> scanout texture of the guest's frame
  -> Cocoa display (ui/cocoa.m)                   IOSurface -> CALayer -> window
```

Hyprland renders the desktop through the same path: it is one more GL
client, and its output is the scanout that the window shows.

## Threads

| Thread | Runs | Lock |
|---|---|---|
| vCPU threads (HVF) | the guest; a queue kick traps here and schedules a bottom half | BQL only for device MMIO |
| QEMU main loop (`qemu_main`) | virtio-gpu commands, all of virglrenderer's GL work, the IOSurface blit | BQL |
| `vrend-sync` | waits for GPU fences (`glClientWaitSync`), reports each one through a bottom half | none (own CGL context) |
| `org.omacvm.present` queue | waits for an IOSurface's GPU work, hands it to the main thread | none (own CGL context) |
| AppKit main thread | window, input, sets the layer's contents | no BQL for drawing |

## Fences (gpu-native)

A guest frame waits for the fence of the frame before it (Mesa's
throttling), so the time from "guest submits" to "guest hears the fence is
done" sets the frame rate of anything light.

- Before: QEMU only used virglrenderer's sync thread with an EGL display.
  With Cocoa's CGL contexts it polled fences from a 1 ms timer
  (`qemu-darwin-gpu-fence-poll.patch`), on QEMU's millisecond virtual clock.
  Measured with QEMU's trace events: median 1.56 ms from fence to reply,
  so glmark2 could not get far past 1000 frames a second.
- Now (`qemu-cocoa-gl-async-fence.patch`, `virgl-darwin-thread-sync.patch`):
  the sync thread runs on macOS too (an unlinked FIFO opened read-write
  stands in for Linux's eventfd, also for Venus's render server) and
  reports each fence the moment the GPU is done: median 0.2 ms.
- A faster poll timer is no way around it: without `ppoll`, QEMU's main
  loop on macOS waits in whole milliseconds (tried: 50 us and 20 us timers
  give the same ~1100-1200 as 1 ms).
- Apple's `glClientWaitSync` spins (`gleTestSync`) until the fence signals.
  `virgl-darwin-fence-wait.patch` tests instead: busy for 100 us, then 50 us
  waits with `mach_wait_until` on a time-constraint thread (plain `nanosleep`
  is stretched by timer coalescing). QEMU's CPU during glmark2 195% -> 165%,
  Aquarium 194% -> 176%, same frame rates.
- Fallback: `OMACVM_VIRGL_POLL_FENCES=1`. QEMU's log says which path a VM
  took ("virgl fences reported by the sync thread" / "polled every 1 ms").

## Presenting a frame (gpu-native)

- Before: the guest's flush only marked the view dirty. The window redrew
  on QEMU's GUI refresh timer, which Cocoa leaves at 30 ms: at most 33
  frames a second in the window, while Omarchy rendered at 120. The redraw
  ran in a `CAOpenGLLayer` on the main thread and took the BQL.
- Now (`qemu-cocoa-gl-present-on-flush.patch`): a flush asks for a redraw
  at once.
- Now (`qemu-cocoa-gl-present-iosurface.patch`): on QEMU's thread the
  scanout texture is drawn into one of three IOSurfaces with a context of
  its own; a serial queue waits for that GPU work, then the main thread sets
  the surface as the layer's contents. No GL and no BQL on the main thread.
  At most one surface per display refresh (a timer catches up with the
  newest frame); a surface is reused only when Core Animation is done with
  it (`IOSurfaceIsInUse`).
- One GPU copy per shown frame remains (scanout texture -> IOSurface). Making
  the guest's own scanout textures IOSurfaces would remove it, but CGL only
  binds IOSurfaces as rectangle textures, which the guest's shaders do not
  sample (see ADR 0010).
- Fallback: `OMACVM_GL_PRESENT=layer` (also taken automatically when the
  IOSurface contexts cannot be made); the log says which ("GL frames shown
  as IOSurfaces"). `OMACVM_GL_FPS=1` logs frames shown per second;
  `OMACVM_GL_DUMP=FILE` writes a frame shown whenever FILE is missing.

## Blob memory and Venus groundwork (gpu-native, for gpu-venus)

- OpenGL gets nothing from blobs here: Mesa's virgl driver uses them only
  for persistent, coherent buffer mappings (ARB_buffer_storage), and
  virglrenderer can offer those only with `glBufferStorage`, which Apple's
  OpenGL 4.1 does not have. Blobs matter for Venus (Vulkan).

- HVF maps guest memory in 16 KiB pages and macOS 15 has no 4 KiB granule
  (`hv_vm_config_set_ipa_granule` is macOS 26). A 4 KiB guest places blobs on
  4 KiB boundaries, so a host-visible blob (Venus memory) could not be
  mapped. `qemu-virtio-gpu-blob-alignment.patch` offers
  `VIRTIO_GPU_F_BLOB_ALIGNMENT` with the host page size: Linux 7.x and
  Mesa 26's Venus driver then size and place every blob on 16 KiB.
- `virgl-darwin-venus-in-process.patch`: Venus's render server runs as a
  thread of QEMU (Metal heaps cannot cross processes).

## Where the time goes (gpu-native)

- Light frames (glmark2, the desktop): the fence round trip. Fixed above.
- Heavy browser frames (WebGL Aquarium, 30,000 fish): QEMU's render thread
  is busy all the time, and most of it is Apple's OpenGL itself (about 60%:
  pipeline-state lookups and texture validation for every draw); the kernel
  (main-loop polls, the user network, the BQL) about 14%; virglrenderer only
  about 9%. Faster fences do not change Aquarium (about 21 fps before and
  after). Tuning virglrenderer can win little; a render thread of its own,
  away from QEMU's main loop, maybe 10%. The large step is not to go through
  Apple's OpenGL at all: Vulkan (Venus) with Zink for OpenGL, see gpu-venus.
- Not levers: ANGLE on Metal as the host GL (`gl=es`): the guest gets only
  OpenGL 2.1 and glmark2 drops to about 700. Sleeping between fence tests:
  macOS sleeps far longer than asked, Aquarium fell to 7-15 fps.

## Shaders and limits on Apple's GL (gl-compat)

virglrenderer was written for Linux drivers. Where Apple's OpenGL 4.1 core profile
disagrees, one refused shader or one GL error used to put the guest's whole virgl
context in error (`vrend_report_context_error`): everything that app drew later was
black, and the guest was never told. Fixed in the translation and the caps (ADR 0019),
one patch each, each with a build-time test that compiles or runs on the Mac's GL:

| Gap on the Mac | Patch | Test (`app/runtime/Tests/virgl`) |
|---|---|---|
| floatBitsToInt() etc. need GLSL 3.30; `GL_ARB_draw_instanced` refused | `virgl-shader-core-glsl-version.patch` | `test-core-glsl-shaders.c` |
| `GL_EXT_texture_shadow_lod` asked for core lookups (gradients, cube shadow bias, gather) | `virgl-shader-shadow-lod-extension.patch` | `test-core-glsl-shaders.c` |
| results written to an integer output lost their bits or did not compile (upstream bug) | `virgl-shader-integer-outputs.patch` | `test-core-glsl-shaders.c` |
| blitter shaders were GLSL 1.30: every shader blit drew nothing | `virgl-blitter-core-glsl-version.patch` | `test-blitter-shaders.c` |
| integer multisample blit used texture() on a MS sampler (upstream bug) | `virgl-blitter-integer-msaa.patch` | `test-blitter-shaders.c` |
| framebuffer without attachments (all draw buffers GL_NONE): GL error on draw | `virgl-framebuffer-no-attachments.patch` (depth stand-in as large as the viewports, depth test off while it is there) | `test-empty-framebuffer.c` |
| guest told 32 samplers per stage, the Mac has 16 | `virgl-caps-sampler-limit.patch` (smallest limit of all stages) | `test-sampler-limit.c` |

The patches apply after gpu-native's and only touch `vrend_shader.c`,
`vrend_blitter.[ch]` and `vrend_renderer.c` (framebuffer state, caps).
`virgl-shader-core-glsl-version.patch` covers gpu-robust's `virgl-core-instance-id.patch`
(same loop in `emit_header`); both apply in either order, drop that one when both land.
gpu-robust's containment (refused shader skips its draws) is the safety net for gaps
not found yet.

Measured with tests/graphics (branch conformance-runs; VK-GL-CTS vulkan-cts-1.4.6.2,
WebGL conformance 1.0.4 and 2.0.0, Chrome 154; transform feedback left out, see
gpu-robust). "One process" = one dEQP process for the whole list, one Chrome for every
page, as apps run; "isolated" = restarted after every failure. Before = gpu-native's
runtime with gpu-hang's integer sampler fix (conformance-runs' gn-v4h); after = this
branch. Correctness runs, no bench lock.

| Suite | before, one process | before, isolated | after, one process | after, isolated |
|---|---|---|---|---|
| dEQP-GLES2, every 20th case (859) | 853 | 853 | 853 | 853 |
| dEQP-GLES3, every 50th case (869) | 455 of 896 (with TF, 12 QEMU crashes) | 812 + 24 QW | 855 + 3 QW | 855 + 3 QW |
| WebGL 1 pages (787) | 430 | 776 | 776 | 776 |
| WebGL 2 pages (967 without TF) | 97 of 970 | 960 of 970 | 959 | 959 |
| dEQP-GLES2, whole list (17165) | 16971 | | 16972 | 16972 |
| dEQP-GLES3, whole list (43448) | 21140 + 1116 QW | | 42832 + 104 QW | 42832 + 104 QW |

After the patches the one-process numbers equal the isolated ones, case by case. Against
the isolated "before" no case got worse; 22 dEQP-GLES3 cases (stride) and WebGL 2
`rendering/draw-buffers.html` pass now. The QEMU log of the one-process runs has no
context error. What still fails fails in both modes: cube map filtering, one blit
format conversion (rgb8 to rg32f), 11 WebGL 1 and 8 WebGL 2 pages, and the
transform feedback crash that gpu-robust fixes
(`lifetime.attach.deleted_output.buffer_transform_feedback`).

## Measuring

Test VM: 8 CPUs, 16 GB, Omarchy in a window on the Mac's built-in display,
in the Hyprland session. Every number with the tracks' benchmark lock held
(the other test VMs paused). Scripts and raw results are in the gpu-native
track notes.

| | rc-2.6.0 | this branch |
|---|---|---|
| glmark2 full run (`--fullscreen`) | 1125-1388 | 3576-4117 |
| glmark2 short set, same session | 1096-1139 | 3859-4111 |
| fence to reply (median, QEMU trace) | 1.56 ms | 0.20 ms |
| frames shown in the window, desktop animation | 33/s at most | mean 58, max 90 (120 Hz display) |
| WebGL Aquarium 30k (Chrome) | 21.2-21.6 fps | 21.4-22.9 fps |
| QEMU CPU during Aquarium | ~160% | ~176% |
