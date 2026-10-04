# Graphics in OmacVM.app

How a frame (and a video frame) gets from an app in Omarchy to the Mac's
screen in OmacVM.app: the chain, the threads and locks, fences, who owns
which memory, the settings and fallbacks, what the guest may and may not
do, and how we test it. One document for every graphics track; each track
keeps its section current. Decisions with trade-offs are in
[../adr/](../adr/).

Status words used below:

- **shipped**: in `rc-2.6.0` (what users run).
- **built**: on a track branch, built and tested there, not merged yet.
  The branch is named.
- **planned**: designed, not written, or blocked.

The other routes (Parallels, UTM, Fusion) use their vendor's graphics stack;
this page is only about OmacVM.app's own QEMU.

## 1. The chain

### Today (shipped)

```
 app in the VM (Hyprland, Chrome, glmark2, ...)          GL / GLES
   |
 Mesa virgl driver (Gallium -> TGSI text)                guest user space
   |
 virtio-gpu kernel driver (DRM)                          guest kernel
   |   SUBMIT_3D, RESOURCE_*, fences, one ctrl queue
   v
 QEMU virtio-gpu-gl-pci  (hw/display/virtio-gpu-virgl.c) QEMU main loop, BQL
   |
 virglrenderer 1.3.0 + macOS patches (vrend)             same thread
   |   TGSI -> GLSL 4.1, state tracking
   v
 Apple OpenGL 4.1 core (CGL, runs on Metal)              one CGL context per guest context
   |
 scanout texture (borrowed by QEMU, no readback)
   |
 QEMU Cocoa display, gl=on: CAOpenGLLayer                AppKit main thread, takes the BQL
   v
 the VM window (one window, one output Virtual-1)
```

Hyprland renders the desktop through the same path: it is one more GL
client, and its output is the scanout the window shows.

QEMU is commit `c3d48b7` (11.1 line), virglrenderer 1.3.0 with the
patches from `startergo/homebrew-virglrenderer` 1.0.42 (MTLHeap export,
Apple GL fixes), then ours. All pinned by sha256 in
`app/runtime/build-qemu-gpu-runtime.sh`. ANGLE and libepoxy bottles are
linked for QEMU's EGL code; with `-display cocoa,gl=on` OmacVM.app renders
on CGL, not on ANGLE.

### Target design

```
 guest apps
   |                \                         \
 Mesa virgl (GL)    Mesa venus (Vulkan)       VA-API (Chrome, Firefox, mpv)
   |                 + Zink (GL on Vulkan)      Mesa virgl video
   |                  [planned, needs           |
   |                   KosmicKrisp]             |
   v                 v                          v
 virtio-gpu: ctrl queue, blob resources, hostmem window, 16 KiB blob alignment,
             up to 5 outputs (Virtual-1..5)
   |
 QEMU virtio-gpu-gl-pci (blob=true, venus=true, hostmem=4G when Venus is on)
   |  ctrl queue decoded on the main loop today; async (kick -> render
   |  thread) planned
   v
 virglrenderer
   +-- vrend (GL contexts)       -> Apple OpenGL 4.1 (CGL)
   +-- venus (render server as   -> Vulkan loader -> MoltenVK (macOS 15)
   |   a thread of QEMU)                           -> KosmicKrisp (macOS 26+)
   |                                                   -> Metal
   +-- video (virgl_video_vt.c)  -> VideoToolbox (the Mac's media engine)
   |                                -> IOSurface planes -> GL blit into the
   |                                   guest's textures
   +-- vrend-sync thread: fences signalled as the GPU finishes
   v
 scanout texture of each output
   |  blit on QEMU's thread into one of three IOSurfaces
   v
 CALayer.contents = IOSurface  (Core Animation composites it)
   |
 one window per Mac display in full screen, one window when windowed
```

