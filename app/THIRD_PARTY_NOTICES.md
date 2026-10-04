# Third-party notices

OmacVM.app's own code is MIT (`LICENSE`). It ships or uses:

- **QEMU** 11.1.1 (commit c3d48b7d), GPL-2.0 and other licences per file.
  Built from source by `runtime/build-qemu-gpu-runtime.sh` with the patches in
  `runtime/patches/`. Whoever gets the app can get that source and those
  patches: the build scripts and patches are in `app/runtime/` of the public
  repository github.com/gillesgoetsch/omacvm, at the release's tag, and QEMU's
  own source is at gitlab.com/qemu-project/qemu (commit c3d48b7d).
- **try-omarchy** (github.com/omacom/try-omarchy), MIT: the runtime build
  scripts and patches, `QMPConnection.swift`, `VMHostSleepController.swift`,
  `NativeBridgeSocket.swift`, the clipboard and battery bridges
  (`NativeClipboardBridge.swift`, `NativeBatteryBridge.swift`,
  `HostBattery.swift`), the camera (`camera.swift`, a link to
  `src/bridge/mac/camera.swift`, from `NativeCameraBridge.swift`) and the
  display sync script. `runtime/LICENSE.try-omarchy`.
  In the VM, the battery's kernel module (GPL-2.0-only, as try-omarchy's
  original file) and agent, in OmacVM's `src/battery/` (see the
  repository's `THIRD_PARTY_NOTICES.md`).
  Its release is also downloaded at build time as the temporary live system.
- **edk2** UEFI firmware as built by the QEMU project: BSD-2-Clause-Patent,
  with OpenSSL (Apache-2.0) and others, see `edk2-licenses.txt`.
- **QEMU's libraries** in the app: GLib, libintl, libusb (LGPL-2.1+, kept as
  replaceable .dylib files); virglrenderer, libepoxy, pixman (MIT); ANGLE,
  libslirp, PCRE2 (BSD); SDL (zlib); zstd, lz4 (BSD); xz (0BSD).
- **Vulkan for the VM (Venus)**: MoltenVK 1.4.2 (Apache-2.0, The Brenwill
  Workshop / Khronos) and the Khronos Vulkan loader 1.4.357 (Apache-2.0), from
  Homebrew's arm64_sequoia bottles. When the app carries KosmicKrisp, Mesa's
  Vulkan driver on Metal, Venus uses it on macOS 26 and newer. It is built
  from a pinned Mesa commit and is mostly MIT. Other parts: BSD-2-Clause
  (xxHash), BSD-3-Clause (Berkeley SoftFloat), BSL-1.0 (the C11 threads code),
  BLAKE3 (CC0-1.0 / Apache-2.0, used under Apache-2.0), and the Khronos
  headers under Apache-2.0 and SGI-B-2.0. `LICENSE.mesa-kosmickrisp.txt` in
  the licences folder lists the Mesa files it is built from, with their
  licence texts and the copyright lines of their headers. virglrenderer's
  macOS and Venus-on-Metal patches come from
  github.com/startergo/homebrew-virglrenderer (MIT).
- **OmacVM** (github.com/gillesgoetsch/omacvm, the repository the app is
  part of), MIT: the VM side, the base and Omarchy installers, the icon.
- In the VM, nothing is bundled: Arch Linux ARM and Omarchy (omarchy-mac) come
  from their own servers during the setup, each package under its own licence.
