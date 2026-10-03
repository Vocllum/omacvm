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
  `NativeBridgeSocket.swift`, `NativeClipboardBridge.swift`, the camera
  (`camera.swift`, a link to `src/bridge/mac/camera.swift`, from
  `NativeCameraBridge.swift`) and the display sync script.
  `runtime/LICENSE.try-omarchy`.
  Its release is also downloaded at build time as the temporary live system.
- **edk2** UEFI firmware as built by the QEMU project: BSD-2-Clause-Patent,
  with OpenSSL (Apache-2.0) and others, see `edk2-licenses.txt`.
- **QEMU's libraries** in the app: GLib, libintl, libusb (LGPL-2.1+, kept as
  replaceable .dylib files); virglrenderer, libepoxy, pixman (MIT); ANGLE,
  libslirp, PCRE2 (BSD); SDL (zlib); zstd, lz4 (BSD); xz (0BSD).
- **OmacVM** (github.com/gillesgoetsch/omacvm, the repository the app is
  part of), MIT: the VM side, the base and Omarchy installers, the icon.
- In the VM, nothing is bundled: Arch Linux ARM and Omarchy (omarchy-mac) come
  from their own servers during the setup, each package under its own licence.
