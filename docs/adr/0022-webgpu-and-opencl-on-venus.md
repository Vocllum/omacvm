# 0022: WebGPU and OpenCL on Venus

Status: accepted, built (`webgpu-compute`). Firefox: WebGPU on by default in
Venus VMs. Chromium/Chrome: WebGPU from a separate launcher. OpenCL: rusticl.
Partly replaces 0013's "rusticl waits for KosmicKrisp". (First written as
0016; renumbered because other branches use 0016-0021.)

## Context

With Venus (0012, 0013) the VM has Vulkan 1.4 on MoltenVK. Two things
people want on top of it: WebGPU in the browser and GPU compute (OpenCL,
e.g. Geekbench GPU, darktable, ffmpeg's OpenCL filters).

What we found (track notes `webgpu-compute`):

- **Firefox 157** runs WebGPU (wgpu) on Venus as soon as
  `dom.webgpu.enabled` is set; it presents through its own copy path.
- **Chrome/Chromium** hands a page a hardware WebGPU adapter on Linux only
  if two gates pass (Chromium `webgpu_decoder_impl.cc`
  `CreatePreferredAdapter`, Dawn `PhysicalDeviceVk.cpp`):
  1. Dawn's backend list holds Vulkan only when Chrome's compositor runs on
     Vulkan (Ganesh-Vulkan or Skia Graphite on Dawn-Vulkan) or "WebGPU on
     Vulkan via GL interop" is on; otherwise it is empty and pages get
     SwiftShader (or nothing).
  2. `SupportsExternalImages()`: `VK_KHR_external_memory_fd` (the host
     already emulates dma-buf export with Metal heaps, so Venus has it) and
     **OPAQUE_FD** semaphores that are exportable and importable. Venus
     offered SYNC_FD only.

  Gate 1 options on MoltenVK: GL interop needs `GL_EXT_semaphore_fd` in
  ANGLE-on-virgl and GL<->Metal memory sharing on the Mac (not there);
  ANGLE on Vulkan gives only ES 2.0 (no `VK_EXT_provoking_vertex`). Skia
  Graphite on Dawn-Vulkan works, but Chrome allows a Vulkan compositor only
  on X11, not Wayland.
- **rusticl** (Mesa's OpenCL) runs on Zink on Venus after Zink changes for
  MoltenVK (push descriptors off, start without `nullDescriptor`).
- MoltenVK 1.4.2 ships a SPIRV-Cross older than two fixes that matter here:
  - it forwards loads through buffer device addresses past stores to the
    same memory (fixed upstream in 090bb6b7, 2026-07-31): every in-place
    swap in OpenCL lost an element, so Geekbench 7's Feature Matching
    failed validation (its bitonic sort);
  - it cannot compile zero-initialized workgroup memory (no
    `gl_WorkGroupSize` declared): WebGPU shaders with workgroup memory lost
    the whole Vulkan context, in Firefox and in Chrome.
  No newer MoltenVK release exists (1.4.2 is from 2026-07-24).
- Arch Linux ARM's Mesa 26.2.3 venus cannot round blob sizes to the
  host's 16 KiB pages; 26.2.4 can.

## Options

1. Wait for KosmicKrisp (macOS 26) for everything.
2. Firefox WebGPU and OpenCL now, built in the guest from pinned Mesa with
   our patches, only on Venus VMs; Chrome stays on SwiftShader.
3. As 2, plus Chrome: OPAQUE_FD semaphores in Venus and Chrome's compositor
   on Graphite/Dawn-Vulkan, from a separate launcher.
4. Chrome by GL interop: host GL<->Metal sharing (IOSurface-backed Venus
   memory, `CGLTexImageIOSurface2D`) plus `GL_EXT_semaphore_fd` in virgl.

## Decision

Option 3. Option 1 leaves macOS 15 users without all of it; option 4 is a
large host project and would still need option 3's semaphores.

`src/app/guest/venus/install.sh` runs from the app's guest install when
the VM has Venus (three capsets and a host-visible region in virtio-gpu's
debugfs). It builds Mesa 26.2.4 (sha256-pinned) into `/opt/omacvm-mesa`
(venus + zink + rusticl, no GL: virgl keeps serving GL) with:

- `mesa-zink-moltenvk-no-push-descriptors.patch`,
  `mesa-zink-moltenvk-null-descriptor.patch` (Zink on MoltenVK at all);
- `mesa-zink-moltenvk-global-loads.patch`: on MoltenVK Zink reads each
  global address back from a variable, so SPIRV-Cross keeps the load where
  it is (drop with a MoltenVK that has 090bb6b7);
- `mesa-venus-opaque-fd-semaphores.patch`: binary semaphores exportable
  and importable as OPAQUE_FD, backed by the DRM syncobj Venus already
  uses for SYNC_FD (kernel 6.6+);
- `mesa-venus-incremental-present.patch` (from `kosmickrisp`).

It registers the Vulkan and OpenCL ICDs in `/etc`, skips the distro's
venus manifest, sets `RUSTICL_ENABLE=zink`, turns on WebGPU in Firefox and
installs `omacvm-chromium-webgpu` (and `omacvm-chrome-webgpu` for Google
Chrome) with a "Chromium (WebGPU)" menu entry: `--ozone-platform=x11
--enable-skia-graphite --skia-graphite-dawn-backend=vulkan` and
`MESA_VK_WSI_DEBUG=sw` (Venus' software present: 60 fps, DRI3 gives ~30).
`--remove` undoes all of it.

On the host, `virgl-darwin-venus-moltenvk-zero-init.patch` hides
`shaderZeroInitializeWorkgroupMemory` on MoltenVK, also from Vulkan 1.1
guests (Dawn): MoltenVK reports the instance's version as the device's, so
the driver ID is asked for whenever `VK_KHR_driver_properties` is there.

## Consequences

- Firefox and Chromium (launcher) run WebGPU on the Mac's GPU. WebGPU f32
  matmul 2048, one locked batch: Chromium in the VM 5071 GFLOPS, Chrome on
  the Mac 6038 (84 %); Firefox in the VM 665, Firefox on the Mac 319 (SPIR-V
  through MoltenVK's SPIRV-Cross compiles that kernel better than naga's MSL).
- Without `mesa-venus-opaque-fd-semaphores.patch` Chrome in the same mode
  gets no adapter at all; with it, the Venus adapter (tested both ways).
- The launcher costs WebGL about a fifth (Aquarium 14.3 vs 18.4 fps,
  unlocked): WebGL stays on virgl and its frames reach the Vulkan
  compositor by copy. Hence a separate launcher, default Chromium unchanged.
- Copying a WebGPU canvas into a 2D canvas (`drawImage`) gives zeros in
  every Chrome mode in the VM, also the default one: open.
- OpenCL 3.0 device "zink ... (MOLTENVK)"; Geekbench 7 GPU OpenCL passes
  all workloads' validation now: 42486 in the VM vs 95380 for the Mac's own
  OpenCL in one locked batch (before the global-loads patch: 10673, Feature
  Matching failed). Zink reports one compute unit (Vulkan has
  no such query), so tools that size work by CUs (clpeak) under-fill the GPU.
- Each kernel launch crosses the Venus ring: work made of many small
  kernels (Geekbench's Super Resolution, Particle Physics) loses most.
- Unbound descriptors are undefined on MoltenVK instead of zero; rusticl
  binds what kernels use.
- First install builds Mesa in the VM: about 1-2 minutes on 8 vCPUs (M4
  Max), after pacman fetched LLVM, Clang, Rust and bindgen.
- On macOS 26 KosmicKrisp compiles NIR to MSL itself: the global-loads and
  zero-init workarounds are MoltenVK-only by driver ID.
