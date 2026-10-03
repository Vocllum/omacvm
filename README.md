# OmacVM.app

Omarchy in a VM on an Apple Silicon Mac, in one app. No Parallels, UTM or
VMware Fusion: the app brings its own QEMU (Apple's Hypervisor framework,
GPU through VirGL).

Work in progress, not released.

## Build

Needs macOS 15 and Xcode's Command Line Tools.

```sh
git clone --recurse-submodules <this repo> && cd omacvm-app
scripts/build-app.sh          # dist/OmacVM.app
open dist/OmacVM.app
```

The first build compiles QEMU (about 70 seconds).

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
| `vendor/omacvm` | OmacVM (submodule): the installers and the VM side, `app` route |

Licences: `THIRD_PARTY_NOTICES.md`.
