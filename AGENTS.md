# AGENTS.md: operating manual for coding agents

Read this before changing anything. It describes how the full Omaparallels
setup is built, how the pieces talk to each other, how to verify it, and what
has already been tried and does not work.

Omaparallels = Omarchy (omarchy-mac, Arch Linux ARM) in Parallels Desktop on
an Apple Silicon Mac, made to feel like a native Mac. Sibling project:
[Omanotch](https://github.com/gillesgoetsch/omanotch) (Omarchy's bar beside
the notch; separate repo, works with Parallels or UTM).

## 1. Definition of done

A build is done when all of this holds:

1. `prlctl list -a` shows the VM; it boots to SDDM / the Omarchy desktop from
   the NVMe disk, GRUB default entry = `linux-aarch64-thp` (unless `--no-thp-kernel`).
2. `ssh -i ~/.ssh/omaparallels root@<ip>` works (key only; ufw allows 22 from
   10.211.55.0/24).
3. `systemctl is-active prltoolsd` = active in the guest.
4. Display: `hyprctl monitors` matches the Mac (native pixels, refresh rate,
   arrangement) within a few seconds of a window/full-screen/display change.
5. On the Mac: `lsof -nP -iTCP -sTCP:LISTEN | grep 10.211.55.2` shows
   47830 (Gestures) and 47831 (Bridge); `launchctl list | grep omaparallels`
   shows bridge, gestures, clip-in, lock.
