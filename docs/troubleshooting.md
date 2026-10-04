# Troubleshooting: what we found

Problems we hit while building the VMware Fusion route, the browser GPU on
every route and benchmarking all four ways, and what fixed them. Each one is written as symptom, cause, fix
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
| 15 | UTM | [UTM idle power is being measured again](#15-utm-idle-power-is-being-measured-again) |
| 16 | All | [MotionMark gives no stable result](#16-motionmark-gives-no-stable-result) |
| 17 | All | [Security review of the Mac and guest sides; "another SSH host key"](#17-security-review-of-the-mac-and-guest-sides) |
| 18 | All | [No snapshots in GRUB with Arch Linux ARM's own kernel](#18-all-routes-no-snapshots-in-grub-with-arch-linux-arms-own-kernel) |
| 19 | All | [Two VMs in one app both get the swipes and Cmd shortcuts](#19-all-routes-two-vms-in-one-app-both-get-the-swipes-and-cmd-shortcuts) |
| 20 | UTM | [Cmd+W stops the VM](#20-utm-cmdw-stops-the-vm) |
| 21 | UTM, Fusion | [No sound at all, no microphone](#21-utm-fusion-no-sound-at-all-no-microphone) |
| 22 | Parallels, Fusion, app | [The microphone records nothing, or silence](#22-parallels-fusion-app-the-microphone-records-nothing-or-silence) |
| 23 | app | [Chrome hangs in Basemark Web 3.0, the screen flickers](#23-app-chrome-hangs-in-basemark-web-30-the-screen-flickers) |

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
- **Where:** [Omanotch](../src/omanotch/README.md)'s `notchcast`,
  `src/omanotch/guest/notchcast/notchcast.c`.

## 5. Fusion: Omanotch cannot find the Mac

- **Symptom:** Omanotch's strip stays empty on a Fusion VM; `notchcast` cannot
  connect.
- **Cause:** `notchcast` looked for the Mac at the default gateway. On Fusion's
  NAT network the gateway is `.2` (Fusion's NAT), and the Mac is `.1`.
- **Fix:** OmacVM passes the Mac's address to `notchcast` as `NOTCHBAR_HOST`,
  on every route. `notchcast` also knows Fusion now.
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

## 15. UTM idle power is being measured again

- **Symptom:** the benchmark measured about 15 W for the whole Mac with an
  idle Omarchy desktop on UTM, against 5.5 to 6.2 W on Parallels, Fusion and
  OmacVM.app. A later check showed about 5 W on UTM at idle, also with an
  app open.
- **What we know:** UTM's QEMU only lets a virtual CPU sleep if its next timer
  is more than 2 ms away (`hvf_wfi()`), so a CPU with a running 1 ms tick
  wakes up more often. With nothing busy in the VM, Linux stops the tick and
  this costs little. The benchmark's run most likely had something busy in
  the VM.
- **Next:** a fair re-run, same state on every route
  ([#32](https://github.com/gillesgoetsch/omacvm/issues/32)).

## 16. MotionMark gives no stable result

- **Symptom:** MotionMark 1.3.1 scores 1 to 4 on Parallels, UTM and
  OmacVM.app, with ±100 % to ±1900 % per subtest; every subtest stays at its
  minimum. On Fusion it measures normally (2368 at 120 fps, ±9 %).
- **Cause:** MotionMark raises each scene's complexity until the frame rate
  drops, which needs steady frame timing. Chrome's frames on the virgl routes
  come too unevenly for that, even at the lowest complexity. Animations and
  scrolling still look smooth in use; the benchmark can't settle.
- **Where:** `src/bench/browser-bench.py` prints the subtest breakdown.

## 17. Security review of the Mac and guest sides

- **Symptom:** `omacvm apply`, `check` or a build stops with "answers with
  another SSH host key than the one OmacVM remembered".
- **Cause:** OmacVM remembers each VM's SSH host key the first time it sets the
  VM up (build, apply) and refuses another one later. A rebuilt or reinstalled
  VM has a new key; anything else answering at the VM's address does too.
- **Fix:** after a rebuild, `omacvm apply --vm NAME --reset-host-key`.
- **Where:** `src/lib/mac.sh` (`gssh`, `hostkey_changed`), `src/lib/vm.sh`
  (`vm_pin`); the keys are in `~/Library/Application Support/omacvm/known_hosts/`.

What the review found, and the fixes:

| What | Fix | Where |
|---|---|---|
| No host-key check; `omacvm update` sent the Bridge token to any running VM that said it had OmacVM | host keys remembered per VM (above); `update` only updates VMs OmacVM set up from this Mac (a remembered key, or OmacVM's note or icon on the VM), others need `omacvm update --vm NAME` once | `src/lib/mac.sh`, `src/lib/vm.sh` (`vm_marked`), `src/cmd/update.sh` |
| Gestures let any VM on the VM networks connect (trackpad frames, Cmd keys, capture off) | every listener wants the Bridge token in the hello; daemons from before it are let in only from the VMs OmacVM had set up (their MAC addresses, listed once in `~/Library/Application Support/omacvm/gestures-legacy`), until apply or update replaces them | `src/gestures/mac/omacvm-gestures.c`, `src/gestures/guest/omacvm-gestures`, `src/mac/gestures-legacy.sh` |
| A quote in a UTM VM's name ran AppleScript | the name goes in as an argument | `src/lib/mac.sh` (`utm_ip`) |
| The clipboard helper followed links in the folder the guest writes | only a plain file, never through a link, at most 4 MiB | `src/clipboard/mac/omacvm-clip-in` |
| A full name with `"`, `$` or a backtick ran in the install script; the hostname was not checked | values written with `printf %q`; hostname `^[a-z0-9][a-z0-9-]{0,62}$` | `src/vm/omarchy-install.sh`, `src/cmd/build.sh` |
| Root followed links in the user's home (`chown`, `monitors.lua`, the notchcast drop-in, the kernel build) | `chown -h`; those files written as the user; the kernel built in a folder of root's and installed from a copy root owns | guest installers, `src/kernel/build-thp-kernel.sh` |
| The Bridge: a slow client held a thread, a negative `Content-Length` crashed it | a deadline for the whole request, at most 32 requests at a time (16 per address), 400 for a bad length | `src/bridge/mac/server.swift` |

Left open: the Mac apps are signed ad hoc with a requirement that names only
their identifier, so another program signed the same way could keep their
privacy permissions (signing releases with a Developer ID fixes that); Omanotch
and Arch Linux ARM's kernel recipe follow their latest versions (not pinned to
a commit). The try-omarchy image is pinned: `src/vm/live/build-live.sh`
(`dmg_sha256`) refuses a `TryOmarchy.dmg` whose SHA-256 differs.

## 18. All routes: no snapshots in GRUB with Arch Linux ARM's own kernel

- **Symptom:** without the memory-optimized kernel, GRUB has no "Omarchy
  snapshots" menu, and `/proc/cmdline` says `BOOT_IMAGE=/Image` with no
  initramfs (no Plymouth splash, and a read-only snapshot would get no
  writable overlay). Found when `omacvm disable thp-kernel` went back to the
  stock kernel.
- **Cause:** Arch Linux ARM installs its kernel as `/boot/Image`. GRUB's
  `10_linux` lists it but looks for `initramfs-Image.img`, which does not
  exist; grub-btrfs only looks at `vmlinuz-*`, so it found no kernel at all
  ("Kernels not found"). The memory-optimized kernel never had the problem:
  it is `vmlinuz-linux-aarch64-thp`.
- **Fix:** a copy of the kernel as `/boot/vmlinuz-linux`, which pairs with
  `initramfs-linux.img` in both, kept current by a pacman hook after every
  kernel update; GRUB boots it by default when the memory-optimized kernel is
  off. `omacvm check` fails "bootable snapshots" when GRUB has no snapshots
  menu.
- **Where:** `src/kernel/stock-kernel.sh` (copy and hooks
  `/etc/pacman.d/hooks/zz-omacvm-stock-kernel*.hook`), `src/guest/install.sh`
  (`GRUB_TOP_LEVEL`), `src/guest/check.sh`.

## 19. All routes: two VMs in one app both get the swipes and Cmd shortcuts

- **Symptom:** with two OmacVM VMs running in UTM, a Cmd shortcut in the
  full-screen one (Super+Return, Super+W) also reaches the other, and so do
  swipes and scrolling. Found from the code during the UTM end-to-end test,
  while a second UTM VM ran.
- **Cause:** OmacVM Gestures knows which app is in front (UTM, Parallels or
  Fusion), not which of its VMs. It sends keys and touches to every VM
  connected from that app's network (`sendTo(frontNet, …)`); every app has one
  network for all its VMs. On Parallels only the swipes and scrolling are
  affected (Parallels passes Cmd itself).
- **Fix:** `omacvm apply` gives the VM its name (`OMACVM_VM_NAME_B64` in
  `/etc/omacvm/env`), the guest daemon says it in its hello, and the helper
  reads the title of the VM app's front window through Accessibility (on
  every app switch and on its 0.2 s check while a VM app is full screen in
  front). Frames, keys and the capture state go only to the VM whose name is
  in the title; switching VMs sends `S off` to the old one and `S on` to the
  new one. Window titles seen: Parallels the VM's name (windowed and full
  screen), UTM "UTM – NAME", VMware Fusion and OmacVM.app the VM's name
  (windowed; their full screen not checked yet). Tested with two Parallels VMs: Cmd+Return opened a terminal only in
  the VM in front, and only it got the swipe. A VM set up before this (no
  name in its hello) or renamed since its last `omacvm apply` matches no
  title: then every VM of that app gets them, as before; run `omacvm update`.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (`pickTargets`,
  `windowTitle`), `src/gestures/guest/omacvm-gestures` (hello),
  `src/guest/install.sh` (`--vm-name-b64`), `src/cmd/apply.sh`.

## 20. UTM: Cmd+W stops the VM

- **Symptom:** the VM is gone after Cmd+W; the guest journal of that boot
  just ends, without a shutdown.
- **Cause:** when OmacVM Gestures does not take the key (VM not full screen,
  trackpad handed back with ⌃⌥⌘Esc, or a key posted by a script below the
  keyboard, such as System Events' `keystroke`), UTM gets Cmd+W and closes
  the VM window. With UTM's "don't ask before quitting" setting
  (`NoQuitConfirmation`), closing the window stops the VM at once.
- **Fix:** in full screen with the trackpad captured, Cmd+W is Super+W in
  Omarchy (tested: it closes the guest's window, UTM never sees it). To test
  Cmd shortcuts from a script, post them at the HID level
  (`CGEvent.post(tap: .cghidEventTap)` with a `.hidSystemState` source), not
  with System Events.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (event tap at
  `kCGHIDEventTap`).

## 21. UTM, Fusion: no sound at all, no microphone

- **Symptom:** in a UTM or VMware Fusion VM, `aplay -l` says "no soundcards
  found"; Omarchy plays nothing and PipeWire has no input.
- **Cause:** neither app gave the VM a sound card. UTM's scripting has no
  sound property, so the VM it made had `Sound = []`; `vmcli VM Create`
  writes no `sound.*` lines.
- **Fix:** UTM: `Sound = [{Hardware = intel-hda}]` in the VM's config.plist
  (QEMU then gets `intel-hda` + `hda-duplex` on UTM's SPICE audio, input and
  output). UTM starts a VM with the configuration it read at its own start,
  so after the edit UTM is quit first (only when no UTM VM runs), else the VM
  comes up without the card. Fusion: `sound.present`, `sound.virtualDev =
  "hdaudio"`, `sound.fileName = "-1"`, `sound.autodetect` in the .vmx. New VMs
  get it during the build; an older VM when `omacvm apply` starts it from shut
  down. Tested: UTM records the Mac's microphone (RMS about 9, a quiet room),
  Fusion shows "HD-Audio Generic" for playback and capture.
- **Where:** `src/lib/mac.sh` (`utm_add_sound`, `fusion_add_sound`),
  `src/lib/vm.sh` (`vm_boot`), `src/cmd/build.sh`.

## 22. Parallels, Fusion, app: the microphone records nothing, or silence

- **Symptom:** PipeWire lists the input, but a recording is empty: on Fusion
  and OmacVM.app `pw-record` gets no samples at all
  (`/proc/asound/card0/pcm0c/sub0/status`: `hw_ptr 0`); on Parallels the
  samples come but are all zero (`Capture` at 100 % and on). On Fusion the
  whole VM also stops for about four minutes when the recording starts (no
  SSH, `vmware-vmx` at full CPU) until the refusal below is logged; on
  OmacVM.app too (QEMU at full CPU), once per try.
- **Cause:** macOS's microphone permission for the app that records on the
  Mac. Fusion's `vmware-vmx` and OmacVM.app's QEMU are helpers that cannot
  ask for it themselves: their `AudioQueueStart` fails with 268451843.
  vmware.log says `SoundAQStartStream: Failed to start input audio queue,
  error: (no mapping) (268451843)`; OmacVM.app's `logs/qemu.log` says
  `SDL_OpenAudioDevice for recording failed: CoreAudio error
  (AudioQueueStart): 268451843`. Parallels hands the VM silence instead. UTM
  recorded the Mac's microphone on the same Mac because UTM had the
  permission already. Why the app's VM stops: QEMU opens the recording on a
  vCPU thread that holds its global lock (`sample` shows `sdl_open` under
  `intel_hda_set_st_ctl`), and `AudioQueueStart` waits for coreaudiod
  (`_TellServerAboutStreamUsage`) until it gives up.
- **Fix:** Parallels and Fusion: allow Parallels Desktop or VMware Fusion in
  System Settings › Privacy & Security › Microphone (a person's step), then
  restart the VM. OmacVM.app: the app now asks for the microphone when it
  starts a VM, and QEMU records under its grant; the Developer ID build has
  the `audio-input` entitlement for that. Without the permission the app
  starts QEMU without recording (`in.voices=0`, and a line in `qemu.log`), so
  the VM never stops for it; allow it, then restart the VM. Still open: in
  the 2.6.0 test the app was allowed and QEMU's recording still stopped the
  VM for about four minutes and failed, so the app's grant does not seem to
  cover QEMU. `omacvm check` reads the Fusion and app logs for the refusal
  (and says to restart).
- **Where:** `app/app/Sources/OmacVM/Runner.swift`, `app/app/OmacVM.entitlements`,
  `src/cmd/check.sh`.

## 23. app: Chrome hangs in Basemark Web 3.0, the screen flickers

- **Symptom:** in OmacVM.app (2.6.0), Basemark Web 3.0 in Google Chrome
  stops at test 5 of 20, the page flickers and no score comes, even after
  15 minutes. It finishes on the Mac and in Parallels, UTM and Fusion. WebGL
  Aquarium and the desktop keep working.
- **Cause:** the app's virglrenderer turns the guest's shaders (TGSI) into
  GLSL for the Mac's OpenGL 4.1. One of the patches it is built with
  (`virglrenderer-a8-shader-swizzle-texture.patch`, for alpha-only textures)
  reads every `texture()` result into a `vec4`. On an integer texture
  (`usampler2D`) that gives `uintBitsToFloat(vec4)`, which does not exist, so
  Apple's compiler refuses the shader. The VM's `logs/qemu.log` says
  `Shader failed to compile`, `ERROR: 0:273: No matching function for call to
  uintBitsToFloat(vec4)`, then `context 11 failed to dispatch DRAW_VBO` and
  `ctrl 0x106, error 0x1200` for every later command: virglrenderer stops
  that GL context for good, and Chrome's GPU process keeps drawing into a
  dead context. The patch also put the write mask on that `vec4`
  (`vec4 val = texture(...).x`), which does not compile either.
- **Fix:** `app/runtime/patches/virgl-texture-integer-samplers.patch`: the
  temporary has the sampler's own type (`vec4`, `uvec4`, `ivec4`), the write
  mask goes on the assignment only. Each runtime build compiles these
  shaders with the Mac's OpenGL (`app/runtime/Tests/virgl/test-integer-sampler-shader.c`),
  and `app/scripts/gpu-check.sh` runs Aquarium and Basemark in an app VM and
  reads `qemu.log` for refused shaders.
- **Where:** `app/runtime/patches/`, `app/runtime/build-qemu-gpu-runtime.sh`,
  `app/runtime/Tests/virgl/`, `app/scripts/gpu-check.sh`.
