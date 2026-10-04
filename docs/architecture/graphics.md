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
| Async fences (vrend-sync thread on macOS) | built: `gpu-native`, open hang | `qemu-cocoa-gl-async-fence.patch`, `virgl-darwin-thread-sync.patch` |
| Present on each flush | built: `gpu-native` | `qemu-cocoa-gl-present-on-flush.patch` |
| IOSurface present | built: `gpu-native` | `qemu-cocoa-gl-present-iosurface.patch` |
| Blob alignment for 16 KiB pages | built: `gpu-native`, `gpu-venus` | `qemu-virtio-gpu-blob-alignment.patch` |
| Venus on MoltenVK | built: `gpu-venus`, hidden switch | see section 6 |
| KosmicKrisp on macOS 26 | planned | ICD choice already in `virgl-darwin-vulkan-beside.patch` |
| OpenCL (rusticl on Zink), WebGPU in Firefox and Chromium | built: `webgpu-compute`, Venus VMs | section 6, ADR 0022 |
| Zink as GL driver, ANGLE-on-Vulkan in Chrome | blocked on MoltenVK (GL 2.1, no `VK_EXT_provoking_vertex`) | - |
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
no float64, no `VK_EXT_provoking_vertex`. So Zink as a GL driver and
ANGLE-on-Vulkan in Chrome do not work; they wait for KosmicKrisp, which
needs Metal 4 (macOS 26). See ADR 0013. Zink for compute (rusticl) works
with patches: next section, ADR 0022. Frame latency is Venus's ring polling (guest `vn_relax`, host
`vkr_ring_relax`), about 1.3 ms per frame: vkmark ~800 is latency, not GPU.

### WebGPU and OpenCL on Venus (built: `webgpu-compute`)

```
 Firefox (WebGPU, wgpu)   Chromium (WebGPU, Dawn)     OpenCL app (Geekbench, ffmpeg, clpeak)
        |                 launcher: Skia Graphite          |
        |                 on Dawn-Vulkan, X11         rusticl (Mesa OpenCL 3.0) -> Zink
        |                        |                         |
 /opt/omacvm-mesa: Mesa 26.2.4 venus + zink + rusticl with OmacVM's patches, built in the guest
        \________________________|_________________________/
                                 |  Venus ring, as in the chain above
                                 v
                    vkr -> MoltenVK -> Metal
```