| Piece | Status | Where |
|---|---|---|
| virgl GL on Apple OpenGL 4.1 | shipped | `virgl-native-opengl.patch`, tap patches |
| Scanout texture borrowing (no readback) | shipped | `qemu-texture-borrowing-11.1.patch` |
| Integer-sampler shader fix (Basemark hang) | built: `gpu-hang` | `virgl-texture-integer-samplers.patch` |
| gl_InstanceID shaders compile on Apple's core profile | built: `gpu-robust` | `virgl-core-instance-id.patch` |
| Refused shader skips its draws (context lives) | built: `gpu-robust` | `virgl-shader-failure-skip-draws.patch`, section 13 |
| Context loss reported to the guest (GL robustness) | built: `gpu-robust`; guest Mesa not installed by default | `virgl-context-loss-report.patch`, `src/app/guest/mesa/` |
| Async fences (vrend-sync thread on macOS) | built: `gpu-native`, open hang | `qemu-cocoa-gl-async-fence.patch`, `virgl-darwin-thread-sync.patch` |
| Present on each flush | built: `gpu-native` | `qemu-cocoa-gl-present-on-flush.patch` |
| IOSurface present | built: `gpu-native` | `qemu-cocoa-gl-present-iosurface.patch` |
| Blob alignment for 16 KiB pages | built: `gpu-native`, `gpu-venus` | `qemu-virtio-gpu-blob-alignment.patch` |
| Venus on MoltenVK | built: `gpu-venus`, hidden switch | see section 6 |
| KosmicKrisp on macOS 26 | planned | ICD choice already in `virgl-darwin-vulkan-beside.patch` |
| Zink, rusticl, ANGLE-on-Vulkan in Chrome | planned, blocked on MoltenVK (no `nullDescriptor`) | - |
| VideoToolbox decode | built: `video-decode` | `virgl-videotoolbox-decode.patch` |
| One window per display | built: `app-displays` | `omacvm-cocoa-displays.patch` |
| Async ctrl queue (guest keeps encoding while the host runs) | planned | finding from `browser-gpu` |
| Guest scanout textures as IOSurfaces (zero copy present) | planned | ADR 0010 option 3 |

## 2. Processes and threads

Everything runs in one process: QEMU (`qemu-system-aarch64`, hardened
runtime, started by the Swift launcher). There is no separate GPU process
and no render server process on macOS (ADR 0012).

```
 qemu-system-aarch64
 +-------------------------------------------------------------------------+
 | vCPU threads (HVF) x N                                                  |
 |   guest runs; a queue kick is an MMIO exit -> takes the BQL             |
 |                                                                         |
 | QEMU main loop  [BQL]                                                   |
 |   virtio-gpu ctrl + cursor queues, virglrenderer (vrend), all GL work,  |
 |   VideoToolbox decode calls, scanout -> IOSurface blit (built)          |
 |                                                                         |
 | vrend-sync      [no BQL, own CGL context]            (built: gpu-native)|
 |   glClientWaitSync on each fence, then wakes the main loop (fd)         |
 |                                                                         |
 | venus render server thread + vkr ring threads   (built: gpu-venus)      |
 |   [no BQL] decode the Venus ring, call Vulkan (MoltenVK)                |
 |                                                                         |
 | org.omacvm.present serial dispatch queue  [no BQL]  (built: gpu-native) |
 |   waits for an IOSurface's blit fence, hands it to the main thread      |
 |                                                                         |
 | VideoToolbox callback threads  [no BQL]             (built: video)      |
 |   receive decoded CVPixelBuffers                                        |
 |                                                                         |
 | AppKit main thread                                                      |
 |   windows, input, sets layer.contents; takes the BQL for input and,     |
 |   in the shipped CAOpenGLLayer path, for drawing                        |
 +-------------------------------------------------------------------------+
 VTDecoderXPCService (macOS process): the actual hardware decode
```

Rules:

- All vrend GL calls happen on the main loop, with the BQL. virglrenderer
  is not thread safe for vrend contexts; nothing else may call into it
  except the callbacks it documents (fence retire, `write_fence`).
- `vrend-sync` has its own CGL context shared with vrend's, only waits on
  sync objects, and never touches guest-visible state. It signals by writing
  one byte to an fd; the main loop reads it and retires fences there.
- The present queue and the main thread never take the BQL to draw
  (IOSurface path). The CAOpenGLLayer fallback does: the main thread draws
  inside `drawInCGLContext` holding the BQL.
- Venus threads do not take the BQL; they talk to the main loop only
  through the proxy's fence fd and resource callbacks.
- Head windows (one per extra display) share the main view's GL context
  (`gl_view_ctx`); all their drawing happens under the same rules.

Rule for new code: where both are needed, take the BQL first, then any
virglrenderer internal mutex. Never wait for the BQL from a Core Animation
callback in a new path (the shipped `drawInCGLContext` does, and that is
why the main thread and QEMU waited on each other every frame).

## 3. A frame, step by step

1. The app draws; Mesa encodes commands into a command buffer (256 KiB).
   When it is full or the app flushes, the kernel sends `SUBMIT_3D` with a
   fence.
