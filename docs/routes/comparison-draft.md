# Draft: the routes section for the README

This is the planned README section that compares Parallels, UTM and VMware
Fusion. It waits for the benchmark numbers: once they are in, fill in the
placeholders and paste everything below the line into the README, in place of
"Three routes: Parallels, UTM or VMware Fusion" and "How fast".

> [!WARNING]
> **Draft.** Not in the README yet. `{{…}}` marks a number still to measure
> ([benchmarks](../benchmarks/README.md)). Links and image paths are written
> for the README at the repository root, so they don't work on this page.

Before pasting:

- [ ] Fill every `{{…}}` from `report.py`, and draw `docs/images/benchmarks.svg`
  with `chart.py`.
- [ ] Bold the best value in each speed row.
- [ ] Check "Want the fastest VM: Parallels" still holds with the new numbers.
- [ ] Omanotch on Fusion: only once Omanotch's `fusion` branch is merged.
- [ ] Scroll momentum on Fusion: confirm on a Fusion VM.
- [ ] Parallels' Speedometer: measured again with Chrome (35.4 was Chromium and
  doesn't count).

---

## Three routes: Parallels, UTM or VMware Fusion

OmacVM builds the same Omarchy VM in any of these three apps. Everything in
[What you get](#what-you-get) works on all three, except the display rows below.
They differ in price, speed and displays.

**Which one?** Want the fastest VM and fine with paying: Parallels. Want it free
and use external displays: VMware Fusion. Want it free and open source, and one
screen is enough: UTM.

| | Parallels Desktop | UTM 5 | VMware Fusion 26 |
|---|---|---|---|
| **Best for** | speed, least to set up | free and open source, one screen | free, with external displays |
| **Price** | | | |
| Cost | paid | **free**, open source | **free**, also for work |
| CPUs and memory per VM | Standard: 4 CPUs, 8 GB<br>Pro or trial: more | **no licence cap** | **no licence cap** |
| **Speed** (the Mac itself = 100 %) | | | |
| CPU: Geekbench 7 multi-core | {{PARALLELS_GEEKBENCH_PCT}} % | {{UTM_GEEKBENCH_PCT}} % | {{FUSION_GEEKBENCH_PCT}} % |
| Web apps: Speedometer 3.1 | {{PARALLELS_SPEEDOMETER_PCT}} % | {{UTM_SPEEDOMETER_PCT}} % | 70 % |
| Browser graphics: MotionMark 1.3.1 | {{PARALLELS_MOTIONMARK_PCT}} % | {{UTM_MOTIONMARK_PCT}} % | {{FUSION_MOTIONMARK_PCT}} % |
| 3D in the browser: WebGL Aquarium | {{PARALLELS_AQUARIUM_PCT}} % | {{UTM_AQUARIUM_PCT}} % | {{FUSION_AQUARIUM_PCT}} % |
| OpenGL: glmark2 (score; no Mac version to compare) | {{PARALLELS_GLMARK2}} | {{UTM_GLMARK2}} | {{FUSION_GLMARK2}} |
| **Graphics** | | | |
| GPU path | virgl (OpenGL) | virgl (OpenGL) | vmwgfx (SVGA3D), with a Hyprland fix OmacVM builds |
| GPU compute (Vulkan, OpenCL) | ✗ | ✗ | ✗ |
| **Displays** | | | |
| External displays | **✓ every one, in your macOS arrangement** | ✗ one display | **✓ every one, in your macOS arrangement** |
| Native Retina, 120 Hz | ✓ | ✓ | ✓ (120 Hz as reported by the guest) |
| Resolution changes | **live** | fixed at boot, reboot to change | **live** |
| **Mac integration** | | | |
| Wi-Fi, Bluetooth, audio, Night Shift, True Tone, wallpaper (OmacVM Bridge) | ✓ | ✓ | ✓ |
| Media keys with Omarchy's popup | ✓ | ✓ | ✓ |
| Trackpad gestures, Omanotch | ✓ | ✓ | ✓ |
| macOS-native scroll momentum *(experimental)* | ✓ most tested | ✓ | ✓ |
| Copy and paste text, both ways | ✓ | ✓ | ✓ when the pointer enters or leaves the VM |
| Cmd+Space and other Cmd shortcuts in full screen | ✓ after one Parallels setting | ✓ | ✓ |
| Keyboard layout, memory tuning, snapshots | ✓ | ✓ | ✓ |
| **Setup** | | | |
| Get the app | buy it or start the trial | `brew install --cask utm@beta` | download after a Broadcom sign-in |
| Before first use | set *Send macOS system shortcuts* to Always | start UTM from the Dock or Spotlight, never in the background | allow Accessibility for Fusion |
| Omarchy updates | as usual | as usual | each Hyprland update also rebuilds Hyprland (10 to 20 minutes) |
| Where the VM goes | **any folder, external drives too** | UTM's own library | **any folder, external drives too** |
| Status | most tested | UTM 5 is still a beta | newest route |

<p align="center">
  <img src="docs/images/benchmarks.svg" alt="Bar chart: Geekbench 7, Speedometer 3.1, MotionMark 1.3.1 and WebGL Aquarium for Parallels Desktop, UTM and VMware Fusion, each as a percentage of the Mac itself. In Speedometer: Parallels {{PARALLELS_SPEEDOMETER_PCT}} %, UTM {{UTM_SPEEDOMETER_PCT}} %, VMware Fusion 70 %. GPU compute is not available in any of the three." width="100%">
</p>

Measured on a MacBook Pro M4 Max (macOS 15.7.4) with 16 CPUs and 48 GB per VM,
one VM at a time, in full screen: Parallels Desktop {{PARALLELS_VERSION}}, UTM
{{UTM_VERSION}}, VMware Fusion 26.0.1. Speedometer, MotionMark and the Aquarium
run in Google Chrome 154, on the Mac and in each VM. Medians of 3 runs.
Parallels needs Pro or the trial for 16 CPUs and 48 GB. Standard stops at 4 CPUs
and 8 GB, so expect lower numbers there. None of the three apps gives Linux
Vulkan or OpenCL, so there is no GPU compute test in the VMs. How to run the
same tests: [docs/benchmarks](docs/benchmarks/README.md).

<details>
<summary>The raw numbers</summary>

| | Mac | Parallels | UTM | VMware Fusion |
|---|---|---|---|---|
| Geekbench 7 multi-core | {{MAC_GEEKBENCH_MULTI}} | {{PARALLELS_GEEKBENCH_MULTI}} | {{UTM_GEEKBENCH_MULTI}} | {{FUSION_GEEKBENCH_MULTI}} |
| Geekbench 7 single-core | {{MAC_GEEKBENCH_SINGLE}} | {{PARALLELS_GEEKBENCH_SINGLE}} | {{UTM_GEEKBENCH_SINGLE}} | {{FUSION_GEEKBENCH_SINGLE}} |
| Speedometer 3.1 | 62.9 | {{PARALLELS_SPEEDOMETER}} | {{UTM_SPEEDOMETER}} | 43.9 |
| MotionMark 1.3.1 | 5865 | {{PARALLELS_MOTIONMARK}} | {{UTM_MOTIONMARK}} | {{FUSION_MOTIONMARK}} |
| WebGL Aquarium (fps) | {{MAC_AQUARIUM}} | {{PARALLELS_AQUARIUM}} | {{UTM_AQUARIUM}} | {{FUSION_AQUARIUM}} |
| glmark2 | no macOS version | {{PARALLELS_GLMARK2}} | {{UTM_GLMARK2}} | {{FUSION_GLMARK2}} |

</details>

### About the Fusion route

Stock Omarchy shows a black screen on Fusion. Fusion's GPU driver (`vmwgfx`)
hands Hyprland buffers it can't release, so every app dies on its first frame.
OmacVM builds Hyprland with a one-file fix for that (by Pascal-0x90,
[hyprwm/Hyprland#12966](https://github.com/hyprwm/Hyprland/discussions/12966))
and builds it again after every Hyprland update. It also builds VMware Tools
itself, because Arch Linux ARM doesn't package them. They give you the display
layout and copy and paste. Everything about the route:
[docs/routes/vmware-fusion.md](docs/routes/vmware-fusion.md).
