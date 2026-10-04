# Venus on KosmicKrisp (macOS 26 and newer)

Round 1 of the kosmickrisp track, 2026-10-04, on a Mac mini M4 (10 cores, 16 GB,
macOS 27.0) with an LG UltraFine 5K. The test VM ran in OmacVM.app's runtime with
6 CPUs and 8 GB, the Mac mini's screen locked.

KosmicKrisp is Mesa's Vulkan driver on Metal 4. It replaces MoltenVK under Venus on
macOS 26 and newer: the runtime carries both and libvirglrenderer picks KosmicKrisp
there, MoltenVK before (and as a fallback).

## What it took

Host (OmacVM.app runtime, `app/runtime`):

| Change | Why |
|---|---|
| `build-kosmickrisp.sh` | Builds KosmicKrisp from Mesa `e5f0687867f5` (sha256-pinned archive). First Mesa's OpenCL-C compiler `mesa_clc` with Homebrew LLVM, then the driver with `-Dmesa-clc=system -Dllvm=disabled -Dspirv-tools=disabled -Dzstd=disabled`: the dylib links only system libraries. About 3 minutes on the M4. |
| `-Dplatforms=macos` | Without Mesa's macos platform `VK_USE_PLATFORM_METAL_EXT` is undefined: KosmicKrisp lists `VK_EXT_external_memory_metal` but returns NULL for `vkGetMemoryMetalHandleEXT`. Venus called it and QEMU crashed on the guest's first allocation. |
| `virgl-darwin-venus-metal-entrypoints.patch` | Venus checks both Metal entry points before calling them: a driver without them fails the allocation with a log line, the VM keeps running (it was a guest-triggered host crash). |
| `virgl-darwin-kosmickrisp-fallback.patch` | Before choosing KosmicKrisp, make a throwaway instance with it; when it does not load or has no device, log and use MoltenVK. |
| `prepare-qemu-gpu-runtime.sh`, `verify-macos-compatibility.sh` | `lib/libvulkan_kosmickrisp.dylib` + `share/vulkan/icd.d/kosmickrisp_mesa_icd.json` next to MoltenVK. The dylib is the one image allowed a macOS 26 minimum: only the Vulkan loader opens it, and only on 26+. |

KosmicKrisp is opt-in at build time: `OMACVM_RUNTIME_KOSMICKRISP=1` adds it, and the runtime
build first runs `build-kosmickrisp.sh --check`, which lists every missing build tool
(Homebrew LLVM, SPIRV-LLVM-Translator, SPIRV-Tools, bison, the macOS 26 SDK) and stops before
QEMU is built. Without the variable the runtime has MoltenVK only; the MacBook builds that way.
The build writes `LICENSE.mesa-kosmickrisp.txt`: it reads ninja's inputs and header deps for the
dylib (871 Mesa files at this commit), sorts them by licence (MIT 855, BSD notices for xxHash and
Berkeley SoftFloat, BSL-1.0 for the C11 threads code, BLAKE3 under Apache-2.0, Khronos
Apache-2.0 and SGI-B-2.0 headers) and writes the licence texts with every copyright line. An
unknown licence stops the build. The runtime carries it in `share/licenses`, and `build-app.sh`
refuses to build an app whose runtime has the dylib but not the notice.
`OMACVM_VULKAN_DRIVER=moltenvk|kosmickrisp` picks the driver by hand at run time.
QEMU's log says which one runs: `vkr: vulkan driver: .../kosmickrisp_mesa_icd.json`.