2. The vCPU kicks the ctrl queue. HVF has no ioeventfd, so the kick is an
   MMIO exit and the vCPU waits there while QEMU's main loop decodes the
   **whole** queue (`virtio_gpu_process_cmdq`). Chrome's GPU process spends
   about a third of its time in this kick (`browser-gpu` perf).
3. vrend turns TGSI into GLSL (cached per shader) and makes the GL calls on
   Apple's OpenGL. Apple's per-draw cost (state revalidation) dominates
   draw-call heavy WebGL (Aquarium 30k fish, about 34 submits per frame).
4. The fence: a `glFenceSync` is placed after the submit.
   - shipped: a 1 ms QEMU timer polls fences (`qemu-darwin-gpu-fence-poll.patch`).
     Median fence-to-reply 1.56 ms, so light scenes cap near 1000 frames/s.
   - built: `vrend-sync` waits and reports at once: median 199 us.
5. Hyprland composites and page-flips; virtio-gpu sends
   `RESOURCE_FLUSH`/`SET_SCANOUT`. QEMU borrows the scanout texture (no
   readback).
6. Present:
   - shipped: the view is marked dirty; Cocoa redraws on QEMU's GUI refresh
     tick (30 ms), so the window shows at most 33 frames/s.
   - built: each flush asks for a redraw; QEMU's thread blits the scanout
     into one of three IOSurfaces, the present queue waits for that blit,
     the main thread sets `layer.contents`. At most one surface per display
     refresh; a surface is reused only when `IOSurfaceIsInUse` is false.
7. Core Animation composites the surface into the window.

## 4. Fences

| Kind | Who creates it | Who signals | Path today |
|---|---|---|---|
| virgl context fence (GL) | guest `SUBMIT_3D` + fence flag | vrend: `glClientWaitSync` done | shipped: 1 ms poll; built: `vrend-sync` |
| Venus fence | guest ring + `SUBMIT_3D` | render server thread writes the proxy's fence fd | built: needs the fd to be writable (see below) |
| Present fence | QEMU's IOSurface blit | GL sync, waited on the present queue | built |
| Video decode | VideoToolbox callback | buffer kept until the GPU copy is done (last 3 retained) | built |

macOS has no `eventfd`. `virgl-darwin-thread-sync.patch` uses an unlinked
FIFO opened read-write: one fd that can be written and read, also after
`dup` or when passed over the proxy socket. A pipe did not work: Venus's
server writes the fd it was given, and a pipe's read end cannot be written,
so Venus fences never retired (found by `gpu-venus`, fixed in `gpu-native`
`9b176fa`).

Open problem (`gpu-native`, 2026-10-04): in a 30 min glmark2 soak with async
fences the guest froze after 4-5 min. QEMU idle, `vrend-sync` blocked in
`glClientWaitSync` on a fence that never signals. Not a lock deadlock.
Being traced with a debug build. **Until this is fixed, async fences are
not safe to ship**; the 1 ms poll stays the default for a release.

Cost of async fences: Apple's `glClientWaitSync` spins (`gleTestSync`), so
`vrend-sync` uses about half a core while the guest renders.

## 5. Memory ownership

| Memory | Owner | Lifetime | Guest sees |
|---|---|---|---|
| Guest RAM | QEMU (HVF mapping, 16 KiB pages) | VM | itself |
| Classic resources (non-blob) | guest pages as backing + a host GL texture/buffer owned by vrend | until `RESOURCE_UNREF` | its own backing pages; transfers copy |
| Scanout texture | vrend; QEMU only borrows it per frame | until the guest replaces the scanout | nothing extra |
| Present IOSurfaces (3 per window) | QEMU Cocoa code | window; reused when not in use by Core Animation | nothing |
| Blob resources, host-visible (Venus) | MoltenVK `MTLHeap` in QEMU's process | until unref; mapped into the hostmem BAR | a window in the hostmem PCI BAR (4 GiB of address space, costs no RAM until used) |
| VideoToolbox pixel buffers | VideoToolbox pool; we retain the last 3 | until the GPU copy into the guest texture is done | never; copied into the guest's plane textures |

Rules:

- The guest never gets a host pointer. Blob memory reaches it only as a
  mapping inside QEMU's hostmem region, at an offset QEMU chooses.
- HVF maps in 16 KiB pages and macOS 15 has no 4 KiB IPA granule
  (`hv_vm_config_set_ipa_granule` is macOS 26). QEMU offers
  `VIRTIO_GPU_F_BLOB_ALIGNMENT` with the host page size, and rounds a blob's
  host mapping up to whole pages (`qemu-virtio-gpu-blob-alignment.patch`).
  Guest Mesa must round blob sizes too: Mesa 26.2.4 and later do, Arch Linux
  ARM's 26.2.3 does not (Venus fails with `EINVAL`).
