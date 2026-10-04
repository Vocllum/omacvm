# Findings for developers

What we learned building and measuring OmacVM that a user hunting for a fix
does not need: reviews, measuring pitfalls, how the VM apps work inside.
Problems with a fix you can apply are in
[troubleshooting.md](../troubleshooting.md); the current numbers are in
[benchmarks](../benchmarks/README.md).

## Parallels vs UTM, first measurements (September 2026)

From Omanotch's early days, before OmacVM's benchmark harness. The scores are
superseded by [benchmarks](../benchmarks/README.md); what is kept here is why
the gaps were there.

Setup: MacBook Pro 16" (2024), M4 Max, 64 GB, macOS 15.7.4; guest Omarchy
(Hyprland 0.56), 16 vCPUs, 48 GB; Parallels Desktop 27.0.2 and UTM 5.0.6 beta
(QEMU 10.0.12, HVF), both virtio-gpu with virgl; Arch Linux ARM's kernel
rebuilt with transparent huge pages in both.

- **UTM's Vulkan driver costs memory speed.** With it on, UTM starts QEMU with
  `ipa-granule-size=0x1000` (4 KB second-stage pages): a 20 MB typed-array loop
  in Node.js took 99 ms, 53 ms with Vulkan off (51 ms native).
- **Cross-CPU wake-ups cost twice as much in UTM**: 46.6 µs per round trip
  against 24.8 µs in Parallels (same-CPU round trips equal at about 1.8 µs).
  QEMU emulates the interrupt controller in user space; likely the cause, not
  proven. Plain computation is equal (`openssl speed rsa2048`: 3037 native,
  3035 Parallels, 3018 UTM). UTM's guest also does not see SME/SME2.
- **Transparent huge pages matter in a VM.** The stock Arch Linux ARM kernel
  has none, and every page-table miss costs extra:

  | Single thread, lower is better | macOS | Parallels stock | Parallels THP | UTM stock | UTM THP |
  |---|---|---|---|---|---|
  | Random reads over 1 GiB | 0.186 s | 0.474 s | 0.21–0.27 s | 0.49–0.53 s | 0.26–0.28 s |
  | First touch of 1 GiB (page faults) | 0.070 s | 0.138 s | 0.101 s | 0.24–0.27 s | 0.041–0.049 s |

- **UTM gets one GPU display per VM.** Two `virtio-gpu-gl-pci` adapters: QEMU
  refuses to start. One adapter with `max_outputs=2`: the guest sees the
  second output, UTM opens no window for it. A second, plain `virtio-gpu-pci`:
  UTM opens a window and Hyprland drives it, but every frame is copied over
  and the copy shows unfinished frames: 20–57 of 120 frames partly magenta at
  1920×1200 and above (grabbed with `ffmpeg -f kmsgrab`); only 1280×800 is
  clean. VRR, explicit sync, linear blits and damage tracking made no
  difference.
- **Chrome on UTM fell back to software compositing**: it got no OpenGL ES 3.0
  context from virgl until a patched Mesa reported multisampling.

How: Geekbench and the first Speedometer runs by hand; later Speedometer runs
driven over Chrome's DevTools protocol; memory with a small C program (1 GiB
random reads, first-touch faults); wake-ups with two processes ping-ponging a
byte over pipes, pinned to the same or different CPUs.
