# OmacVM.app (draft)

Omarchy in its own Mac app, without Parallels, UTM or VMware Fusion. The app
brings QEMU (built from try-omarchy's patched source) and runs it with Apple's
Hypervisor framework. The GPU goes through VirGL on the Mac's OpenGL.

Status: work in progress, not released. Source: `~/omacvm-app` (local).

## What works

- Setup in the app: VM name, user, password, resources, disk size, where the
  disk goes (any APFS or Mac OS Extended drive).
- The build: the same steps as the other routes (try-omarchy as a temporary
  live system, Arch Linux ARM on btrfs with GRUB, Omarchy from omarchy-mac,
  OmacVM's VM side). About 8 minutes on an M4 Max, plus a 1.4 GB download the
  first time.
- A normal install: boots through UEFI and GRUB, so `omarchy update` and
  snapshots work.
- The window: Omarchy follows its size and the display's refresh rate
  (120 Hz on a MacBook Pro).
- GPU in browsers: WebGL 1 and 2 on the hardware in Chromium, Google Chrome,
  Brave and Firefox (`virgl (Apple M4 Max)`), no flags.
- Quit or the window's close button shuts Omarchy down cleanly. The Mac's
  sleep pauses the VM.
- Install under a name: OmacVM, Omarchy or your own; it shows in the Dock.
- Clipboard both ways, text and images (try-omarchy's agent, over a virtio
  port, not the network).
- Sound through the Mac (QEMU's HDA card; PipeWire in the VM).

## What needs a person

- Accessibility for the app (System Settings > Privacy & Security), so ⌘
  shortcuts go to Omarchy as Super.
- The password for Omarchy, typed in the setup.

## Not done yet

- Bridge and Gestures: the Mac side listens on 127.0.0.1 too (branch
  app-route), not installed yet.
- Full screen beside the notch: Omarchy's bar part works (it takes the strip's
  height); the Mac part waits for a test (the Mac was locked).
- One display only; no external displays.
- The app needs Xcode's Command Line Tools on the Mac that builds it.

## How it talks to the Mac

QEMU's user network: the Mac is `10.0.2.2` for the VM, and the Mac reaches
the VM's SSH on `127.0.0.1:<port>`.

- The VM reaches only two of the Mac's local ports through `10.0.2.2`:
  47830 (Gestures) and 47831 (Bridge). Everything else the Mac runs on
  127.0.0.1 (dev servers, databases) is refused, like on the other routes.
  The app's QEMU carries a libslirp patch for that
  (`OMACVM_SLIRP_HOST_PORTS`).
- Gestures and Bridge also listen on the Mac's 127.0.0.1, where any Mac
  program could connect. So both want the Bridge's token there: the Bridge on
  every request (as before), Gestures in its hello. The app makes the token
  when the Bridge has not, and puts it into the VM.