- QEMU 11 mapped blobs with `mmap(MAP_FIXED)` into hostmem; HVF keeps the
  pages it got from `hv_vm_map`, so the guest saw stale memory.
  `qemu-hvf-virgl-blob-subregion.patch` maps a memory subregion instead.
- Metal heaps are pointers in one process, which is why the Venus server
  runs in process (ADR 0012).

## 6. Vulkan: Venus (built: `gpu-venus`)

```
 guest Vulkan app -> Mesa venus (vulkan-virtio) -> virtio-gpu ring in a blob
   -> QEMU -> virglrenderer proxy -> render server THREAD (in process)
   -> vkr (venus renderer) -> libvulkan.1.dylib (in the runtime)
   -> ICD: MoltenVK 1.4.2 (macOS 15) | KosmicKrisp (macOS 26+, planned)
   -> Metal
```

Patches (all in `app/runtime/patches`, one per concern):

- `virgl-darwin-venus-in-process.patch` + `-Drender-server-worker=thread`
- `virgl-darwin-stream-sockets.patch`: macOS has no `AF_UNIX SOCK_SEQPACKET`;
  stream sockets with fixed framing.
- `virgl-darwin-vulkan-beside.patch`: load the loader beside
  libvirglrenderer, pick the ICD by macOS version, `MVK_CONFIG_USE_MTLHEAP=1`.
- `virgl-darwin-venus-heap-check.patch`: a NULL heap fails cleanly (QEMU
  crashed in `CFRetain`).
- `virgl-darwin-venus-ext-table.patch`: a tap patch shifted the extension
  table by one entry.
- `qemu-hvf-virgl-blob-subregion.patch`, `qemu-virtio-gpu-blob-alignment.patch`.

Switch: `defaults write org.omacvm.app venus -bool true` adds
`blob=true,venus=true,hostmem=4G` to the GPU device. Off by default: the
guest needs Mesa with blob rounding.

Limits: MoltenVK has no `nullDescriptor`, no geometry shaders, no logicOp,
no float64. So Zink (GL on Vulkan) and ANGLE-on-Vulkan in Chrome do not
work; they wait for KosmicKrisp, which needs Metal 4 (macOS 26). See
ADR 0013. Frame latency is Venus's ring polling (guest `vn_relax`, host
`vkr_ring_relax`), about 1.3 ms per frame: vkmark ~800 is latency, not GPU.

## 7. Video decode (built: `video-decode`)

```
 Chrome / Firefox / mpv -> libva -> Mesa virtio_gpu_drv_video.so
   (Firefox/mpv via the omacvm VA shim that hides I420/YV12)
   -> virgl video commands in SUBMIT_3D
   -> vrend_video.c -> virgl_video_vt.c
        H.264: SPS/PPS rebuilt from picture params
        VP9:   one frame at a time (hidden frames too)
        AV1:   the frame's OBUs cut from the TU (Chrome only)
        HEVC:  Main / Main 10 (SPS short-term RPS limits apply)
   -> VTDecompressionSession (real-time, hardware)
   -> CVPixelBuffer (IOSurface planes)
   -> CGLTexImageIOSurface2D (rect texture) + glBlitFramebuffer
      into the guest's plane textures (0.5 ms per 4K frame; CPU copy 5.5 ms)
```

Decode calls run on QEMU's main loop under the BQL (about 5 ms per 4K VP9
frame of waiting; two 4K streams contend). Moving the wait off the main loop
is planned. Why VideoToolbox sits inside virglrenderer's video path: ADR 0014.

## 8. Displays (built: `app-displays`)

```
 Mac display 1 (window, Virtual-1)  Mac display 2 (Virtual-2) ... up to 5
        |                                 |
 QEMU cocoa main view               head window: own DisplayChangeListener,
 (console 0)                        CAOpenGLLayer sharing gl_view_ctx (console N)
        \______________ virtio-gpu, max_outputs=5 _______________/
                               |
 virtio-serial port org.omacvm.display  <->  omacvm-displays (guest agent)
   QEMU -> guest: {"layout": [...points...], "external", "fullscreen"}
   guest -> QEMU: {"hello":1,"external":bool}, {"monitors":[...]}
```

- Heads are created only after the guest agent says hello, and only in full
  screen with "Use external displays" on. Windowed: one window, one output.
