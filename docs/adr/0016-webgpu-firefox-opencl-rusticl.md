# 0016: WebGPU through Firefox, OpenCL through rusticl on MoltenVK

Status: accepted, built (`webgpu-compute`). Chrome's WebGPU stays blocked.
Partly replaces 0013's "rusticl waits for KosmicKrisp".

## Context

With Venus (0012, 0013) the VM has Vulkan 1.4 on MoltenVK. Two things
people want on top of it: WebGPU in the browser and GPU compute (OpenCL,
e.g. Geekbench GPU, darktable, ffmpeg's OpenCL filters).

What we found (track notes `webgpu-compute`):

- **Chrome 154** never hands a page the Venus adapter. On Linux, Chrome's
  WebGPU uses Vulkan only when its compositor is Vulkan, or when
  "WebGPU on Vulkan via GL interop" is on; otherwise the backend list is
  empty and the page gets SwiftShader. The GL interop needs
  `GL_EXT_memory_object_fd` and `GL_EXT_semaphore_fd` in ANGLE-on-virgl
  (neither is there), and the browser drops `--use-vulkan` while the
  compositor is GL, so the check cannot be forced. A Vulkan compositor
  needs ANGLE on Vulkan for WebGL, and ANGLE gives only ES 2.0 there:
  MoltenVK has no `VK_EXT_provoking_vertex` (last-vertex convention).
  Underneath both: virgl (Apple OpenGL) and Venus (MoltenVK/Metal) cannot
  share memory on the Mac today, so no GL<->Vulkan interop can work.
- **Firefox 157** runs WebGPU (wgpu) on Venus as soon as
  `dom.webgpu.enabled` is set; it presents through its own copy path and
  needs no interop.
- **rusticl** (Mesa's OpenCL) runs on Zink on Venus, after two Zink
  changes for MoltenVK: no push descriptors (MoltenVK keeps push sets out
  of argument buffers, where SPIRV-Cross can alias zink's typed bo
  arrays; without the change every kernel failed to compile), and start
  without `nullDescriptor`.
- Arch Linux ARM's Mesa 26.2.3 venus cannot round blob sizes to the
  host's 16 KiB pages; 26.2.4 can.

## Options

1. Wait for KosmicKrisp (macOS 26) for everything.
2. Ship WebGPU through Firefox and OpenCL through rusticl now, built in the
   guest from pinned Mesa with our patches, only on Venus VMs.
3. Make Chrome work: host-side GL<->Vulkan sharing (IOSurface-backed
   exportable Venus memory, imported into Apple GL with
   `CGLTexImageIOSurface2D`), plus `GL_EXT_semaphore_fd` in virgl, or a
   Graphite-Dawn compositor whose dmabufs Hyprland (virgl) could import.

## Decision

Option 2 now; option 3 recorded as the way to Chrome. Option 1 leaves
macOS 15 users without both.

`src/app/guest/venus/install.sh` runs from the app's guest install when
the VM has Venus (three capsets and a host-visible region in virtio-gpu's
debugfs). It builds Mesa 26.2.4 (sha256-pinned) with
`mesa-zink-moltenvk-no-push-descriptors.patch` and
`mesa-zink-moltenvk-null-descriptor.patch` into `/opt/omacvm-mesa`
(venus + zink + rusticl, no GL: virgl keeps serving GL), registers the
Vulkan and OpenCL ICDs in `/etc`, skips the distro's venus manifest
(`VK_LOADER_DRIVERS_DISABLE=virtio_icd.json`), sets `RUSTICL_ENABLE=zink`
and turns on WebGPU in Firefox. `--remove` undoes it. No Chrome flag is
set: none of them gives Chrome a hardware WebGPU adapter here.

## Consequences

- Firefox: WebGPU on the Mac's GPU. Chrome: SwiftShader (CPU) WebGPU, as
  before.
- OpenCL 3.0 device "zink ... (MOLTENVK)"; Geekbench 7 GPU runs
  (OpenCL). Zink reports one compute unit (Vulkan has no such query), so
  tools that size work by CUs (clpeak) under-fill the GPU.
- Each kernel launch crosses the Venus ring: launch-heavy work (ffmpeg's
  `nlmeans_opencl`, ~1000 launches per frame) is slow.
- Unbound descriptors are undefined on MoltenVK instead of zero; rusticl
  binds what kernels use. One Geekbench 7 workload (Feature Matching)
  fails its own validation: open.
- First install builds Mesa in the VM (needs LLVM, Rust; about 10-15
  minutes). Leaves the GL stack alone.
- On macOS 26 KosmicKrisp may make the null-descriptor patch unnecessary;
  the push-descriptor one is MoltenVK-only by its driver ID.
