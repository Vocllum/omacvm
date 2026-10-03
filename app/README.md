# OmacVM.app

Omarchy in a VM on an Apple Silicon Mac, in one app. No Parallels, UTM or
VMware Fusion: the app brings its own QEMU (Apple's Hypervisor framework,
GPU through VirGL).

Part of [OmacVM](../README.md): this folder is the app, `../src` is OmacVM's
VM side the app carries. Get the app with `omacvm build --vm-type app`, or
as `OmacVM-<version>.zip` from OmacVM's
[releases](https://github.com/gillesgoetsch/omacvm/releases).

## Build

Needs macOS 15 and Xcode's Command Line Tools.

```sh
git clone https://github.com/gillesgoetsch/omacvm && cd omacvm/app
scripts/build-app.sh          # dist/OmacVM.app
open dist/OmacVM.app
```

The first build compiles QEMU (about 70 seconds). The app takes `../src` as
committed: the build stops when `src/` has uncommitted changes.

## Release

```sh
scripts/build-app.sh --release      # stops unless the whole repo is committed
scripts/package-release.sh          # dist/OmacVM-<version>.zip and .sha256
```

The version is OmacVM's (`../src/VERSION`). Upload both files to the GitHub
release `v<version>`: `omacvm build --vm-type app` and `omacvm update`
download them from there.

## Status

Works: setup, VM build (about 8 minutes plus a 1.4 GB download the first
time), window that Omarchy follows (native resolution, 120 Hz), full screen
beside the notch (option), clipboard both ways, sound, WebGL in Chromium,
Chrome, Brave and Firefox, clean shutdown on Quit, pause on Mac sleep,
install under a chosen name, the Mac's battery in Omarchy's bar, ⌘ keys as Super in full screen (through OmacVM
Gestures, which the build installs on the Mac with the other helpers).

Waiting: external displays. Not confirmed on this route yet: the Bridge's
features (Wi-Fi, Bluetooth, media keys) and trackpad gestures.

Needs a person: the permissions OmacVM's Mac helpers ask for; the app needs no
Accessibility of its own.

## What the app does

1. Asks for a VM name, your user and password, resources and where the disk goes.
2. Builds the VM (20-60 minutes): try-omarchy's release boots as a temporary
   live system, OmacVM's installers put Arch Linux ARM (btrfs, GRUB) and
   Omarchy (omarchy-mac) on the disk, then OmacVM's VM side.
3. Starts it: QEMU shows Omarchy in a window that follows its size. Quit
   shuts the VM down cleanly; the Mac's sleep pauses it.

The VM is a normal install: `omarchy update` and snapshots work.

## Layout

| Path | What |
|---|---|
| `runtime/` | QEMU build, from try-omarchy, with OmacVM's patches |
| `app/` | the launcher (Swift) |
| `scripts/create-vm.sh` | builds a VM, headless |
| `scripts/build-app.sh` | builds the app |
| `scripts/package-release.sh` | zips the built app for a release |
| `../src` | OmacVM: the installers and the VM side, `app` route |

Licences: `THIRD_PARTY_NOTICES.md`. QEMU is GPL-2.0: its build scripts and
every patch the app's QEMU is built with are in `runtime/` of this public
repo, which is the source offer for the QEMU in the app.