- Linux virtio-gpu has no suggested position, so positions travel over the
  port. One virtio-tablet: QEMU maps window-local pointer positions into the
  bounding box of all monitors the guest reported.
- `qemu-virtio-gpu-display-event-race.patch`: a second display change while
  Linux reads the outputs was lost.
- Head windows still draw with CAOpenGLLayer; moving them to the IOSurface
  present is part of merging `gpu-native` and `app-displays` (one present
  path for every head). ADR 0015.

## 9. Settings and fallbacks

Every new path has a safe default and a way back to today's path. A failure
falls back and logs once.

| Setting | Default | Effect | Status |
|---|---|---|---|
| `OMACVM_VIRGL_POLL_FENCES=1` | off | back to the 1 ms fence poll | built (`gpu-native`) |
| `OMACVM_GL_PRESENT_ON_TICK=1` | off | redraw on QEMU's 30 ms tick again | built |
| `OMACVM_GL_PRESENT=layer` | iosurface | CAOpenGLLayer path; also taken by itself if the IOSurface contexts fail | built |
| `OMACVM_GL_FPS=1` | off | log frames shown per second | built |
| `OMACVM_GL_DUMP=FILE` | off | write a shown frame as PPM (orientation/colour check) | built |
| `defaults write org.omacvm.app venus -bool true` | false | Venus device options | built (`gpu-venus`) |
| `OMACVM_VULKAN_DRIVER` | by macOS version | force an ICD file | built |
| `OMACVM_VIDEO_DECODE=0` | on | no video caps offered; guest decodes in software | built (`video-decode`) |
| `OMACVM_VIDEO_AV1=1` | set by the app when the VM has the shim | offer AV1 | built |
| `OMACVM_VIDEO_NO_VP9`, `OMACVM_VIDEO_NO_HEVC` | off | hide one codec | built |
| `OMACVM_VIDEO_COPY` | off | CPU copy instead of IOSurface blit | built |
| `OMACVM_VIDEO_NO_REALTIME` | off | no real-time VT session | built |
| `OMACVM_VIRGL_VIDEO_ABI=legacy` | Mesa 26 numbers | profile numbers of older guests | built |
| `OMACVM_VIDEO_DEBUG=1` | off | log decode details | built |
| "Use external displays" (Omarchy display panel, stored in the VM) | toggle in the VM | one output per Mac display | built (`app-displays`) |
| `OMACVM_MAX_OUTPUTS`, `OMACVM_DISPLAY_SOCKET` | set by the launcher | heads and agent socket | built |
| `OMACVM_DISPLAYS_DEBUG=1` | off | log the display port | built |
| `OMACVM_BACKGROUND=1`, `OMACVM_COCOA_HIDDEN=1` | off | test only: window behind / no window | built |
| `OMACVM_VIRGL_SHADER_FAILURES=lose` | skip | a shader vrend cannot translate or the Mac's GL refuses loses the whole context (upstream behaviour) instead of skipping its draws | built (`gpu-robust`) |
| `OMACVM_VIRGL_TEST_FAIL_GLSL=TEXT` | unset | test runtimes only (`OMACVM_RUNTIME_TEST_HOOKS=1` build): refuse shaders whose GLSL contains TEXT | built |
| `OMACVM_TEST_SKIP_DISPLAYS`, `OMACVM_TEST_MAIN_DISPLAY` | off | test only: virtual displays | built |

What the app records: QEMU's log (`qemu.log` in the VM folder) has the
paths taken (fence mode, present mode, Venus ICD, video caps). `omacvm check`
reads the guest side (renderer string, vainfo profiles, outputs). Planned: one
line per path in a file `omacvm check` reads from the host side, so a
fallback is visible without reading logs.

## 10. Security: the guest is untrusted

```
  untrusted                         | trusted (QEMU process, user's account,
                                    |  hardened runtime, no extra entitlements
  guest kernel + apps               |  beyond hypervisor + what the app needs)
  --------------------------------> | virtio-gpu ctrl queue   -> QEMU checks
    command streams, shaders,       | virglrenderer decoders  -> vrend checks
    resource sizes, blob sizes,     | Venus ring              -> vkr checks
    video bitstreams,               | our VT parser           -> our checks
    display JSON lines              | omacvm-cocoa-displays   -> our checks
```

What crosses and who checks it:

