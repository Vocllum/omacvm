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
| 2 | Fusion | [Chrome draws everything in software](#2-fusion-chrome-draws-everything-in-software) |
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

## 2. Fusion: Chrome draws everything in software

- **Symptom:** Chrome and Chromium are slow on Fusion, WebGL is off, and
  `chrome://gpu` says software rendering.
- **Cause:** Chromium's GPU blocklist has an entry for VMware's GPU on Linux
  (`software_rendering_list`, entry 176, "VMware is buggy on Linux"). The GPU
  works fine with the vmwgfx fix above.
- **Fix:** OmacVM adds `--ignore-gpu-blocklist` to `~/.config/chromium-flags.conf`,
  and to `~/.config/chrome-flags.conf` when that file exists. Chrome must be
  fully restarted to pick it up: closing the window is not enough, quit every
  Chrome process.
- **Note:** WebGPU then shows "Hardware accelerated", but Fusion gives Linux
  no Vulkan, so there is no real WebGPU or GPU compute behind it.
- **Where:** `src/fusion/guest/install.sh` (the loop over the two flag files).
  If you install Google Chrome after OmacVM and `chrome-flags.conf` did not exist
  yet, add the line yourself or run `omacvm apply` again.

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
  branch `fusion` (`notchcast`). Not in this repo.

## 5. Fusion: Omanotch cannot find the Mac

- **Symptom:** Omanotch's strip stays empty on a Fusion VM; `notchcast` cannot
  connect.
- **Cause:** `notchcast` looked for the Mac at the default gateway. On Fusion's
  NAT network the gateway is `.2` (Fusion's NAT), and the Mac is `.1`.
- **Fix:** OmacVM passes the Mac's address to `notchcast` as `NOTCHBAR_HOST`,
  on every route. `notchcast` also knows Fusion now (Omanotch's `fusion` branch).
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
