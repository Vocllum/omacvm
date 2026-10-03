# The Mac's battery

On a MacBook, Omarchy's bar shows the Mac's battery as it would on a laptop:
charge, charging or not, time left, and its battery panel (size, cycles,
the charge limit set in macOS). Omarchy warns when it runs low; the VM never
suspends or powers off for it, the Mac decides that.

Feature `battery`: on by default for UTM, VMware Fusion and OmacVM.app on a
Mac with a battery. Parallels gives the VM the Mac's battery itself, so
OmacVM leaves it alone there.

From try-omarchy (github.com/omacom/try-omarchy, MIT; the module
GPL-2.0-only): the kernel module, the agent and the Mac's snapshots.

## How it works

```
Mac                                              VM
IOKit power sources ─┬─ OmacVM Bridge (UTM, Fusion) ── GET /battery, "battery" events ──┐
                     └─ OmacVM.app ── virtio port org.omacvm.battery ───────────────────┤
                                                                                        ▼
                                  omacvm-battery.service (root) ── /sys/devices/platform/omacvm-battery/state
                                                                                        ▼
                                  module omacvm_battery: /sys/class/power_supply/BAT0, ADP0
                                                                                        ▼
                                  UPower ── Omarchy's bar (battery icon, panel, low-battery warning)
```

- The Mac sends a whole snapshot each time (JSON, see `src/bridge/mac/battery.swift`):
  on every change of its power sources (IOKit notifications), and every
  30 seconds from OmacVM.app. Only the VM's request for a fresh one goes the
  other way; nothing in the VM can change the Mac.
- `omacvm-battery` (Python) writes it as one line to the module's `state`
  file (root only): `present=1 status=discharging capacity=57 ac=0
  time_to_empty=8100 …`, or `present=0 ac=1` on a Mac without a battery.
  A line is taken whole or not at all. When the Mac's side goes away, the
  agent marks the battery's state unknown and systemd starts it again.
- The module (`module/`, DKMS `omacvm-battery/1.0.0`) shows BAT0 (a Li-ion
  battery, "Apple Mac Battery") and ADP0 (the charger). BAT0 appears with
  the first snapshot that has a battery.
- `/etc/UPower/UPower.conf.d/90-omacvm-battery.conf`: `CriticalPowerAction=Ignore`
  (UPower takes it only with `AllowRiskyCriticalPowerAction=true`).

## Kernel updates

`guest/install.sh on` installs `dkms` and the headers of the installed kernel
(`linux-aarch64-headers` of the same version; the memory-optimized kernel
brings its own) and builds the module for every kernel that has headers. A
kernel update through `omarchy update` brings new headers with it, and
pacman's DKMS hook builds the module for the new kernel before the reboot.
`omacvm check` lists every kernel and whether it has the module.

## Files in the VM

| What | Where |
|---|---|
| module source | `/usr/src/omacvm-battery-1.0.0/` (DKMS), built into `/usr/lib/modules/<kernel>/updates/dkms/` |
| loaded at boot | `/etc/modules-load.d/omacvm-battery.conf` |
| agent | `/usr/local/bin/omacvm-battery`, `omacvm-battery.service` |
| app port | `/dev/virtio-ports/org.omacvm.battery` (root only, `70-omacvm-battery.rules`) |
| build log | `/var/lib/omacvm/battery-build.log` |

```bash
upower -i /org/freedesktop/UPower/devices/battery_BAT0
cat /sys/devices/platform/omacvm-battery/state
journalctl -u omacvm-battery
omacvm-bridge battery          # UTM, Fusion: what the Bridge sends
```

## Tested

MacBook Pro M4 Max, macOS 15.7.4, Arch Linux ARM's kernel 7.2.8, upower
1.91.4, dkms 3.4.3: a UTM 5 VM (through the Bridge) and an OmacVM.app VM
(virtio port) show the Mac's battery (100 %, on the charger, full) in UPower and in
Omarchy's bar; `omacvm check` passes the battery rows; `omacvm disable
battery` removes module, agent and DKMS entry, `enable` brings them back;
reinstalling the kernel headers makes pacman's DKMS hook rebuild the module.
Not tested yet: a VMware Fusion VM (the same path as UTM), and the Mac on
battery power (discharging, time left, the low-battery warning).