- **virgl command streams and shaders**: virglrenderer's decoder (bounds,
  handles, formats). Upstream code plus our patches; every patch that touches
  a decoder states its bounds check. A shader vrend cannot translate or the
  Mac's GL refuses skips its draws; any other decoder error loses that guest
  context only, logs once, and
  writes "guilty" into the guest's reset status buffer when it named one
  (section 13). The status buffer must be guest memory (`VIRGL_BIND_CUSTOM`,
  4 bytes or more); the host writes 4 bytes at offset 0 through the checked iov
  helper. `Tests/virgl/fuzz-cmd-stream.sh` fuzzes command streams into a vrend
  context on the Mac's GL (libFuzzer + ASan). Its first minutes found two
  upstream bugs, both fixed: a NULL shader variant that crashed QEMU
  (`virgl-shader-variant-null-checks.patch`) and shader sizes that asked for
  4 GiB (`virgl-shader-size-limits.patch`). The conformance runs found a
  third: ending transform feedback with no program bound crashed Apple's GL
  (`virgl-transform-feedback-end.patch`); the fuzzer's contexts now get a GL
  buffer and a colour buffer too, and that stream is one of its regression
  inputs.
- **GPU memory a guest draw reaches** (ADR 0017): Apple's GL has no robust
  buffer access, so a range past a buffer is a read or write the GPU really
  does, and a GPU fault resets the GPU (on 2026-10-04 that hung WindowServer
  and panicked macOS). vrend now checks, before any GL call: buffer binding
  points take GL buffers only, with ranges inside them
  (`virgl-buffer-binding-checks.patch`); every vertex, instance and index a
  draw fetches lies inside its buffers, indices read back from the GL buffer,
  indirect commands read and drawn as checked direct draws
  (`virgl-draw-range-checks.patch`); every active uniform block has a buffer
  that covers it (`virgl-uniform-buffer-checks.patch`); run-time shader array
  indexes are clamped (`virgl-shader-index-clamp.patch`). A GL call the Mac's
  GL refuses keeps the older state, which these checks never saw: vertex
  formats and buffer offsets the GL would refuse are refused first
  (`virgl-vertex-format-checks.patch`, `virgl-uniform-buffer-alignment.patch`),
  uniform block arrays are bound as declared
  (`virgl-uniform-block-array.patch`), and a GL error while a draw is set up
  skips the draw (`virgl-draw-gl-error-check.patch`). vrend's own early
  return when the vertex shader does not read its first input left the old
  attribute pointers in place with no GL error at all; it now sets the other
  attributes and disables the rest (`virgl-vertex-unused-first-input.patch`).
  A draw that fails is skipped and logged. The fuzzer runs on Apple's software renderer only, with
  a GL oracle that aborts on any draw leaving a buffer (STANDARDS 14).
  Venus has the same exposure: its devices always get robust buffer access
  where the host driver has it (`virgl-venus-robust-buffer-access.patch`);
  whether MoltenVK really bounds fetches on Apple's GPUs is not shown.
- **resource and blob sizes**: QEMU checks sizes against guest RAM and the
  hostmem window; blob sizes are rounded to the host page by QEMU, never
  trusted.
- **Venus**: the ring and command decoding are upstream vkr; the render
  server runs in QEMU's process on macOS, so a Venus bug is a QEMU bug
  (no process boundary, ADR 0012). Mitigation: off by default, hardened
  runtime.
- **video bitstreams**: our code parses slice headers (H.264 `pps_id`,
  ref-idx overrides), AV1 OBU headers and VP9 frames before VideoToolbox
  sees them. These parsers need a libFuzzer harness (planned, owner:
  `video-decode`). VideoToolbox itself decodes in `VTDecoderXPCService`,
  a separate macOS process.
- **display messages**: JSON from the guest agent; numbers type-checked
  (finite `NSNumber` below 1e7, else the monitor is skipped), at most one
  update applied per second (`app-displays` round 2; tested with nulls,
  arrays, 1e300, 101 flips).
- **display mode changes**: every `set_scanout` with a new size makes QEMU a
  new surface and, in the Cocoa view's GL context, a new surface texture.
  That context was never flushed, and Apple's GL keeps the memory of large
  textures (a 4K screen or more) made, deleted or uploaded on a context until
  it is flushed: each guest mode change left a screen texture behind (about
  1.1 GB per switch for two large modes, 20 GB after 18 switches, in 2.6.0
  too). `with_gl_view_ctx()` now flushes (`qemu-cocoa-gl-view-flush.patch`;
  build-time test `Tests/display/test-gl-view-flush.c` on the software
  renderer; `Tests/display/view-texture-churn.c` measures the GPU memory per
  switch by hand).
