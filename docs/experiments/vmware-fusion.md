# VMware Fusion as a third route

Status: increments 1, 2, 4 and 5 done (a full `omacvm build --vm-type fusion` passed
`omacvm check` in 24 minutes; the display follows the Mac's mode after a reboot);
3: the Bridge, the media keys and trackpad gestures (Magic Trackpad) in full screen
verified on a Mac.
This file is the plan; the code follows it.

## Why

VMware Fusion Pro is free, so it could be a free route with a real GPU and live resolution
changes, next to Parallels (paid) and UTM (free, one display, fixed mode).

## What stood in the way

Stock Omarchy shows a black screen on Fusion. Fusion's guest GPU driver, `vmwgfx`,
prime-imports client dmabufs as TTM surface handles, not GEM handles. Hyprland closes the
imported handle with `GEM_CLOSE`, gets EINVAL and rejects the buffer; every GPU client,
SDDM's greeter first, dies with `invalid arguments for wl_surface.attach`.

The fix is a one-file Hyprland patch (`src/protocols/LinuxDMABUF.cpp`): when the driver is
`vmwgfx` and `GEM_CLOSE` fails, release the handle with `DRM_VMW_UNREF_SURFACE`. Posted by
Pascal-0x90 in hyprwm/Hyprland discussion #12966. There is no upstream pull request, so
OmacVM carries the patch for Fusion VMs.

## Spike result (Fusion 26.0.1, Apple Silicon, Hyprland 0.56.2, kernel 7.2.8)

| Check | Result |
|---|---|
| ALARM's stock `linux-aarch64` has `vmwgfx` and a NIC driver | yes (`vmwgfx` 2.21.0, `e1000e`); no `vmxnet3`, `vmw_balloon`, `vmw_vmci` |
| The failure reproduces on Fusion on ARM | yes, black screen at SDDM |
| Patched Hyprland | login screen, desktop, bar, terminal and Chromium on `SVGA3D`; no software fallback, no dmabuf errors |
| Live mode change with `hl.monitor{…}` | works (2560x1440) |
| OmacVM's live installer, `base-install.sh`, `omarchy-install.sh` | run unchanged; the live image boots as a SATA disk |

Facts that shape the port:

- The Mac is `.1` on Fusion's NAT network (`vmnet8`); the guest's default gateway is `.2`.
  The subnet is chosen per Fusion install, so no address can be hard-coded.
- DHCP leases: `/var/db/vmware/vmnet-dhcpd-vmnet8.leases`; the MAC is
  `ethernet0.generatedAddress` in the `.vmx`.
- Fusion's NAT DNS proxy drops lookups under load (it failed the yay build): the guest
  gets public resolvers instead.
- `open-vm-tools` is not in ALARM's repos: no clipboard or auto-fit from VMware.
- Tools: `vmcli VM Create`, `vmware-vdiskmanager`, `vmrun start|stop|list`, all inside
  `VMware Fusion.app/Contents/Library`. The `.vmx` is plain `key = "value"` text.
- DMI `sys_vendor` in the guest: `VMware, Inc.`

## Design

A third VM type, `fusion`, next to `parallels` and `utm`.

- **Mac's address.** Guest: the default gateway with the last octet set to 1, kept in
  `OMACVM_HOST` like the other types. Mac: the address of the interface that owns the
  `vmnet8` subnet (from Fusion's `networking` file, `VNET_8_HOSTONLY_SUBNET`). The Bridge
  takes it through `OMACVM_BRIDGE_ADDRS`; Gestures' compiled address list becomes a list
  read at start.
- **Patched Hyprland** (`src/fusion/guest/build-hyprland.sh`, modelled on
  `src/kernel/build-thp-kernel.sh`): builds the tag of the installed `hyprland` package
  with the patch, keeps the stock binary, and does nothing when the installed binary is
  already the patched build of that version. A pacman hook re-runs it after a `hyprland`
  upgrade, so `omarchy update` cannot bring the black screen back. Not a feature switch:
  on Fusion the desktop does not start without it.
- **Display.** Fusion sends its layout only to a guest running VMware Tools: without them
  every Mac display in full screen shows the same guest screen (Fusion's spare windows stay
  unattached, `src screenId=-1` in `vmware.log`). OmacVM builds `open-vm-tools` from Arch's
  recipe for aarch64; its resolutionKMS plugin passes Fusion's `DisplayTopology_Set` to
  vmwgfx, and `omacvm-fusion-displays` applies the suggested positions to Hyprland (which
  ignores them). Tested: three 2560x1440 displays in the macOS arrangement, windowed mode
  following the window, switching between them, a reboot. New VMs get `svga.numDisplays`
  = the Mac's display count and `gui.fullScreenOnAllHostDisplays`.
- **Clipboard.** VMware Tools' agent (`vmware-user`, dndcp plugin; built with GTK 3:
  with gtkmm 4 it does not compile against libsigc++ 3) exchanges an X11 clipboard with
  Fusion when the pointer enters or leaves the VM. On Hyprland's XWayland that fails: Hyprland
  owns the X11 clipboard and refuses X11 clients without an X11 window in focus. The agent
  gets a private Xvfb display instead, and `omacvm-fusion-clipboard` syncs it with Wayland's
  clipboard. `xsel`, not `xclip`: the agent detects a new copy by the selection's TIMESTAMP,
  which xclip answers with the text. Tested both ways by hand, and after a reboot.
- **Full-screen capture** (media keys, gestures, pointer): add Fusion's process name next
  to `prl_client_app` and `UTM`.

## Increments

Each one ends with `omacvm check` passing on a real Fusion VM.

1. **An existing Fusion VM is a known type.** `vms_list`, `vm_type`, `vm_find_ip`,
   `vm_boot`, start/stop/state (`src/lib/vm.sh`, `src/lib/mac.sh`); the guest detects
   `VMware*` and finds the Mac (`src/guest/install.sh`); `omacvm vms`, `omacvm apply --vm`
   and `omacvm check --vm` accept `fusion`. Every two-way `parallels`/`utm` branch becomes
   explicit, so a third type never falls into another one's branch.
2. **Patched Hyprland** as above, with its check.
3. **Mac side**: Bridge and Gestures listen on Fusion's network; full-screen detection.
4. **`omacvm build --vm-type fusion`**: `src/vm/fusion.sh` (create, `.vmx` settings, live
   disk on SATA, drop it), public DNS in the guest, resources, prerequisite screen.
5. **Display and docs**: display mode at install, README and AGENTS.md tables.

Out of scope for now: clipboard, more than one display, Omanotch on Fusion (separate repo).

## Not verified yet

- A long session, external displays in full screen, scale 2.
- Whether the Mac's helpers get trackpad and media keys while Fusion is full screen.
