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
  share memory on the Mac today, so no GL<->Vulkan interop can work. And
  even on KosmicKrisp, where ANGLE on Vulkan works (`kosmickrisp` track),
  Dawn refuses the adapter: it wants OPAQUE_FD semaphores and exportable
  optimal images, Venus offers SYNC_FD semaphores only.
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
   `CGLTexImageIOSurface2D`), `GL_EXT_semaphore_fd` in virgl, OPAQUE_FD
   semaphores and exportable optimal images in Venus; or a Graphite-Dawn
   compositor whose dmabufs Hyprland (virgl) could import (same sharing).

## Decision

Option 2 now; option 3 recorded as the way to Chrome. Option 1 leaves
macOS 15 users without both.

`src/app/guest/venus/install.sh` runs from the app's guest install when
the VM has Venus (three capsets and a host-visible region in virtio-gpu's
debugfs). It builds Mesa 26.2.4 (sha256-pinned) with
`mesa-zink-moltenvk-no-push-descriptors.patch` and
`mesa-zink-moltenvk-null-descriptor.patch` (and the `kosmickrisp`
track's `mesa-venus-incremental-present.patch`) into `/opt/omacvm-mesa`
(venus + zink + rusticl, no GL: virgl keeps serving GL), registers the
Vulkan and OpenCL ICDs in `/etc`, skips the distro's venus manifest
(`VK_LOADER_DRIVERS_DISABLE=virtio_icd.json`), sets `RUSTICL_ENABLE=zink`
and turns on WebGPU in Firefox. `--remove` undoes it. No Chrome flag is
set: none of them gives Chrome a hardware WebGPU adapter here. On the
host, `virgl-darwin-venus-moltenvk-zero-init.patch` hides
`shaderZeroInitializeWorkgroupMemory` on MoltenVK (its SPIRV-Cross cannot
compile it; every WebGPU shader with workgroup memory lost Firefox's
context).

## Consequences

- Firefox: WebGPU on the Mac's GPU (a WebGPU f32 matmul ran at 678 GFLOPS
  in the VM's Firefox, 223 in Firefox on the Mac in the same batch: the
  SPIR-V -> MoltenVK path compiles that kernel better than naga's MSL).
  Chrome: SwiftShader (CPU) WebGPU, as before.
- OpenCL 3.0 device "zink ... (MOLTENVK)"; Geekbench 7 GPU OpenCL 10673
  (Mac: 111530); ffmpeg's 4K `nlmeans_opencl` 3.2x the VM's 8 CPUs. Zink
  reports one compute unit (Vulkan has no such query), so tools that size
  work by CUs (clpeak) under-fill the GPU: 1.5 TFLOPS fp32 as reported,
  8.9 with 40 CUs forced (Mac OpenCL 15.6).
- Each kernel launch crosses the Venus ring: work made of many small
  kernels (Geekbench's Super Resolution, Particle Physics) loses most.
- Unbound descriptors are undefined on MoltenVK instead of zero; rusticl
  binds what kernels use. One Geekbench 7 workload (Feature Matching)
  fails its own validation: open.
- First install builds Mesa in the VM: 61 s on 8 vCPUs (M4 Max), after
  pacman fetched LLVM, Clang, Rust and bindgen. Leaves the GL stack alone.
- On macOS 26 KosmicKrisp may make the null-descriptor patch unnecessary;
  the push-descriptor one is MoltenVK-only by its driver ID.