- **no host pointers** reach the guest. Limited: hostmem 4 GiB, 2D resources
  (QEMU's `max_hostmem`), outputs 5, retained pixel buffers 3, IOSurfaces 3
  per window. Not limited: virgl 3D resources (textures, buffers) a guest
  creates; each is bounded by the GL's maximum sizes, but their number is
  not, so a guest can still fill the Mac's memory with them (open, needs a
  per-VM GPU memory budget).

## 11. Test strategy

| Level | What | Where |
|---|---|---|
| Build time | virglrenderer's own tests + ours, run in every runtime build (e.g. `Tests/virgl/test-integer-sampler-shader.c`: TGSI -> GLSL, compiled on the Mac's OpenGL) | `app/runtime` |
| Host only | Venus init + context create without a VM; VT probe; JSON and pointer-math unit tests | track scratch, to move into `app/runtime/Tests` |
| Conformance | dEQP GLES2/3 subset (virgl), Vulkan CTS subset (Venus), WebGL conformance in Chrome | planned |
| Smoke | Hyprland up, `chrome://gpu` green, guest `grim` vs expectation, `OMACVM_GL_DUMP` frame upright with right colours | per track |
| Video | `ffmpeg -hwaccel vaapi` framemd5 equal to software (H.264, VP9, real content) | `video-decode` |
| GPU check | `app/scripts/gpu-check.sh VM_DIR 3`: Aquarium + Basemark finish, no refused shaders in `qemu.log` | `gpu-hang` |
| GPU ranges | build time: `Tests/virgl/test-gpu-ranges.c` (software renderer + GL oracle); `fuzz-cmd-stream.sh` (software renderer only); in a VM: dEQP GLES3 draw/buffer/ubo/indexing groups per case before/after | `gpu-robust` |
| Context loss | build time: `Tests/virgl/test-context-loss.c`, `Tests/virgl/test-transform-feedback.c`; in a VM: `tests/graphics/context-loss.sh --expect contain|recover|dead` (Chrome WebGL), `guest/gl-lost.c` (GLES), `guest/vk-lost.c` (Venus) | `gpu-robust` |
| Performance | glmark2, vkmark, Aquarium, Basemark, video-bench.py; same window size, median of 3, JSON, with `~/.omacvm-bench.lock` and other test VMs paused | `src/bench`, `docs/benchmarks` |
| Stability | 30 min soak per path (browser + video + glmark2 loop), sleep/wake, display plug/unplug | per track |

Numbers so far (track notes have the raw data; most were taken without the
bench lock and are indications only):

| What | Shipped | Built |
|---|---|---|
| glmark2, window 1440x810 pt, 60 Hz | 1259 | 4006 (async fences + present on flush) |
| Fence to reply, median | 1.56 ms | 0.20 ms |
| Window frames/s | <= 33 | 60 (display refresh) |
| vkmark headless 800x600 (Venus) | - | ~800 |
| YouTube 4K60 VP9, guest cores / QEMU cores | 1.21 / 1.71 (software) | 0.34 / 0.45 (VideoToolbox) |

## 12. Merging the tracks

The tracks share one runtime. Order and overlaps known today:

1. `gpu-hang` (`virgl-texture-integer-samplers.patch`) goes first: a fix,
   after `virgl-native-opengl.patch`.
2. `gpu-native` and `gpu-venus` both carry `qemu-virtio-gpu-blob-alignment.patch`
   and `virgl-darwin-venus-in-process.patch` (same content); keep one copy.
   `gpu-venus` needs `gpu-native`'s FIFO thread-sync for Venus fences.
3. `gpu-native` and `app-displays` both patch `ui/cocoa.m` heavily: the
   IOSurface present must cover the head windows too.
4. `video-decode` and `gpu-native` both add a "hidden window for tests" patch
   (`qemu-cocoa-hidden-for-tests.patch`, `omacvm-cocoa-background.patch`):
   keep one.
5. `gpu-native`'s branch has an earlier version of this document and ADR
   0010; this version replaces both.