6. In the guest as the desktop user: `omaparallels-bridge state` prints the
   Mac's Wi-Fi with an SSID (Location Services granted), `omaparallels-bridge
   audio` the Mac's devices, and the bar shows `omaparallels.wifi`,
   `omaparallels.audio`, `omaparallels.workspaces` in the slots of the stock
   widgets.
7. Copy in the VM → `pbpaste` on the Mac shows it.

## 2. Environment

| Requirement | Value |
|---|---|
| Host | Apple Silicon, macOS 14+ (verified 15.7.4, MacBook Pro M4 Max) |
| Parallels Desktop | 19+; **Standard is enough** (verified 27.0.2). Only `prlctl list/register/unregister` and `prl_disk_tool` are used; everything else is `config.pvs` (vm/pvs.py). `prlctl start` is tried only as a fallback (Pro/Business) |
| Tools | Xcode Command Line Tools (swiftc, clang), Homebrew `zstd` + `e2fsprogs` (live installer), python3, openssl |
| Network | ~1.4 GB try-omarchy download (live installer) + Arch Linux ARM and Omarchy packages |
| Disk | ~60 GB free for the build (the VM disk is expanding) |

## 3. Repository map

| Path | What |
|---|---|
| `build.sh` | One command, nothing → finished VM (sections 1–5 inside). Flags: `--vm-name --cpus --memory-gb --disk-gb --user --full-name --hostname --no-thp-kernel --autologin --omanotch --channel --yes`; `OMAPARALLELS_PASSWORD` for unattended runs |
| `apply.sh` | Guest side onto a running VM: copies the bridge token and this repo to `/usr/local/share/omaparallels`, runs `guest/install.sh`, sets the Dock icon. Re-run after updating the repo |
| `mac/install.sh`, `mac/uninstall.sh` | Mac side: bridge, gestures, clipboard, lock |
| `guest/install.sh` | Guest side, root, idempotent: system extras + every feature's `guest/install.sh` |
| `vm/live/` | Temporary live installer (from vincenzopalazzo/omarchy-parallels, MIT): try-omarchy → bootable ARM64 Linux with SSH |
| `vm/base-install.sh` | In the live system: GPT + btrfs on NVMe, pacstrap, locale/keyboard/user, GRUB |
| `vm/omarchy-install.sh` | In the new system: omarchy-mac `install.sh --channel rc`, unattended |
| `vm/pvs.py` | `config.pvs` editor (settings, NVMe disk, boot order, shares) |
| `lib/mac.sh` | Mac helpers: `gssh`, `vm_ip` (DHCP lease by MAC), `vm_state`, `vm_start`, `wait_*` |
| `lib/install-plugin.sh`, `lib/omaparallels-plugins` | Omarchy shell plugin install; queues until the shell runs (first login) |
| `lib/sign.sh` | Signs Mac apps with `designated => identifier "<id>"` so TCC grants survive rebuilds |
| `bridge/` | Omaparallels Bridge: `mac/*.swift` (OmaparallelsBridge.app), `guest/` (client, OSD follower, nightlight toggle), `plugins/omaparallels.{wifi,audio}` |
| `gestures/` | Omaparallels Gestures: `mac/omaparallels-gestures.c` (MultitouchSupport + event tap), `guest/omaparallels-gestures` (uinput touchpad) |
| `display/` | `parallels-dynres` + `monitors.lua` |
| `workspaces/` | Per-display workspaces: `monitor_workspaces.lua`, bindings, `plugins/omaparallels.workspaces` |
| `clipboard/` | VM → Mac copy (guest `parallels-clip-out`, Mac `omaparallels-clip-in`) |
| `keyboard/` | `mac-layout.sh` (macOS input source → XKB), guest layout + Cmd+V paste |
| `lock/` | Theme export (guest) → wallpaper + `OmarchyLock.saver` (Mac) |
| `memory/` | zram/sysctl/THP-defrag/MGLRU tuning |
| `kernel/` | `thp-pkgbuild.py` (rewrites ALARM's current linux-aarch64 PKGBUILD), `build-thp-kernel.sh` |
| `icon/` | VM Dock icon from Omarchy's `/usr/share/omarchy/icon.txt` |
| `docs/` | README graphics |

## 4. Architecture

```
Mac (macOS)                                   VM (Arch Linux ARM + Omarchy)
───────────                                   ─────────────────────────────
OmaparallelsBridge.app  10.211.55.2:47831 ◀── omaparallels-bridge (curl, SSE) ← bar widgets,
  CoreWLAN, CoreAudio, CoreBrightness,  HTTP+    omaparallels-bridge-osd → omarchy-osd,
  media-key event tap, keychain         token    omarchy-toggle-nightlight
OmaparallelsGestures.app 10.211.55.2:47830 ◀── omaparallels-gestures (root, uinput touchpad)
omaparallels-clip-in ◀── share "clip"  ◀────── parallels-clip-out (wl-paste --watch)
lock theme-sync      ◀── share "theme" ◀────── omarchy-theme-export (path unit)
VM bundle (.pvm)     ──▶ share "vmlog" (ro) ──▶ parallels-dynres reads parallels.log [DYNRES]
Omanotch.app (separate) 10.211.55.2:47811 ◀─── notchcast
```

- The Mac is **10.211.55.2** on Parallels' shared network (not .1). Guests get
  10.211.55.x by DHCP; leases in `/Library/Preferences/Parallels/parallels_dhcp_leases`.
- Every Mac listener binds 10.211.55.2 only, never 0.0.0.0. The bridge needs
  `Authorization: Bearer <token>` (`~/Library/Application Support/omaparallels-bridge/token`
  → guest `~/.config/omaparallels-bridge/token`, 0600).
- Bridge API, events and permissions: `bridge/README.md`.
- Disk: GPT on NVMe (Parallels expanding disk, online compact): 2 GiB EFI at
  `/boot` + btrfs `@ @home @log` (+ `@factory` and snapper from omarchy-mac),
  `noatime,compress=zstd:1,space_cache=v2,discard=async`. GRUB (omarchy-mac's
  restore tooling expects it), installed normally and `--removable`.
- Kernel: `linux-aarch64-thp` (`/boot/vmlinuz-linux-aarch64-thp`, GRUB default
  via `GRUB_TOP_LEVEL`), stock `linux-aarch64` (`/boot/Image`) as fallback in
  GRUB's advanced menu. Cmdline `loglevel=3 quiet mitigations=off nowatchdog`.

### Parallels settings (vm/pvs.py `omaparallels`)

| config.pvs | Value | Why |
|---|---|---|
| `Hardware/Cpu/Number`, `AutoCountEnabled` | N, 0 | fixed; default suggestion = performance cores (vCPUs cannot be pinned) |
| `Hardware/Memory/RAM`, `RamAutoSizeEnabled` | MB, 0 | default suggestion = half the Mac (see memory lesson) |
| `Hardware/Video/Enable3DAcceleration`, `EnableVSync`, `VideoMemorySize` | 1, 1, 0 | virgl GPU for Hyprland and Chrome |
| `Hardware/Video/EnableHiResDrawing`, `UseHiResInGuest`, `Settings/Runtime/HostRetinaEnabled`, `OsResolutionInFullScreen` | 1 | native Retina pixels |
| `Settings/Runtime/FullScreen/UseAllDisplays` | 1 | external displays in full screen |
| `Settings/Tools/SmoothScrolling/Enabled` | 1 | hi-res wheel events with macOS inertia (0 = ±120 notches only) |
| `SharedFolders/HostSharing`: `vmlog` (the .pvm, ro), `clip` (rw), `theme` (rw); `SharedCloud` 0, `SharedVolumes` 0, `SharedProfile` 0 | | display layout, clipboard, lock theme; no Mac volumes/iCloud in the guest |
| `Hardware/Hdd` InterfaceType 3 | NVMe, expanding, OnlineCompactMode 1 | the system disk |

GUI-only (app-wide, not scriptable): Parallels Desktop > Settings > Shortcuts >
macOS System Shortcuts > **Send macOS system shortcuts: Always** (Cmd+Space etc.).

## 5. Build pipeline (build.sh)

1. Detect: login name, full name, keyboard (`keyboard/mac-layout.sh`),
   timezone, language, cores/RAM/disk suggestion; confirm; password → SHA-512 hash.
2. `vm/live/build-live.sh --skip-boot` → registered VM with the live disk
   (SATA). Unregister, `prl_disk_tool create` the NVMe disk, `pvs.py`
   settings/add-nvme/shares/boot-from live, register, `vm_start`.
3. Over SSH (key injected by the live initramfs): `vm/base-install.sh`
   (fastest mirrors, partitions, pacstrap, base config, GRUB). Poweroff.
4. Unregister, remove the live disk, boot from NVMe, register, start.
5. `vm/omarchy-install.sh` (temporary NOPASSWD + `verifypw=any` sudo, removed
   by trap), Parallels Tools from `prl-tools-lin-arm.iso` (pure userspace).
6. `mac/install.sh`, `apply.sh` (token, repo, `guest/install.sh`, icon),
   optional Omanotch, reboot.

## 6. Standard procedures

- **Build**: `./build.sh` (interactive) or `OMAPARALLELS_PASSWORD=… ./build.sh --yes …`.
- **Update an existing VM**: `git pull && mac/install.sh && ./apply.sh --vm <name>`
  (`--no-thp-kernel` to skip the ~10 min kernel rebuild).
- **SSH**: `ssh -i ~/.ssh/omaparallels root@$(grep -o '10\.211\.55\.[0-9]*' /Library/Preferences/Parallels/parallels_dhcp_leases | tail -1)`.
- **Run as the desktop user over SSH**: `sudo -u <user> env XDG_RUNTIME_DIR=/run/user/1000 bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap; <cmd>'`
  (Omarchy commands need `OMARCHY_PATH`; `hyprctl`/`grim` also need
  `WAYLAND_DISPLAY=wayland-1` and `HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr | head -1)`).
- **Screenshot the guest**: `grim` as above (not `screencapture` on the Mac, which needs Screen Recording).
- **Test the bridge from the guest**: `omaparallels-bridge state|audio|display|events`; from the Mac:
  `curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/omaparallels-bridge/token)" http://10.211.55.2:47831/state`.
- **Permissions**: Location Services (bridge: SSIDs), Accessibility (bridge: media keys; gestures), Input
  Monitoring (gestures). Reset: `tccutil reset Accessibility org.omaparallels.bridge` (and
  `org.omaparallels.gestures`, `ListenEvent`), then `launchctl kickstart -k gui/$(id -u)/org.omaparallels.<app>`.
- **Logs**: `~/Library/Logs/omaparallels-{bridge,gestures,lock}.log`; guest
  `journalctl --user -u omaparallels-bridge-osd`, `journalctl -u omaparallels-gestures`.
- **Uninstall**: `mac/uninstall.sh [--purge]`; delete the VM in Parallels.

## 7. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Bar widgets missing after a fresh build | Omarchy shell was not running at install time | they are queued; `omaparallels-plugins.service` enables them at the first login (`~/.local/state/omaparallels/pending-plugins`) |
| `OMARCHY_PATH is not set` from omarchy commands run as root/sudo | no Omarchy env | `source /usr/share/omarchy/default/bash/env-bootstrap` first |
| SSIDs null, `location_authorized: false` | Location Services not granted to the bridge | System Settings > Privacy & Security > Location Services |
| Media keys still show the macOS popup | Accessibility missing, VM not full screen, or capture switched off in the bridge's menu | grant, check `media keys:` lines in the bridge log |
| Permission prompts after every rebuild | app signed ad-hoc without lib/sign.sh's requirement | always build through the feature's `build.sh` |
| VM resumes a dead state after a hard kill | suspend files | delete `<pvm>/*.mem*` and `vm.lock` before starting |
| Display back at 1024x768 after a theme switch | `monitors.lua` without the saved layout | `display/guest/install.sh` (monitors.lua reads `~/.local/state/parallels-dynres/monitors`) |
| omarchy-mac install stalls | interactive prompt or sudo password | runs with `< /dev/null`, NOPASSWD + `verifypw=any`; log `/var/log/omaparallels-omarchy-install.log` |
| ALARM downloads time out | geo-DNS mirror far away | `vm/base-install.sh` ranks mirrors; edit `/etc/pacman.d/mirrorlist` |
| `register` fails "name already taken" | ghost VM identity | `vm/live/build-live.sh` retries with new UUIDs |

## 8. Hard-won rules (do NOT)

- Do not use try-omarchy as the installed system (pinned demo runtime, not
  updatable). It is only the temporary live installer.
- Do not update with bare `pacman -Syu`: omarchy-mac pins the Hyprland stack to
  Omarchy's ARM repo; use `omarchy update`.
- Do not expect Hyprland to apply Parallels' display pushes: it never does.
  `parallels-dynres` reads `[DYNRES]` lines from `parallels.log` (vmlog share)
  and applies them with `hyprctl eval 'hl.monitor{…}'`. `hyprctl keyword` does
  not work with Omarchy 4's Lua config; runtime monitor rules are lost on
  reload, hence the saved layout. Do not hard-code scales (Omarchy's scale menu
  writes `omarchy_monitor_scale` in `monitors.lua`).
- Omarchy 4's Hyprland config is **Lua** (`hyprland.lua`, `bindings.lua`,
  `input.lua`, `monitors.lua`, `autostart.lua`); `hyprland.conf` is ignored.
- Parallels Tools on Hyprland syncs the clipboard Mac → VM only; its helper
  window "Parallels Shared Clipboard" tiles unless the window rule keeps it out.
- Parallels never returns memory the guest touched until the VM stops (its
  balloon has no free-page reporting; it did not inflate under 40 GB of host
  pressure; zeroed pages are not reclaimed). Keep zram small and memsize capped.
- GRUB on Arch only boots kernels named `/boot/vmlinuz-*` with their initramfs.
- Parallels gives a Linux guest only a mouse: no gestures, no trackpad
  passthrough (a virtual USB device needs DriverKit entitlements). Gestures
  come from MultitouchSupport on the Mac + uinput in the guest.
- The notch area is unreachable in Parallels (window starts below it);
  Accessibility moves are ignored. Omanotch solves it separately.
- `prl_client_app` rewrites the VM's `VM.app` Dock helper icon from the
  `.pvm`'s Finder custom icon when Parallels starts; set the Finder icon.
- Never edit `/usr/share/omarchy` files from here (omarchy-mac updates replace
  them); extend through plugins, `~/.config`, and `/usr/local/bin` wrappers that
  shadow `/usr/bin` (PATH order).
- Only one agent should edit the guest's Hyprland config at a time: a reload
  mid-edit leaves the "config has errors" banner.
- Do not switch the user's macOS Spaces or Mission Control in tests.
- Do not put personal data in this repo (names, paths under a real home,
  SSIDs, mirrors picked for one country, wallpapers).

## 9. Conventions

- Identifiers: Mac bundle IDs and LaunchAgent labels `org.omaparallels.*`;
  Omarchy plugin IDs `omaparallels.*`; guest commands `omaparallels-*`.
- Every installer is idempotent and safe to re-run.
- Ports: 47811 Omanotch, 47830 Gestures, 47831 Bridge.
- One commit per change, message says what the user gets.
- Verify on a real VM before committing behaviour changes (`apply.sh` against
  a test VM; `build.sh --vm-name "Omaparallels Test"` for the full path).
