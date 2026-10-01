# AGENTS.md: operating manual for coding agents

Read this before changing anything. It describes how the full OmacVM setup is
built on both routes (Parallels Desktop, UTM), how the pieces talk to each
other, how to verify it, and what has already been tried and does not work.

OmacVM = Omarchy (omarchy-mac, Arch Linux ARM) in a VM on an Apple Silicon Mac,
made to feel native. Sibling project: [Omanotch](https://github.com/gillesgoetsch/omanotch)
(Omarchy's bar beside the notch; separate repo, Parallels and UTM).

## 1. Definition of done

A build is done when all of this holds:

1. The VM is registered (`prlctl list -a` or `utmctl list`) and boots to SDDM /
   the Omarchy desktop from its NVMe disk; GRUB default entry =
   `linux-aarch64-thp` (unless `--no-thp-kernel`).
2. `ssh -i ~/.ssh/omacvm root@<ip>` works (key only; ufw allows 22 from the VM
   network's /24).
3. `/etc/omacvm/env` names the VM type and the Mac's address.
4. Display: Parallels: `hyprctl monitors` matches the Mac (native pixels,
   refresh rate, arrangement) within seconds of a change. UTM: Virtual-1 runs
   the mode from `display/mac-display.swift` (e.g. 3456x2160@120).
5. On the Mac: `lsof -nP -iTCP -sTCP:LISTEN` shows 47830 (Gestures) and 47831
   (Bridge) on 10.211.55.2 and/or 192.168.64.1; `launchctl list | grep omacvm`
   shows bridge, gestures, clip-in.
6. In the guest as the desktop user: `omacvm-bridge state` prints the Mac's
   Wi-Fi with an SSID (Location Services granted), `omacvm-bridge audio` the
   Mac's devices; the bar shows `omacvm.wifi`, `omacvm.audio`,
   `omacvm.workspaces` in the slots of the stock widgets.
7. Changing Omarchy's background sets the Mac's wallpaper (bridge log
   `/wallpaper from …`).

## 2. Environment

| Requirement | Value |
|---|---|
| Host | Apple Silicon, macOS 14+ (verified 15.7.4, MacBook Pro M4 Max) |
| Parallels route | Parallels Desktop 19+; **Standard is enough** (verified 27.0.2). Only `prlctl list/register/unregister` and `prl_disk_tool`; everything else is `config.pvs` (vm/pvs.py); `prlctl start` only as a fallback |
| UTM route | UTM 5 (verified 5.0.6, QEMU 10.0.12). VM creation through UTM's AppleScript dictionary (`/Applications/UTM.app/Contents/Resources/UTM.sdef`), `utmctl` for start/stop/status/ip-address |
| Tools | Xcode Command Line Tools (swiftc, clang, swift), Homebrew `zstd` + `e2fsprogs` (live installer), python3, openssl |
| Network | ~1.4 GB try-omarchy download (live installer) + Arch Linux ARM and Omarchy packages |
| Disk | ~60 GB free for the build (VM disks are expanding) |

## 3. Repository map

| Path | What |
|---|---|
| `build.sh` | Nothing → finished VM. `--vm-type parallels\|utm` (default Parallels if installed) `--vm-name --cpus --memory-gb --disk-gb --user --full-name --hostname --no-thp-kernel --autologin --omanotch --channel --yes`; `OMACVM_PASSWORD` for unattended runs |
| `check.sh` + `guest/check.sh` | Read-only feature check, Mac side then guest side over SSH (`bash -s` of `guest/check.sh`, so it works on VMs with an older copy). One line per feature, exit 1 on any FAIL. Add a line here for every new feature |
| `apply.sh` | Guest side onto a running VM (either type, found by name): bridge token + this repo to `/usr/local/share/omacvm`, `guest/install.sh`, Dock icon (Parallels). Re-run after updating the repo |
| `mac/install.sh`, `mac/uninstall.sh` | Mac side: bridge, gestures, clipboard helper. `mac/parallels-shortcuts.sh`: empty Parallels' Linux keyboard profile (opt-in, app-wide) |
| `guest/install.sh` | Guest side, root, idempotent. Detects the VM type (DMI vendor Parallels/QEMU), writes `/etc/omacvm/env`, runs the shared features and the per-type ones |
| `vm/live/` | Temporary live installer (from vincenzopalazzo/omarchy-parallels, MIT): try-omarchy → bootable ARM64 Linux with SSH; a Parallels VM, or `--raw-image` for UTM |
| `vm/base-install.sh` | In the live system: GPT + btrfs on the NVMe disk, pacstrap, locale/keyboard/user, GRUB |
| `vm/omarchy-install.sh` | In the new system: omarchy-mac `install.sh --channel rc`, unattended; SSH rule for the Mac's network |
| `vm/pvs.py` | Parallels `config.pvs` editor (settings, NVMe disk, boot order, shares) |
| `vm/utm.sh` | UTM: create the VM (AppleScript `make new virtual machine`), drop the live disk, app-wide speed settings |
| `lib/mac.sh` | Mac helpers: `gssh`, Parallels (`vm_ip` by DHCP lease, `vm_state`, `vm_start`) and UTM (`vm_type`, `utm_ip`, `utm_state`, `utm_start`, `utm_wait_stopped`) |
| `guest/omacvm-omanotch.service` | `build.sh --omanotch`: one-shot user unit that runs Omanotch's `guest/install.sh` in the first desktop session (it needs Hyprland running), skipped once `~/.local/bin/notchcast` exists |
| `lib/install-plugin.sh`, `lib/omacvm-plugins` | Omarchy shell plugin install; queues until the shell runs (first login); restarts the shell once when a plugin's files changed |
| `lib/sign.sh` | Signs Mac apps with `designated => identifier "<id>"`, so TCC grants survive rebuilds |
| `bridge/` | OmacVM Bridge: `mac/*.swift` (OmacVMBridge.app), `guest/` (client, OSD follower, nightlight and Wi-Fi QR command replacements), `plugins/omacvm.{wifi,audio,wifiqr}` |
| `gestures/` | OmacVM Gestures: `mac/omacvm-gestures.c` (MultitouchSupport + event tap), `guest/omacvm-gestures` (uinput touchpad) |
| `display/` | Parallels: `parallels-dynres` + `monitors.lua`. `mac-display.swift`: the built-in display below the notch, for UTM |
| `utm/` | UTM guest specifics: guest tools, virtio-gpu environment, fixed display mode |
| `workspaces/` | Per-display workspaces: `monitor_workspaces.lua`, bindings, `plugins/omacvm.workspaces` |
| `clipboard/` | Parallels only: VM → Mac copy (guest `parallels-clip-out`, Mac `omacvm-clip-in`) |
| `wallpaper/` | Guest `omacvm-wallpaper` (path unit) → `POST /wallpaper` on the bridge |
| `keyboard/` | `mac-layout.sh` (macOS input source → XKB), guest layout + Cmd+V paste |
| `memory/`, `kernel/` | zram/sysctl/THP-defrag/MGLRU; THP kernel from ALARM's PKGBUILD |
| `icon/` | `omacvm.svg` is the one icon (⌘ loops around Omarchy's mark): `make-icns.sh` renders it with AppKit (`render.swift`) + `iconutil` into both apps' `Contents/Resources/OmacVM.icns`, the Parallels VM's Dock icon (`set-vm-icon.sh` → Finder custom icon of the .pvm) and UTM's library icon (`vm/utm.sh` `utm_set_icon`: `Data/omacvm.png` + `Information.Icon`/`IconCustom` in config.plist, VM stopped; UTM's scripting only takes built-in icon names) |
| `docs/` | README graphics (hand-written SVG + SMIL) |

## 4. Architecture

```
Mac (macOS)                                         VM (Arch Linux ARM + Omarchy)
───────────                                         ─────────────────────────────
OmacVMBridge.app   :47831 on 10.211.55.2 ◀── HTTP ── omacvm-bridge (curl, SSE) ← bar widgets,
  CoreWLAN, CoreAudio, CoreBrightness,  and 192.168.64.1   omacvm-bridge-osd → omarchy-osd,
  media-key event tap, keychain, wallpaper          omarchy-toggle-nightlight, omarchy-network-qr,
                                                    omacvm-wallpaper (POST /wallpaper)
OmacVMGestures.app :47830 on both       ◀── TCP ─── omacvm-gestures (root, uinput touchpad)
Parallels only:
omacvm-clip-in     ◀── share "clip"  ◀──────────── parallels-clip-out (wl-paste --watch)
VM bundle (.pvm)   ──▶ share "vmlog" (ro) ───────▶ parallels-dynres reads parallels.log [DYNRES]
Omanotch.app (separate) :47811          ◀────────── notchcast
```

- The Mac is **10.211.55.2** on Parallels' shared network (not .1) and the
  default gateway (**192.168.64.1**) on UTM's shared network. The guest's
  `/etc/omacvm/env` holds `OMACVM_VM_TYPE` and `OMACVM_HOST`; the client, the
  gestures daemon (EnvironmentFile) and the widgets use it.
- Mac listeners bind those addresses only, never 0.0.0.0; one listener per
  address, re-bound when the bridge interface comes and goes. The bridge needs
  `Authorization: Bearer <token>` (`~/Library/Application Support/omacvm-bridge/token`
  → guest `~/.config/omacvm-bridge/token`, 0600). API: `bridge/README.md`.
- Full-screen capture (media keys, gestures): frontmost app `prl_client_app`
  (Parallels) or `UTM`, and its window covers a display (the strip beside the
  notch excepted).
- Disk: GPT on NVMe: 2 GiB EFI at `/boot` + btrfs `@ @home @log` (+ `@factory`
  and snapper from omarchy-mac), `noatime,compress=zstd:1,space_cache=v2,discard=async`.
  GRUB (omarchy-mac's restore tooling expects it), normal and `--removable`.
- Kernel: `linux-aarch64-thp` (`/boot/vmlinuz-linux-aarch64-thp`, GRUB default
  via `GRUB_TOP_LEVEL`), stock `linux-aarch64` as fallback. Cmdline
  `loglevel=3 quiet mitigations=off nowatchdog`.

### Parallels settings (vm/pvs.py `omacvm`)

| config.pvs | Value | Why |
|---|---|---|
| `Hardware/Cpu/Number`, `AutoCountEnabled` | N, 0 | default suggestion = performance cores (vCPUs cannot be pinned) |
| `Hardware/Memory/RAM`, `RamAutoSizeEnabled` | MB, 0 | default suggestion = half the Mac |
| `Hardware/Video/Enable3DAcceleration`, `EnableVSync`, `VideoMemorySize` | 1, 1, 0 | virgl GPU for Hyprland and Chrome |
| `EnableHiResDrawing`, `UseHiResInGuest`, `Settings/Runtime/HostRetinaEnabled`, `OsResolutionInFullScreen` | 1 | native Retina pixels |
| `Settings/Runtime/FullScreen/UseAllDisplays` | 1 | external displays in full screen |
| `Settings/Tools/SmoothScrolling/Enabled` | 1 | hi-res wheel events with inertia (0 = ±120 notches only) |
| HostSharing `vmlog` (the .pvm, ro), `clip` (rw); `SharedCloud` 0, `SharedVolumes` 0, `SharedProfile` 0 | | display layout, clipboard; no Mac volumes/iCloud in the guest |
| `Hardware/Hdd` InterfaceType 3 | NVMe, expanding, OnlineCompactMode 1 | the system disk |

GUI-only (app-wide): Shortcuts › macOS System Shortcuts › **Send macOS system
shortcuts: Always**; the Linux keyboard profile's Cmd→Ctrl mappings
(`mac/parallels-shortcuts.sh` empties it: `~/Library/Preferences/Parallels/Linux.dat`,
a Qt data stream, Parallels must be quit).
"Send macOS system shortcuts: Always" has no CLI, plist key or config.pvs
setting; with Always, Parallels writes `sendtovmkeys.dat` (count + one 9-byte
entry per macOS shortcut, flag 1). `lib/mac.sh` `parallels_sends_shortcuts`
reads that as a best guess and `parallels_shortcuts_alert` reminds the user
(build.sh, apply.sh); never write the file.

### UTM settings (vm/utm.sh)

| Setting | Value | Why |
|---|---|---|
| backend, architecture, `hypervisor`, `uefi` | qemu, aarch64, true, true | HVF, EDK2 |
| display | `virtio-gpu-gl-pci`, native resolution, dynamic resolution | virgl; the guest pins its mode |
| network | `virtio-net-pci`, shared | Mac = gateway 192.168.64.1 |
| drives | live installer VirtIO (removed after the base install), system NVMe | base-install looks for NVMe |
| app-wide `QEMUVulkanDriver` = 1, `NSAppSleepDisabled` | | Vulkan on makes UTM pass a 4K stage-2 granule (2x slower memory work); App Nap off |
| guest `/etc/environment.d/90-omacvm-utm.conf` | `WLR_NO_HARDWARE_CURSORS=1 AQ_NO_MODIFIERS=1 WLR_RENDERER_ALLOW_SOFTWARE=1` | hardware cursors and DRM modifiers misbehave on virtio-gpu |
| guest user unit `omacvm-vdagent.service` (stock `spice-vdagent.service` masked globally) | reports the largest Hyprland monitor to spice-vdagentd, clipboard text via wl-copy/wl-paste | the stock agent is X11: on XWayland it sees Omanotch's notch strip beside the screen, reports 2× the width and vdagentd's pointer tablet then only reaches the left half |

## 5. Build pipeline (build.sh)

1. Detect keyboard, timezone, language, cores/RAM/disk; ask user name, full
   name, password (SHA-512 hash) up front; confirm.
2. Live installer: Parallels: `build-live.sh --skip-boot` → registered VM;
   unregister, NVMe disk via `prl_disk_tool`, `pvs.py` settings/shares/boot,
   register, start. UTM: `build-live.sh --raw-image`, `utm_create`, start.
3. Over SSH (key injected by the live initramfs): `vm/base-install.sh`. Poweroff.
4. Drop the live disk, boot from NVMe (pvs.py / `utm_drop_live`).
5. `vm/omarchy-install.sh` (temporary NOPASSWD + `verifypw=any` sudo, removed by
   trap; SSH firewall rule kept even if ufw cannot apply it live). Parallels Tools
   on Parallels.
6. `mac/install.sh`, `apply.sh` (token, repo, `guest/install.sh`, icon),
   optional Omanotch, reboot.

## 6. Standard procedures

- **Build**: `./build.sh [--vm-type utm]` or unattended with `OMACVM_PASSWORD=… ./build.sh --yes …`.
- **Update an existing VM**: `git pull && mac/install.sh && ./apply.sh --vm <name>`.
- **SSH**: `ssh -i ~/.ssh/omacvm root@<ip>` (Parallels: DHCP lease file
  `/Library/Preferences/Parallels/parallels_dhcp_leases`; UTM: `utmctl ip-address <name>`
  or `/var/db/dhcpd_leases`).
- **As the desktop user over SSH**: `sudo -u <user> env XDG_RUNTIME_DIR=/run/user/1000 bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap; <cmd>'`
  (`hyprctl`/`grim` also need `WAYLAND_DISPLAY=wayland-1` and `HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr | head -1)`).
- **Screenshot the guest**: `grim -o Virtual-1` as above.
- **Bridge from the guest**: `omacvm-bridge state|audio|display|events`; from the Mac:
  `curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/omacvm-bridge/token)" http://10.211.55.2:47831/state`.
- **Permissions**: Location Services (bridge), Accessibility (bridge, gestures), Input Monitoring
  (gestures). Reset: `tccutil reset Accessibility org.omacvm.bridge` (and `org.omacvm.gestures`,
  `ListenEvent`), then `launchctl kickstart -k gui/$(id -u)/org.omacvm.<app>`.
- **Logs**: `~/Library/Logs/omacvm-{bridge,gestures}.log`; guest
  `journalctl --user -u omacvm-bridge-osd`, `journalctl -u omacvm-gestures`,
  Omarchy shell `/run/user/1000/quickshell/by-id/*/log.log`.
- **Uninstall**: `mac/uninstall.sh [--purge]`; delete the VM in Parallels/UTM.

## 7. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `check.sh`: Omanotch not connected, Mac log says "another guest is connected" | Omanotch serves one VM at a time | close or stop `notchcast` in the other VM |
| Bar widgets missing after a fresh build | the Omarchy shell was not running at install time | queued; `omacvm-plugins.service` enables them at the first login |
| `OMARCHY_PATH is not set` from omarchy commands run as root/sudo | no Omarchy env | `source /usr/share/omarchy/default/bash/env-bootstrap` first |
| A command replacement in `/usr/local/bin` is ignored by the bar | the Omarchy shell runs with `/usr/share/omarchy/bin` (symlinks to /usr/bin) first on PATH; Hyprland does not | call `/usr/local/bin/...` by full path from QML (see `omacvm.wifiqr`) |
| `Target not found` / "handler will not be used" for a widget's IPC | a clone kept the stock widget's IPC target | give clones their own target (`omacvm.wifi`) |
| Updated widget does not change | a running shell keeps loaded plugins | `lib/install-plugin.sh` flags changes; `guest/install.sh` runs `omarchy-restart-shell` |
| Disabling an old clone brings the stock widget back next to the new one | `clonedFrom` hand-back | rename ids in `shell.json` instead, or disable the stock widget |
| SSIDs null, `location_authorized: false` | Location Services not granted (new bundle id or reset) | Privacy & Security › Location Services |
| Media keys still show the macOS popup | Accessibility missing, VM not full screen, or capture switched off in the bridge menu | `media keys:` lines in the bridge log |
| Build stops right after the Omarchy install | Omarchy enables ufw; new SSH connections from the Mac are refused | `vm/omarchy-install.sh` adds the rule while its own session is open |
| `ERROR: problem running` from ufw | rule stored but not applicable live right after the install | ignored on purpose; verified with `ufw show added` |
| UTM desktop blank after a resolution change | virgl under UTM cannot switch modes live | fixed mode in `monitors.lua`, reboot to change it |
| UTM VM very slow | UTM started with `open -g` (background priority) or Vulkan driver on | start UTM normally; `QEMUVulkanDriver` 1 |
| VM resumes a dead state after a hard kill (Parallels) | suspend files | delete `<pvm>/*.mem*` and `vm.lock` |
| ALARM downloads time out | geo-DNS mirror far away | `vm/base-install.sh` ranks mirrors |

## 8. Hard-won rules (do NOT)

- Do not use try-omarchy as the installed system (pinned demo runtime). It is
  only the temporary live installer.
- Do not update with bare `pacman -Syu`: omarchy-mac pins the Hyprland stack to
  Omarchy's ARM repo; use `omarchy update`.
- Do not expect Hyprland to apply Parallels' display pushes: `parallels-dynres`
  reads `[DYNRES]` lines from `parallels.log` and applies them with
  `hyprctl eval 'hl.monitor{…}'`; runtime rules are lost on reload, hence the
  saved layout. Do not hard-code scales (Omarchy's scale menu writes
  `omarchy_monitor_scale`). On UTM, do not change modes live at all.
- Omarchy 4's Hyprland config is **Lua**; `hyprland.conf` is ignored.
- Parallels Tools syncs the clipboard Mac → VM only under Hyprland; its helper
  window "Parallels Shared Clipboard" tiles unless the window rule keeps it out.
- The VM never returns touched memory to the Mac while it runs (Parallels'
  balloon has no free-page reporting). Keep zram small and memory capped.
- GRUB on Arch only boots kernels named `/boot/vmlinuz-*` with their initramfs.
- A Linux guest gets no trackpad gestures from Parallels or UTM; they come from
  MultitouchSupport on the Mac + uinput in the guest.
- UTM: only one `virtio-gpu-gl` device is allowed, so no second accelerated
  display; QEMU's user-space interrupt controller makes cross-CPU wake-ups
  ~2x slower than Parallels (Speedometer gap); a 4K stage-2 granule (Vulkan
  driver on) halves memory-heavy throughput.
- The Mac's lock screen cannot be themed: only the wallpaper (shown behind it).
  An Omarchy-styled password field on the Mac would be fake.
- Never edit `/usr/share/omarchy` (updates replace it); extend through plugins,
  `~/.config`, and `/usr/local/bin` replacements (remember the shell's PATH).
- Only one agent should edit the guest's Hyprland config at a time.
- Do not switch the user's macOS Spaces or Mission Control in tests.
- Do not put personal data in this repo.

## 9. Conventions

- Identifiers: bundle IDs and LaunchAgent labels `org.omacvm.*`; Omarchy plugin
  IDs `omacvm.*`; guest commands `omacvm-*`.
- Every installer is idempotent and safe to re-run.
- Ports: 47811 Omanotch, 47830 Gestures, 47831 Bridge.
- One commit per change, message says what the user gets.
- Verify on real VMs before committing behaviour changes: `apply.sh` against a
  test VM, `build.sh --vm-name "OmacVM Test"` (and `--vm-type utm`) for the full path,
  then `./check.sh --vm <name>` must pass.