6. `gpu-robust` adds, after `virgl-texture-integer-samplers.patch`:
   `virgl-shader-failure-skip-draws.patch`, `virgl-context-loss-report.patch`,
   `virgl-shader-variant-null-checks.patch`, `virgl-shader-size-limits.patch`,
   `virgl-venus-lost-context-fences.patch`, `virgl-core-instance-id.patch`,
   `virgl-transform-feedback-end.patch`, `virgl-stream-output-checks.patch`,
   `virgl-gl-error-skip-command.patch`, `virgl-buffer-binding-checks.patch`,
   `virgl-draw-range-checks.patch`, `virgl-uniform-buffer-checks.patch`,
   `virgl-shader-index-clamp.patch`, `virgl-vertex-format-checks.patch`,
   `virgl-uniform-buffer-alignment.patch`, `virgl-uniform-block-array.patch`,
   `virgl-draw-gl-error-check.patch`, `virgl-vertex-unused-first-input.patch`,
   `virgl-venus-robust-buffer-access.patch`, and the test-only
   `virgl-test-shader-fault.patch` behind `OMACVM_RUNTIME_TEST_HOOKS=1`. On
   QEMU it adds `qemu-cocoa-gl-view-flush.patch` after the `omacvm-cocoa-*`
   patches; it applies after the QEMU patches of `rel-2.7.0`, `gpu-2.9.0`,
   `display-bugs`, `gpu-native`, `pacing-hdr`, `kosmickrisp`, `gl-compat`,
   `video-encode` and `webgpu-compute` (checked 2026-10-04). The
   patches up to the Venus fence one passed the build-time tests on
   `gpu-venus`'s tree (branch `gpu-robust-venus`, c0988e2); the Venus fence
   patch is only exercised there, since `rc-2.6.0` has no Venus. The whole
   series applies without conflict after the virgl patches of `gpu-2.9.0`,
   `release-2.7.0`, `gl-compat`, `gpu-venus` and `video-decode` (checked
   2026-10-04). `gpu-robust` also carries the `conformance` harness and this
   document as cherry-picks (same content, merge without conflict).

## 13. Errors and context loss (built: `gpu-robust`)

What happens when the Mac side cannot run a guest's GPU work. ADR 0016.

```
 guest app ----- shader the Mac's GL refuses -----> vrend: mark the shader failed,
   |                                                skip the draws that need it,
   |                                                log (3 lines max per context)
   |                                                -> the app keeps running
   |
   +------------ any other fatal decoder error ---> vrend: context lost (in_error),
                                                    log once, write GUILTY into the
                                                    guest's reset status buffer
                                                    (VIRGL_CCMD_SET_RESET_STATUS_BUFFER)
       guest Mesa (src/app/guest/mesa/):
         robust context  -> glGetGraphicsResetStatus = GL_GUILTY_CONTEXT_RESET
         other contexts  -> abort() at the next flush, like Mesa's venus;
                            Chrome restarts its GPU process, WebGL pages get
                            webglcontextlost + webglcontextrestored
       stock guest Mesa  -> cannot be told: the app draws nothing until restarted

 Vulkan app ---- fatal venus command -----------> vkr: ring status FATAL, log once;
                                                    the proxy signals the context's
                                                    fences from now on (they hung
                                                    before); guest venus aborts the app
```

Other contexts (the compositor, other apps) and the VM are not affected in any
of these cases. Measured in OmacVM T-gpu-robust (Chrome 154, M4 Max, macOS 15.7):

| Case | Before | After |
|---|---|---|
| WebGL page, one shader refused by the Mac's GL | page frozen: every readback wrong from then on (1559 of 1559 frames) | page keeps drawing: 1978 of 1978 frames read back right; no context loss |
| Same, policy `lose`, guest Mesa patched | - | `webglcontextlost` at 5.05 s, restored 1.0 s later on the GPU (renderer still virgl), all frames right afterwards |
| GLES app with a robust context (`gl-lost`) | reset status never set | `GL_GUILTY_CONTEXT_RESET` on the frame the context was lost |
| Vulkan app, fatal command (`vk-lost`) | hangs in `vkWaitForFences` (killed after 60 s) | ends with abort() after 2 s; the next Vulkan app runs normally |
| WebGL with instanced drawing (ANGLE reads gl_InstanceID) | every such shader refused: `#extension GL_ARB_draw_instanced` is not in Apple's core profile (found in the soak) | compiles (`virgl-core-instance-id.patch`, build-time test) |
| Guest command stream fuzzing, 30 min, ~606,000 inputs | QEMU crash (NULL variant) in seconds, 4 GiB asks | no crash, no out-of-memory |

Cost when nothing fails: glmark2 subset (build, texture, shading phong, terrain,
5 s each, off-screen, median of 3, bench lock held, other test VMs paused):
rc-2.6.0 628 (618-634), gpu-robust 625 (622-630), within run-to-run noise.

Tests: `app/runtime/Tests/virgl/test-context-loss.c` (every runtime build),
`tests/graphics/context-loss.sh`, `tests/graphics/venus-loss.sh`,
`app/runtime/Tests/virgl/fuzz-cmd-stream.sh`.
