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
- Quit, the window's close button, logging out and restarting the Mac shut
  Omarchy down cleanly first. The Mac's sleep pauses the VM; after waking,
  the VM's clock is set to the Mac's.
- Full screen in its own Space, below the notch, like Parallels; Omanotch puts
  Omarchy's bar into the strip beside the notch, as on the other routes.
- ⌘ shortcuts (⌘Space too) go to Omarchy as Super in full screen, through
  OmacVM Gestures, as on UTM: the app needs no Accessibility of its own.
- Optional notch-strip mode (a switch in the app): the window covers the
  strip itself and Omarchy's bar moves there, but that full screen has no
  Space of its own (macOS 15 keeps full-screen Spaces below the notch).
- Install under a name: OmacVM, Omarchy or your own; it shows in the Dock.
- Clipboard both ways, text and images (try-omarchy's agent, over a virtio
  port, not the network).
- Sound through the Mac (QEMU's HDA card; PipeWire in the VM).

## What needs a person

- The password for Omarchy, typed in the setup.
- The permissions OmacVM's Mac helpers ask for (as on the other routes).

## Not done yet

- Bridge and Gestures: the Mac side listens on 127.0.0.1 too (branch
  app-route), not installed yet.
- One display at a time. The window can go to an external display and be full
  screen there, but Omarchy gets one screen, not one per Mac display.
- The app needs Xcode's Command Line Tools (it builds OmacVM's Mac helpers);
  it checks for them before a build and offers to install them.

## How it talks to the Mac

QEMU's user network: the Mac is `10.0.2.2` for the VM, and the Mac reaches
the VM's SSH on `127.0.0.1:<port>`.

- The VM reaches only three of the Mac's local ports through `10.0.2.2`:
  47811 (Omanotch), 47830 (Gestures) and 47831 (Bridge). Everything else the Mac runs on
  127.0.0.1 (dev servers, databases) is refused, like on the other routes.
  The app's QEMU carries a libslirp patch for that
  (`OMACVM_SLIRP_HOST_PORTS`).
- Gestures and Bridge also listen on the Mac's 127.0.0.1, where any Mac
  program could connect, or listen in their place while they are not
  running. So the VM gives the Bridge's token to neither before it has proved
  it knows it (HMAC-SHA256 of a fresh nonce and the Mac address it answered
  on, which must be 127.0.0.1: a proof passed on from the helper on
  10.211.55.2 fails): Gestures then wants the VM's own proof (the token
  never goes over the wire, and the VM acts on no key or gesture before the
  proof); the Bridge gets the token on each request after `GET /proof`.
  The app makes the token when the Bridge has not, and puts it into the VM.
- Not covered yet, so the token is not safe from Mac programs on this route:
  VMs set up before the proof still send the token straight away (to
  whatever listens) until their next `omacvm apply`; and with Omanotch on,
  its notchcast sends the token itself (`auth <token>`) to 47811, so any
  program on the Mac's 127.0.0.1:47811 gets it. Omanotch should move to the
  same proof.
- Omanotch (47811) needs a version that serves 127.0.0.1; `omacvm apply` and
  `omacvm check` say when the one on the Mac is older.
- `omacvm apply` writes `guest-pointer` into the VM's folder once the VM
  draws Omarchy's own pointer; VMs set up before that still need the Mac's
  pointer (QEMU's `show-cursor=on`).

## Why one display

QEMU's macOS window (its "cocoa" display) shows one guest screen at a time:
it has a single window and a single display listener, and its View menu
switches between screens. Parallels and VMware Fusion open a window per
display; QEMU on the Mac does not. Two ways to get there, neither done:

- Teach the cocoa display one window per guest screen. Most of its code
  assumes one window (global view, one GL context, mouse coordinates for one
  screen), so this is a larger patch, plus routing the pointer to the right
  screen in Hyprland. Several days.
- QEMU's SDL display opens a window per screen, but it lacks everything the
  cocoa patches add here: the window size the VM follows, the notch strip,
  ⌘ as Super, pinch and smooth scrolling.
