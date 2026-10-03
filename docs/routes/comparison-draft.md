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

## Four ways: Parallels, UTM, VMware Fusion or OmacVM.app

OmacVM builds the same Omarchy VM in any of these. Everything in
[What you get](#what-you-get) works in all of them, except where the table
says otherwise.

**Which one?** Fastest and fine with paying: Parallels. Free with external
displays: VMware Fusion. Free and open source: UTM. Nothing else to install:
OmacVM.app.

| | Parallels Desktop | UTM 5 | VMware Fusion 26 | OmacVM.app |
|---|---|---|---|---|
| **Best for** | speed, least to set up | free, open source | free, external displays | one app, nothing else to install |
| **Price** | | | | |
| Cost | paid | **free**, open source | **free**, also for work | **free**, open source |
| CPUs and memory per VM | Standard: 4 CPUs, 8 GB<br>Pro or trial: more | **no cap** | **no cap** | **no cap** |
| **Speed** (the Mac itself = 100 %) | | | | |
| CPU: Geekbench 7 multi-core | {{P_GB}} % | {{U_GB}} % | {{F_GB}} % | {{A_GB}} % |
| Web apps: Speedometer 3.1 | {{P_SP}} % | {{U_SP}} % | 70 % | {{A_SP}} % |
| Browser graphics: MotionMark 1.3.1 | {{P_MM}} % | {{U_MM}} % | {{F_MM}} % | {{A_MM}} % |
| 3D: glmark2 (score) | {{P_GL}} | {{U_GL}} | {{F_GL}} | {{A_GL}} |
| **Graphics and video** | | | | |
| GPU path | virgl | virgl | vmwgfx, with a Hyprland fix OmacVM builds | virgl |
| GPU in Chrome, Chromium, Brave, Firefox | ✓ | ✓ (2.2.1) | {{F_BROWSERS}} | ✓ |
| YouTube 4K | {{P_YT}} | {{U_YT}} | {{F_YT}} | {{A_YT}} |
| GPU compute (Vulkan, OpenCL) | ✗ | {{U_VK}} | ✗ | {{A_VK}} |
| **Battery** (MacBook Pro 16" M4 Max, 100 Wh) | | | | |
| Idle | {{P_W_IDLE}} W · {{P_H_IDLE}} h | {{U_W_IDLE}} W · {{U_H_IDLE}} h | {{F_W_IDLE}} W · {{F_H_IDLE}} h | {{A_W_IDLE}} W · {{A_H_IDLE}} h |
| Reading (light) | {{P_W_LIGHT}} W · {{P_H_LIGHT}} h | {{U_W_LIGHT}} W · {{U_H_LIGHT}} h | {{F_W_LIGHT}} W · {{F_H_LIGHT}} h | {{A_W_LIGHT}} W · {{A_H_LIGHT}} h |
| YouTube 4K | {{P_W_VIDEO}} W · {{P_H_VIDEO}} h | {{U_W_VIDEO}} W · {{U_H_VIDEO}} h | {{F_W_VIDEO}} W · {{F_H_VIDEO}} h | {{A_W_VIDEO}} W · {{A_H_VIDEO}} h |
| Every core busy (heavy) | {{P_W_CPU}} W · {{P_H_CPU}} h | {{U_W_CPU}} W · {{U_H_CPU}} h | {{F_W_CPU}} W · {{F_H_CPU}} h | {{A_W_CPU}} W · {{A_H_CPU}} h |
| **Displays** | | | | |
| External displays | **✓ every one, in your macOS arrangement** | ✗ one display | **✓ every one, in your macOS arrangement** | {{A_EXT}} |
| Native Retina, 120 Hz | ✓ | ✓ | ✓ | ✓ |
| Resolution changes | **live** | fixed at boot | **live** | **live** |
| **Mac integration** | | | | |
| Wi-Fi, Bluetooth, audio, Night Shift, True Tone, wallpaper (OmacVM Bridge) | ✓ | ✓ | ✓ | ✓ |
| Media keys, trackpad gestures, Omanotch | ✓ | ✓ | ✓ | ✓ {{A_NOTCH}} |
| Cmd+Space and other Cmd shortcuts in full screen | ✓ after one Parallels setting | ✓ | ✓ | ✓ |
| Copy and paste text, both ways | ✓ | ✓ | ✓ when the pointer crosses the VM's edge | {{A_CLIP}} |
| **Setup** | | | | |
| Get it | buy it or start the trial | `brew install --cask utm@beta` | download after a Broadcom sign-in | `omacvm build --vm-type app` |
| Before first use | one Parallels setting | start UTM from the Dock | allow Accessibility for Fusion | allow Accessibility for OmacVM |
| Where the VM goes | **any folder, external drives too** | UTM's own library | **any folder, external drives too** | **any folder, external drives too** |
| Status | most tested | UTM 5 is a beta | new in 2.2 | {{A_STATUS}} |

On the Mac itself, for the same loads: idle {{M_W_IDLE}} W ({{M_H_IDLE}} h),
reading {{M_W_LIGHT}} W ({{M_H_LIGHT}} h), YouTube 4K {{M_W_VIDEO}} W
({{M_H_VIDEO}} h, AV1 in hardware), every core busy {{M_W_CPU}} W
({{M_H_CPU}} h).

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