- `src/app/guest/venus/install.sh`, called by the app's guest install,
  does nothing without Venus (it reads the capset count and the host
  visible region from virtio-gpu's debugfs). With Venus it builds the
  pinned Mesa once (stamp: version + patch hash), registers
  `/etc/vulkan/icd.d/omacvm_venus_icd.json` and
  `/etc/OpenCL/vendors/omacvm-rusticl.icd`, writes
  `/etc/environment.d/90-omacvm-venus.conf` (`RUSTICL_ENABLE=zink`,
  `VK_LOADER_DRIVERS_DISABLE=virtio_icd.json`: the distro's venus, Mesa
  26.2.3, fails on 16 KiB blob pages), Firefox's `dom.webgpu.enabled`, and
  the `omacvm-chromium-webgpu` launcher with a "Chromium (WebGPU)" menu entry.
- Patches (guest Mesa, `src/app/guest/venus/patches`):
  - `mesa-zink-moltenvk-no-push-descriptors.patch`: SPIRV-Cross can alias
    zink's typed bo arrays only in argument buffers, which MoltenVK never
    uses for push sets (every kernel failed);
  - `mesa-zink-moltenvk-null-descriptor.patch`: start without
    `nullDescriptor`; unbound slots are undefined on MoltenVK;
  - `mesa-zink-moltenvk-global-loads.patch`: MoltenVK 1.4.2's SPIRV-Cross
    forwards loads through buffer addresses past stores to the same memory,
    so swaps lost elements (Geekbench's Feature Matching failed); zink reads
    each global address back from a variable, which keeps the load in place;
  - `mesa-venus-opaque-fd-semaphores.patch`: OPAQUE_FD binary semaphores on
    the DRM syncobj Venus already has, the one thing Dawn was missing;
  - `mesa-venus-incremental-present.patch` (from the `kosmickrisp` track).
- Host (`app/runtime/patches`): `virgl-darwin-venus-moltenvk-zero-init.patch`
  reports `shaderZeroInitializeWorkgroupMemory` off on MoltenVK, for every
  guest instance version (Dawn uses 1.1): MoltenVK's SPIRV-Cross cannot
  compile zero-initialized workgroup memory, and such a WebGPU shader lost
  the whole Vulkan context.
- GL stays on virgl. Zink as a GL driver is not installed (GL 2.1 only on
  MoltenVK).
- Chrome's two gates (ADR 0022): a Vulkan compositor, and Dawn's
  `SupportsExternalImages()` (OPAQUE_FD semaphores). The launcher passes
  `--ozone-platform=x11 --enable-skia-graphite
  --skia-graphite-dawn-backend=vulkan` with `MESA_VK_WSI_DEBUG=sw`: Chrome
  refuses Vulkan on Wayland, and Venus' DRI3 present to Xwayland is half as
  fast as its software path. WebGL stays on virgl and is copied into the
  compositor (about a fifth slower), so the default Chromium is unchanged.
- Copying a WebGPU canvas into a 2D canvas returns zeros in every Chrome
  mode in the VM (also the default): open.
- Kernel launches cross the Venus ring like draw calls: launch-heavy
  OpenCL work pays Venus's latency (see vkmark above).
- On KosmicKrisp (Mac mini M4, macOS 27) the same guest Mesa passes the
  same checks; the Zink patches and the host zero-init patch act on
  MoltenVK's driver ID only, so they stay off there. Results tables:
  [../benchmarks/README.md](../benchmarks/README.md#gpu-compute-with-venus-2026-10-04).

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
| Guest: `src/app/guest/venus/install.sh` (`--remove`) | only on Venus VMs | OmacVM's Mesa for Vulkan, OpenCL (rusticl), Firefox WebGPU | built (`webgpu-compute`) |
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
  a decoder states its bounds check. A refused shader kills that guest
  context only (Chrome then hangs, which is how the Basemark bug showed up);
  reporting a context loss instead is planned.
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
- **no host pointers** reach the guest; no guest-controlled allocation
  without a limit (hostmem 4 GiB, outputs 5, retained pixel buffers 3,
  IOSurfaces 3 per window).

## 11. Test strategy

| Level | What | Where |
|---|---|---|
| Build time | virglrenderer's own tests + ours, run in every runtime build (e.g. `Tests/virgl/test-integer-sampler-shader.c`: TGSI -> GLSL, compiled on the Mac's OpenGL) | `app/runtime` |
| Host only | Venus init + context create without a VM; VT probe; JSON and pointer-math unit tests | track scratch, to move into `app/runtime/Tests` |
| Conformance | dEQP GLES2/3 subset (virgl), Vulkan CTS subset (Venus), WebGL conformance in Chrome | planned |
| Smoke | Hyprland up, `chrome://gpu` green, guest `grim` vs expectation, `OMACVM_GL_DUMP` frame upright with right colours | per track |
| Video | `ffmpeg -hwaccel vaapi` framemd5 equal to software (H.264, VP9, real content) | `video-decode` |
| Compute | `src/app/guest/venus/cltest.c` (saxpy, reduction, atomics, in-place sort vs CPU), `semtest.c` (OPAQUE_FD semaphores shared by two devices; prints Dawn's adapter check), Geekbench 7 GPU OpenCL validation, WebGPU matmul vs CPU sample (`webgpu-compute` tools) | `webgpu-compute` |
| GPU check | `app/scripts/gpu-check.sh VM_DIR 3`: Aquarium + Basemark finish, no refused shaders in `qemu.log` | `gpu-hang` |
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
| WebGPU matmul f32 2048, Chromium in the VM (launcher) vs Chrome on the Mac, same locked batch | - | 5071 vs 6038 GFLOPS (84 %) |
| WebGPU matmul f32 2048, Firefox, VM vs Mac, same locked batch | - | 665 vs 319 GFLOPS |
| OpenCL clpeak fp32 (VM, 40-CU shim / as reported) vs Mac OpenCL | - | 8.9 / 1.5 vs 15.6-16.1 TFLOPS |
| Geekbench 7 GPU OpenCL, VM vs Mac, same locked batch | - | 42486 vs 95380 (45 %); before the global-loads fix 10673, Feature Matching failed |
| ffmpeg 4K nlmeans in the VM, OpenCL vs 8 vCPUs | - | 1.07 vs 0.33 fps |
| WebGPU matmul f32 2048 on KosmicKrisp (Mac mini M4, unlocked), Chromium launcher / Firefox in the VM vs Chrome on the mini | - | 1148 / 167 vs 1614 GFLOPS |
| Geekbench 7 GPU OpenCL on KosmicKrisp (Mac mini M4), VM vs the mini's OpenCL | - | 18973 vs 35240 (54 %), all workloads valid |
| Compute soak (OpenCL, Firefox and Chromium WebGPU, ffmpeg OpenCL), M4 Max | - | 63 rounds in 36 min, 0 failures |
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
