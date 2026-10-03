# Troubleshooting: what we found

Problems we hit while building the VMware Fusion route and benchmarking all
three routes, and what fixed them. Each one is written as symptom, cause, fix
and where the fix lives, so you can find it again when it comes back.

Most of these are not obvious from the outside: the symptom points somewhere
else than the cause. Recipes and the general failure table are in
[AGENTS.md](../AGENTS.md) (sections 6 and 7).

| # | Route | Finding |
|---|---|---|
| 1 | Fusion | [Black screen with stock Omarchy](#1-fusion-black-screen-with-stock-omarchy) |
| 2 | Fusion | [Browsers draw everything in software](#2-fusion-browsers-draw-everything-in-software) |
| 3 | Fusion | [Displays sit in the wrong place on a Retina Mac](#3-fusion-displays-sit-in-the-wrong-place-on-a-retina-mac) |
| 4 | Fusion | [No hover or clicks on Omanotch's strip](#4-fusion-no-hover-or-clicks-on-omanotchs-strip) |
| 5 | Fusion | [Omanotch cannot find the Mac](#5-fusion-omanotch-cannot-find-the-mac) |
| 6 | Fusion | [Cmd+Space opens Spotlight, not Omarchy](#6-fusion-cmdspace-opens-spotlight-not-omarchy) |
| 7 | Fusion | [Setup facts: download, permissions, graphics memory, dmesg noise](#7-fusion-setup-facts) |
| 8 | Fusion | [`no such host` during the build](#8-fusion-no-such-host-during-the-build) |
| 9 | All | [A swipe jumps to the next workspace when the fingers lift](#9-all-routes-a-swipe-jumps-when-the-fingers-lift) |
| 10 | All | [The Mac's pointer hides over the VM app's other windows](#10-all-routes-the-macs-pointer-hides-over-the-vm-apps-other-windows) |
| 11 | All | [Benchmarks that don't compare](#11-benchmarks-chromium-vs-chrome-and-the-screensaver) |
| 12 | UTM | [Moving a UTM VM deletes it](#12-utm-moving-a-vm-and-changing-its-config) |
| 13 | Fusion | [Security review of PR #1](#13-security-review-of-the-fusion-route-pr-1) |
| 14 | UTM | [Chrome has no GPU, then WebGL comes out empty](#14-utm-chrome-has-no-gpu-then-webgl-comes-out-empty) |
| 15 | UTM | [UTM uses 15 W while Omarchy sits idle](#15-utm-uses-15-w-while-omarchy-sits-idle) |
| 16 | All | [MotionMark gives no stable result](#16-motionmark-gives-no-stable-result) |

## 1. Fusion: black screen with stock Omarchy

- **Symptom:** the VM boots to a black screen. SDDM's greeter never shows. The
  journal has `invalid arguments for wl_surface.attach` for every app.
- **Cause:** Fusion's GPU driver, `vmwgfx`, imports the apps' dmabufs as TTM
  surface handles, not GEM handles. Hyprland closes the imported handle with
  `GEM_CLOSE`, gets `EINVAL` and rejects the buffer. So every GPU client dies
  on its first frame.
- **Fix:** a one-file Hyprland patch by Pascal-0x90
  ([hyprwm/Hyprland#12966](https://github.com/hyprwm/Hyprland/discussions/12966)).
  When the driver is `vmwgfx` and `GEM_CLOSE` fails, it releases the handle with
  `DRM_VMW_UNREF_SURFACE`. There is no upstream pull request, so OmacVM carries
  the patch and builds Hyprland itself:
  - from the exact commit the installed package was built from (the stock
    binary names it in `Hyprland --version`), checked after the download;
  - as the desktop user, only the install step runs as root;
  - the package's own binary stays as `/usr/bin/Hyprland.stock`;
  - a pacman hook builds it again after every Hyprland update (10 to 20
    minutes, inside `omarchy update`).
- **Where:** `src/fusion/guest/build-hyprland.sh`,
  `src/fusion/guest/hyprland-vmwgfx-dmabuf.patch`, the hook
  `/etc/pacman.d/hooks/zz-omacvm-hyprland.hook` written by
  `src/fusion/guest/install.sh`. In the VM: state in
  `/var/lib/omacvm/hyprland-vmwgfx`, log in
  `/var/cache/omacvm/hyprland-vmwgfx/build.log`.
- **If it comes back:** `omacvm apply --vm NAME`, or in the VM
  `/usr/local/lib/omacvm/fusion/build-hyprland.sh`. To test the hook, reinstall
  with `pacman -S omarchy/hyprland`. Plain `pacman -S hyprland` takes Arch's
  `extra` first and downgrades Hyprland.

## 2. Fusion: browsers draw everything in software

- **Symptom:** Chromium, Chrome, Brave and Firefox are slow on Fusion, and
  WebGL is off or runs on `llvmpipe` (the CPU).
- **Cause:** Chromium's GPU blocklist has an entry for VMware's GPU on Linux
  (`software_rendering_list`, entry 176, "VMware is buggy on Linux"). Firefox
  counts every `vmwgfx` driver as software GL (`widget/gtk/GfxInfo.cpp`), so it
  draws pages with software WebRender and WebGL on `llvmpipe`. The GPU works
  fine with the vmwgfx fix above.
- **Fix:** OmacVM adds `--ignore-gpu-blocklist` to `/etc/chromium-flags.conf`
  and `/etc/chrome-flags.conf`, which Omarchy never rewrites, and to Brave's
  `~/.config/brave-flags.conf`. Omarchy's `omarchy install browser brave`
  replaces that file, so run `omacvm apply` after installing Brave. For
  Firefox it writes `/usr/lib/firefox/defaults/pref/omacvm-fusion.js`, which
  sets `gfx.blacklist.layers.opengl`, `gfx.blacklist.webrender` and
  `gfx.blacklist.webgl-use-hardware` to 1 (`gfx.webrender.all` and
  `layers.acceleration.force-enabled` don't help). Quit each browser fully
  afterwards: closing the window is not enough.
- **Check:** `chrome://gpu` says "Hardware accelerated" for Compositing,
  Rasterization and WebGL; Firefox's `about:support` says "Compositing:
  WebRender" (not "(Software)") and the WebGL renderer is SVGA3D.
- **Note:** WebGPU then shows "Hardware accelerated", but Fusion gives Linux
  no Vulkan, so there is no real WebGPU or GPU compute behind it. Video is
  decoded on the CPU: Mesa has no VA-API driver for `vmwgfx`, so YouTube 4K
  plays in software in every browser.
- **Where:** `src/fusion/guest/install.sh`. Google Chrome from
  `src/bench/install-chrome.sh` reads `/etc/chrome-flags.conf` through its
  `google-chrome-stable` launcher; Google's own launcher reads no flags file.

## 3. Fusion: displays sit in the wrong place on a Retina Mac

- **Symptom:** with the VM full screen on a Retina Mac, the Mac's pointer and
  Omarchy's pointer drift apart. To reach the notch strip or an external
  display you cross an invisible area first.
- **Cause:** Fusion sends its display layout in pixels. Hyprland's monitor
  positions are in logical points. At scale 2 the built-in display sat about
  1200 points too low (the external display ended 1200 points above it, not
  43).
- **Fix:** divide Fusion's positions by the shared scale before passing them to
  Hyprland. This only works when every output has the same scale; with mixed
  scales the positions are passed as they are.
- **Where:** `src/fusion/guest/omacvm-fusion-displays` (`apply()`).

## 4. Fusion: no hover or clicks on Omanotch's strip

- **Symptom:** on Fusion, the pointer gets pushed out of the strip beside the
  notch as soon as it enters. Nothing in Omarchy's bar there reacts to hover or
  clicks.
- **Cause:** Fusion moves the Mac's pointer whenever the guest moves its cursor.
  Parallels and UTM don't. Omanotch's `notchcast` nudged or moved the guest
  cursor when the pointer entered or left the strip, and Fusion pulled the Mac
  pointer straight back with it.
- **Fix:** on VMware, `notchcast` only hides and shows the guest cursor; it
  never moves it.
- **Where:** the [Omanotch](https://github.com/gillesgoetsch/omanotch) repo,
  `notchcast` (on its main branch). Not in this repo.

## 5. Fusion: Omanotch cannot find the Mac

- **Symptom:** Omanotch's strip stays empty on a Fusion VM; `notchcast` cannot
  connect.
- **Cause:** `notchcast` looked for the Mac at the default gateway. On Fusion's
  NAT network the gateway is `.2` (Fusion's NAT), and the Mac is `.1`.
- **Fix:** OmacVM passes the Mac's address to `notchcast` as `NOTCHBAR_HOST`,
  on every route. `notchcast` also knows Fusion now (on Omanotch's main branch).
- **Where:** `src/guest/install.sh` writes
  `~/.config/systemd/user/notchcast.service.d/omacvm-host.conf`.

## 6. Fusion: Cmd+Space opens Spotlight, not Omarchy

- **Symptom:** in a full-screen Fusion VM, Cmd+Space and other Cmd shortcuts go
  to macOS.
- **Cause:** Fusion, like UTM, keeps Cmd combos for macOS.
- **Fix:** OmacVM Gestures catches Cmd combos while the VM is full screen and in
  front, and sends them to Omarchy as Super, through the VM's
  `omacvm-gestures` daemon. Same as on UTM.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (the event tap, `NET_UTM ||
  NET_FUSION`).

## 7. Fusion: setup facts

Small things that cost time the first time.

| Fact | What to do | Where |
|---|---|---|
| Homebrew has no Fusion cask: Broadcom wants a sign-in for the download | support.broadcom.com > My Downloads > VMware Fusion > the newest version, drag it to Applications | README, Requirements |
| On its first start Fusion asks for Accessibility | click OK, then turn VMware Fusion on in System Settings > Privacy & Security > Accessibility | |
| Graphics memory comes out of the VM's own RAM | OmacVM gives a quarter of the VM's memory, at least 1 GB and at most 8 GB (Fusion's limit). `--graphics-gb` changes it | `src/cmd/build.sh` (`gfx_auto`), `src/vm/fusion.sh` (`svga.graphicsMemoryKB`) |
| `mob memory overflow` lines in `dmesg` | harmless: the vmwgfx driver raising its own limit | |
| A leak of GPU memory with older Mesa | Mesa 26.2.1 or newer fixes an svga dmabuf leak; check with `pacman -Q mesa` | |

## 8. Fusion: `no such host` during the build

- **Symptom:** the build fails while downloading many things at once (it first
  failed in the `yay` build, a Go build fetching its modules) with
  `no such host`.
- **Cause:** Fusion's NAT answers DNS itself and drops lookups when many come
  at once.
- **Fix:** public DNS (1.1.1.1, 9.9.9.9) only while OmacVM installs, then
  Fusion's DNS again. Fusion's DNS follows the Mac's, so a VPN, a Pi-hole or
  company DNS keeps working afterwards. `omacvm check` has a line for it.
- **Where:** `src/fusion/guest/dns.sh` (`on` at the start of
  `src/fusion/guest/install.sh`, `off` at the end of `src/guest/install.sh`),
  check in `src/guest/check.sh`.

## 9. All routes: a swipe jumps when the fingers lift

- **Symptom:** a three-finger swipe moves nothing while the fingers move, then
  the next workspace appears at once when they lift.
- **Cause:** Omarchy turns Hyprland's workspace animation off.
- **Fix:** with trackpad gestures on, OmacVM adds a slide animation for
  workspaces, like macOS Spaces, unless you already set a `workspaces`
  animation yourself.
- **Where:** `src/gestures/guest/install.sh`, writes to
  `~/.config/hypr/input.lua`.

## 10. All routes: the Mac's pointer hides over the VM app's other windows

- **Symptom:** the Mac's pointer disappears over any window of the VM app, for
  example Fusion's library window, not only over the full-screen VM.
- **Cause:** OmacVM Gestures hid the pointer over every window of the VM app.
- **Fix:** it now hides the pointer only over a window that fills its display.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (the hit test: the window must
  cover the display's width, and its height minus the menu bar).

## 11. Benchmarks: Chromium vs Chrome, and the screensaver

- **Symptom:** the same VM gives very different browser scores from one day to
  the next. Parallels scored 35.4 in Speedometer 3.1, after about 45 before.
- **Cause:** the 35.4 was Arch's Chromium (153) in the VM, the 45 Google
  Chrome. Arch's Chromium is much slower than Google's Chrome. Omarchy's
  screensaver and lock can also start in the middle of a run.
- **Fix:** always benchmark Google Chrome, on the Mac and in the VM, with the
  same flags Omarchy uses. Turn the screensaver and lock off
  (`omacvm disable idle-lock`).
- **Where:** `src/bench/install-chrome.sh` (Chrome for Linux ARM in the VM),
  `src/bench/bench.sh`. The full method: [benchmarks/](benchmarks/README.md).

## 12. UTM: moving a VM, and changing its config

- **Symptom:** moving a UTM VM to another folder through UTM's scripting lost
  the VM. Separately, UTM's AppleScript `update configuration` started failing on
  OmacVM's VMs.
- **Cause:** a moved VM keeps its UUID, so UTM keeps a stale entry. Deleting the
  stale entry deleted the moved files too, because UTM follows its bookmark to
  the new place. And `update configuration` fails once the VM has OmacVM's
  custom icon.
- **Fix:** `--vm-dir` (where the VM goes) is for Parallels and Fusion only; UTM
  keeps its VMs in its own library. Config changes after the icon is set go
  straight into the VM's `config.plist` (UTM reloads it), not through
  AppleScript.
- **Where:** `src/cmd/build.sh` (refuses `--vm-dir` with `--vm-type utm`),
  `src/vm/utm.sh` (`utm_drop_live` uses AppleScript before the icon is set,
  `utm_set_icon` edits `config.plist`).

## 13. Security review of the Fusion route (PR #1)

The review found places where the Fusion route trusted too much. All are fixed
on the branch.

| What | Fix | Where |
|---|---|---|
| Hyprland source | built from the exact commit the package's binary names, checked after the download | `src/fusion/guest/build-hyprland.sh` |
| VMware Tools recipe | Arch's `open-vm-tools` recipe pinned to commit `a2334c0c` (tag `6-13.1.0-3`) | `src/fusion/guest/build-open-vm-tools.sh` (`RECIPE_COMMIT`) |
| Builds as root | both builds run as the desktop user; only the install runs as root | both build scripts |
| The pacman hook runs as root | it runs a root-owned copy of the build script in `/usr/local/lib/omacvm/fusion` | `src/fusion/guest/install.sh` |
| The clipboard agent's X display | a private Xvfb display with its own xauth cookie (in `$XDG_RUNTIME_DIR`) and no TCP listener | `src/fusion/guest/omacvm-fusion-clipboard` |
| The guest guessed the Mac's address | the Mac passes it (`--host`); the guest accepts only an address ending in `.1` | `src/cmd/apply.sh`, `src/guest/install.sh` |
| Fusion's `networking` file | strict parsing: the first `VNET_8_HOSTONLY_SUBNET` line, and only a private address (not UTM's) | `src/lib/mac.sh` (`fusion_host`), `src/bridge/mac/main.swift`, `src/gestures/mac/omacvm-gestures.c` |
| Listeners on the Mac | Gestures never binds `0.0.0.0`: an address it cannot parse, or `0.0.0.0` itself, means no listener on that network | `src/gestures/mac/omacvm-gestures.c` (`serverThread`) |

## 14. UTM: Chrome has no GPU, then WebGL comes out empty

- **Symptom:** on UTM, `chrome://gpu` says "Software only" and WebGL is off
  (before 2.2.1). With 2.2.1, the GPU was on, but a page that read an
  antialiased WebGL canvas back got nothing, and the whole Chrome window
  could turn transparent.
- **Cause:** UTM's virglrenderer reports `max_samples 1` to Linux. OpenGL ES
  3.0 needs 4 samples, so Chrome's ANGLE refuses ES 3.0 and turns the GPU
  off. try-omarchy has the same problem
  ([try-omarchy#230](https://github.com/omacom/try-omarchy/issues/230)). And
  UTM can't really draw into multisampled buffers.
- **Fix:** a small preload library (`src/utm/guest/virgl-msaa.c`, from
  `/etc/ld.so.preload`) reports 4 samples to Mesa and creates every buffer
  single-sampled. The picture is right, without antialiasing. OmacVM also
  sets UTM's default renderer: with "Apple Core OpenGL" Chrome stays without
  GPU. After `omacvm update`, restart the browsers.
- **Note:** video is decoded on the CPU: UTM's VA-API lists no decode
  profiles. Chrome's "Video Decode: Hardware accelerated" is only a flag.
- **Where:** `src/utm/guest/install.sh`, `src/vm/utm.sh`, `src/cmd/apply.sh`.

## 15. UTM uses 15 W while Omarchy sits idle

- **Symptom:** with an idle Omarchy desktop on UTM, the whole Mac draws about
  15 W; Parallels, Fusion and OmacVM.app draw 5.5 to 6.2 W. One of UTM's QEMU
  threads runs at 100 % on the Mac while every CPU in Linux is idle.
- **Cause:** a bug in UTM's QEMU (`hvf_wfi()`): a virtual CPU only sleeps if
  its next timer is more than 2 ms away. Linux ticks every millisecond
  (HZ=1000) on a CPU that hasn't stopped its tick, so that CPU spins in and
  out of the guest instead of sleeping: up to 170,000 idle calls a second.
  Fixed in newer QEMU (OmacVM.app's runtime has it) and in
  [qemu-utm#5](https://github.com/helixml/qemu-utm/pull/5); UTM 5.0.6 still
  ships the old code.
- **Check:** in the VM, `grep -E "^cpu: |idle_calls" /proc/timer_list` shows
  millions of idle calls on some CPUs; on the Mac, `ps -M -p $(pgrep -x
  QEMULauncher)` shows one thread near 100 %.
- **Tried:** a guest kernel with HZ=250 (4 ms ticks, built like the
  memory-optimized kernel) halves it: UTM's QEMU at 49 % instead of 102 % at
  idle. Other short timers still make some CPUs spin.
- **Fix:** it needs a UTM with the upstream QEMU fix. Until then, for battery
  life use VMware Fusion, Parallels or OmacVM.app.

## 16. MotionMark gives no stable result

- **Symptom:** MotionMark 1.3.1 scores 1 to 4 on Parallels, UTM and
  OmacVM.app, with ±100 % to ±1900 % per subtest; every subtest stays at its
  minimum. On Fusion it measures normally (2368 at 120 fps, ±9 %).
- **Cause:** MotionMark raises each scene's complexity until the frame rate
  drops, which needs steady frame timing. Chrome's frames on the virgl routes
  come too unevenly for that, even at the lowest complexity. Animations and
  scrolling still look smooth in use; the benchmark can't settle.
- **Where:** `src/bench/browser-bench.py` prints the subtest breakdown.
