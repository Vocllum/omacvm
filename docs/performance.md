# Omarchy on a Mac: Parallels vs UTM

Measured on 30 September 2026 on one machine, with the same Omarchy guest in
both hypervisors. These are one person's runs, not a lab study, but the gaps
are large enough to matter.

## Setup

| | |
|---|---|
| Host | MacBook Pro 16" (2024), Apple M4 Max (12 performance + 4 efficiency cores), 64 GB, macOS 15.7.4 |
| External display | 3840×2400, arranged above the built-in display |
| Guest | Omarchy (Arch Linux ARM, Hyprland 0.56), 16 vCPUs, 48 GB RAM |
| Parallels | Parallels Desktop 27.0.2, virtio-gpu with 3D acceleration (virgl) |
| UTM | UTM 5.0.6 beta (QEMU 10.0.12, HVF), virtio-gpu-gl (virgl), Apple Core OpenGL backend |
| Guest kernel | Arch Linux ARM kernel rebuilt with transparent huge pages enabled (see below), in both VMs |

## Summary

| | macOS native | Parallels | UTM |
|---|---|---|---|
| Geekbench 7 single-core | 3286 | **3240** (98.6 %) | 3020 (91.9 %) |
| Geekbench 7 multi-core | 26999 | **26823** (99.3 %) | 24230 (89.7 %) |
| Speedometer 3.1, Chrome | 46.3 | **43.9** | 25.8 (29.5–31.6 after tuning) |
| Desktop rendering | — | ✅ GPU (virgl) | ✅ GPU (virgl) |
| 120 Hz on the built-in display | — | ✅ | ✅ |
| External monitor | — | ✅ GPU-accelerated, follows the macOS arrangement and scaling, plug/unplug handled | ⚠️ flickers magenta above 1280×800 (see below) |
| Clipboard Mac ↔ VM | — | ✅ with a small helper for VM → Mac | ✅ (guest agent) |
| Notch area in full screen | — | ❌ black (hence Omanotch) | ❌ black on macOS 15; an option exists on macOS 27 |

**Verdict:** Parallels runs Omarchy at practically native CPU speed, is much
faster in the browser and handles a second monitor properly. UTM is free and
open source, but slower in everything measured and has no usable second
monitor with GPU acceleration.

## CPU

Geekbench 7.1 preview for Linux AArch64 in the guests, Geekbench 7.0 on macOS.
Parallels loses about 1 %. UTM loses 8–10 %; its guest also does not see the
SME/SME2 instruction sets, which Parallels and macOS expose. The largest single
gap is Geekbench's *Video Player* workload: 3000 in UTM against 4584 in
Parallels and 4775 native.

A simple single-thread CPU test (`openssl speed rsa2048`, signatures per
second) is identical everywhere: 3037 native, 3035 Parallels, 3018 UTM. Plain
computation is not the problem; memory and scheduling behaviour is.

## Browser: Speedometer 3.1

| Run | Score |
|---|---|
| macOS native | 46.3 |
| Parallels, Chrome with GPU (virgl) | 43.9 (user run), 42.7 (automated) |
| Parallels, Chrome headless | 44.5 |
| UTM, as found (Chrome compositing in software) | 24.8–25.8 |
| UTM, tuned (see below), Chrome with GPU | 31.6 |
| UTM, tuned, Chrome headless | 36.7 |

What helped in UTM:

- **Vulkan driver off.** Whenever UTM's Vulkan driver is enabled it starts QEMU
  with `ipa-granule-size=0x1000` (4 KB second-stage pages). That made
  mid-sized memory workloads twice as slow: a 20 MB typed-array loop in Node.js
  took 99 ms against 53 ms after switching Vulkan off (51 ms native).
- **GPU compositing for Chrome.** Chrome could not get an OpenGL ES 3.0
  context from virgl and fell back to software. A locally patched Mesa that
  reports multisampling support fixes that.

What did not close the gap: the remaining difference lines up with thread
wake-ups across CPUs, which cost about twice as much in UTM (46.6 µs per
cross-CPU round trip against 24.8 µs in Parallels; same-CPU round trips are
equal at ~1.8 µs). QEMU in UTM emulates the interrupt controller in user
space; that is the likely cause, but it is not proven.

## Memory and the guest kernel

The stock Arch Linux ARM kernel is built without transparent huge pages. In a
VM every page-table miss costs extra, so random memory access was about 2.5×
slower than native. Rebuilding the same kernel with
`CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y` helped a lot in both VMs:

| Single thread, lower is better | macOS | Parallels stock | Parallels THP | UTM stock | UTM THP |
|---|---|---|---|---|---|
| Random reads over 1 GiB | 0.186 s | 0.474 s | 0.21–0.27 s | 0.49–0.53 s | 0.26–0.28 s |
| First touch of 1 GiB (page faults) | 0.070 s | 0.138 s | 0.101 s | 0.24–0.27 s | 0.041–0.049 s |

Speedometer in Parallels went from 35 (stock kernel, Chromium) to 43.9 (THP
kernel, Chrome); both the kernel and the browser changed between those runs.

## External monitor

**Parallels:** with "use all displays in full screen", each Mac display gets
its own GPU-accelerated guest output. A small guest script reads the layout
Parallels reports (size, position, refresh rate) and applies it to Hyprland,
so the external monitor follows the macOS arrangement and HiDPI scaling, and
plugging/unplugging just works.

**UTM:** QEMU allows only one GPU-accelerated display adapter per VM.

- Two `virtio-gpu-gl-pci` adapters: QEMU refuses to start.
- One adapter with two outputs (`max_outputs=2`): the guest sees the second
  output, but UTM opens no window for it.
- A second, non-accelerated `virtio-gpu-pci` adapter: UTM opens a second
  window and Hyprland drives it, but every frame has to be copied from the GPU
  to that adapter, and the copy shows unfinished frames. Measured by grabbing
  the adapter's scanout: 20–57 of 120 frames partly or fully magenta at
  1920×1200 and above. Only the initial 1280×800 is clean. Disabling VRR,
  explicit sync, linear blits and damage tracking made no difference.

## The notch

Neither hypervisor uses the strip beside the camera housing in full screen on
macOS 15. Parallels has no option for it and says it avoids that area on
purpose; macOS does not let another app move Parallels' window there. UTM
5.0.6 adds an opt-in "use the area beside the camera housing" on macOS 27
only. [Omanotch](../README.md) works around it for Parallels.

## How the numbers were taken

- Geekbench and the first Speedometer runs: by hand in the guest's Chrome.
- Automated Speedometer: a small script drives Chrome over the DevTools
  protocol and reads the final score.
- Memory: a small C program (1 GiB random reads, first-touch page faults).
- Wake-up latency: two processes ping-pong one byte over pipes, pinned to the
  same or to different CPUs.
- Second-monitor corruption: frames grabbed straight from the display
  adapter's scanout inside the guest (`ffmpeg -f kmsgrab`), counting magenta
  pixels.