Guest: Mesa at the same commit with venus, zink and rusticl (`/opt/mesa-kk`), plus one
Mesa fix: [mesa-venus-incremental-present.patch](kosmickrisp/mesa-venus-incremental-present.patch)
(venus forwarded `VK_KHR_incremental_present` to the host when an app enabled it without a
swapchain; Chrome's ANGLE does, and its device creation failed). Arch Linux ARM's Mesa
26.2.3 cannot run Venus at all (no 16 KiB blob alignment); 26.2.4 can.

## What the VM gets

`vulkaninfo` in the guest: `Virtio-GPU Venus (Apple M4)`, venus, Vulkan 1.4.334.

| Feature | KosmicKrisp | MoltenVK 1.4.2 |
|---|---|---|
| nullDescriptor (Zink needs it) | yes | no |
| robustBufferAccess2 | yes | no |
| logicOp | yes | no |
| provoking vertex (ANGLE ES 3.0 needs it) | yes | no |
| transform feedback (Zink GL 3.0 / ES 3.0) | no | no |
| geometry shaders | no | no |
| float64 | no | no |
| tessellation | yes | yes |

## Numbers

Mac mini M4, macOS 27.0, VM 6 CPUs / 8 GB, the Mac's screen locked, runtime from the
gpu-venus branch (virgl fences polled every 1 ms). Median of 3 unless it says otherwise.
The Mac mini also ran another agent's light builds: load average 0.7 to 2.7, except one
spike to 10-20 (12:59-13:05) that overlaps one glmark2 run of each kind. No benchmark
lock exists on the mini; it held only this VM. All numbers: [results.json](kosmickrisp/results.json).

| Test | KosmicKrisp | MoltenVK 1.4.2 (same Mac) | virgl (OpenGL) |
|---|---|---|---|
| vkmark, headless, 800x600 | **840** (840, 912, 805) | 650 (666, 647, 650) | - |
| vkmark, headless, 1920x1080 | 676 (1 run) | 654 (1 run) | - |
| glmark2-es2 --off-screen, 800x600 | **555** over Zink (560, 555, 429) | Zink does not start | 494 (494, 480, 494) |
| Aquarium 30,000 fish, Chrome 154 | **25.9** fps ANGLE on Vulkan (25.9, 25.9, 25.1), see below | ANGLE cannot make ES 3.0 | 21.9 (X11), 22.4 (Wayland) |
| Basemark Web 3.0 | **1620** (1 run; WebGL1 3189, WebGL2 1934) | - | no score after 625 s (the known virgl hang, fixed on gpu-hang) |
| Geekbench 7 GPU OpenCL (rusticl on Zink) | **18886** (19080, 18580, 18886) | no OpenCL device | - |
| clpeak, Vulkan backend, fp32 | **4.01 TFLOPS** | - | - |

Both Vulkan drivers are latency bound at these sizes (about 1.2 ms per frame for any
scene); KosmicKrisp is 29 % faster there. glmark2 over Zink beats virgl by 12 % with the
same fence polling.

clpeak, Vulkan backend: fp32 4.01 TFLOPS, fp16 4.01, int32 1.01 TOPS, int8 dot 766 GOPS,
global memory 97.5 GB/s, local 1.79 TB/s, image 104 GB/s, host to device 44.5 GB/s,
kernel dispatch 364 us, round trip 1.5 ms. The OpenCL backend through rusticl shows
378 GFLOPS and 48 GB/s only because Zink reports one compute unit and clpeak sizes its
work by it. Whether Geekbench loses anything to it is not known.

Geekbench 7 OpenCL workloads (run 3): Background Blur 10630, Face Tracking 12324, Super
Resolution 12571, Horizon Detection 26728, Photo Filter 27601, Video Filter 26675, RAW
23797, Feature Matching 26541 (0, failed validation, on MoltenVK), Path Tracer 23444,
Particle Physics 13531, Fluid Simulation 16788.

The Mac mini itself, same Geekbench 7.0.0, no VM running: GPU Metal **56025** (56610,
56025, 55883), GPU OpenCL **35240** (35307, 35240, 35169). The VM's OpenCL is 54 % of the
Mac's OpenCL and 34 % of its Metal score.

Chrome with ANGLE on Vulkan needs three things today: X11 (`--ozone-platform=x11`;
Chrome refuses Vulkan with Wayland), Venus with the incremental-present fix, and
`--disable-angle-features=supportsPrimitiveTopologyListRestart`. Without the last flag
ANGLE turns on list primitive restart (WebGL 2 keeps restart on), and KosmicKrisp then
unrolls every indexed draw in a compute pass, ending and restarting the Metal render
encoder per draw: Aquarium 1,000 fish ran at 5 fps, 5,000 at 1 fps, 30,000 lost the
device (`VK_ERROR_DEVICE_LOST` on the Mac, Chrome's GPU process aborts). With the flag:
50.9 / 49.7 / 49.9 / 25.3 fps for 100 / 1,000 / 5,000 / 30,000 fish (the ~50 fps cap is
the X11 path with Mesa's software WSI copy, `MESA_VK_WSI_DEBUG=sw`).

Stability: the conformance branch's `tests/graphics/soak.sh --vk --minutes 30` (with the
Vulkan load pointed at the guest's Mesa through a `GPUENV` hook): vkmark over Venus on
KosmicKrisp in a loop, Chrome on a WebGL page and mpv playing 1080p60 (both virgl) at the
same time. **Pass**: 1793 s, no missed heartbeat, no stuck fence, 13 vkmark loops with
steady scores (637 to 643, windowed on Wayland), 108,220 WebGL frames, 1.77 million
fences signalled, QEMU's memory 3614 MB at the start and 1672 MB at the end (no growth).
The Vulkan conformance suite (dEQP-VK) was not run: it is not built in this VM yet.

## Blockers, precisely

- **Zink: OpenGL 2.1 / ES 2.0 only.** KosmicKrisp at this commit has no
  `VK_EXT_transform_feedback` (Zink needs it for GL 3.0 and ES 3.0) and no geometry
  shaders (GL 3.2, ES 3.2). Custom border colours are behind
  `MESA_KK_EXPERIMENTAL=custom_border`. glmark2-es2 runs; anything needing GL 3+ does not.
- **Chrome, ANGLE on Vulkan: works, but only with flags.** See the numbers above for the
  three conditions. Measured with `--ozone-platform=x11 --use-angle=vulkan
  --disable-angle-features=supportsPrimitiveTopologyListRestart
  --disable-native-gpu-memory-buffers --disable-zero-copy` and `MESA_VK_WSI_DEBUG=sw`
  for Chrome. Buffers Chrome allocates through GBM come from virgl (Apple OpenGL) and
  cannot be imported into the Venus (Metal) context (`proxy: exported res N to unexpected
  fd_type -1`, then `vkr: failed to import resource`); sharing between the two needs
  IOSurface-backed memory on the Mac. Not a default to ship yet.
- **WebGPU in Chrome: SwiftShader only.** Dawn finds the Venus adapter and marks it
  available, but Chrome only uses an adapter that can import external images. On desktop
  Linux Dawn needs OPAQUE_FD semaphores and exportable images for that; Venus has only
  SYNC_FD semaphores and no exportable optimal-tiling images (checked with
  [extmem.c](kosmickrisp/extmem.c)). Nothing in Chrome's flags changes it.
- **Geekbench GPU Vulkan**: Geekbench 7 for Linux ARM has no Vulkan backend. OpenCL works
  (rusticl), see the numbers.

## Tools

In [kosmickrisp/](kosmickrisp/): `vkprobe.c` (host: which features a driver gives Venus),
`extmem.c` (guest: what Dawn's external-image check sees), `gdpa.c` (host: the NULL
Metal entry point), `guest-mesa.sh`,
`kk-guest.sh`, `kk-batch.sh` (the measurement round), `results.json` (all numbers).

## For the graphics architecture page and ADR 0013 (gfx-docs branch)

- ADR 0013 status: KosmicKrisp built and tested on macOS 27 (Mac mini M4); bundled
  next to MoltenVK, chosen on macOS 26+, falls back to MoltenVK when it has no device.
- Status table: "Venus on KosmicKrisp" built on branch `kosmickrisp`.
- Settings: `OMACVM_VULKAN_DRIVER=moltenvk|kosmickrisp` (run time),
  `OMACVM_RUNTIME_KOSMICKRISP=1` (build time, opt-in). KosmicKrisp's own `MESA_KK_*` variables
  reach it through QEMU's environment.
- Security: the Metal entry points are checked before use (a missing one was a
  guest-triggered host crash).
- Build: KosmicKrisp needs Homebrew LLVM, SPIRV-LLVM-Translator, SPIRV-Tools and bison at
  build time only, and the macOS 26 SDK. The runtime build fails in a path with a space
  (meson splits `CFLAGS`), true before this branch too.
