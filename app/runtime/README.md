# Runtime

QEMU for OmacVM, built from source. The build scripts and patches come from
[try-omarchy](https://github.com/omacom/try-omarchy) (MIT, `LICENSE.try-omarchy`),
commit 82927e9. Changes here:

- scratch files go to `.build/tmp` instead of `/private/tmp` (macOS's temp folder when the
  checkout's path has a space: QEMU's configure refuses one)
- `patches/omacvm-cocoa-identity.patch`: the app name and icon come from the
  launcher (`OMACVM_PRODUCT_NAME`, `OMACVM_ICON`)
- the edk2 UEFI firmware is kept in `.build/firmware`, so an installed
  system boots through GRUB. `build-edk2.sh` builds it: the edk2 QEMU 11.1.1
  ships (edk2-stable202408, `roms/edk2-version`), with QEMU's own helper and
  flags (`roms/edk2-build.py`, `roms/edk2-build.config`, build
  `armvirt.aa64`, DEBUG as QEMU ships it), clang 18 instead of GCC, and
  `patches/edk2-logo-omarchy.patch`: Omarchy's logo instead of TianoCore's
  (made by `boot-logo/make-logo-bmp.py` from Omarchy's `logo.svg`), and
  `patches/edk2-bootmanager-nvme-identify-align.patch`: with clang, edk2
  could not read the NVMe disk's name and renamed its boot entry to "UEFI
  Misc Device"; now it is "UEFI QEMU NVMe Ctrl omacvm 1" as with QEMU's
  firmware. `Tests/firmware/test-firmware.py` boots it with an empty disk
  and checks both: the logo on the screen and the disk's boot entry. If the
  build or that test fails, or with `OMACVM_FIRMWARE=qemu`, QEMU's prebuilt
  firmware is used (TianoCore logo);
  `.build/firmware/firmware-source` says which. It builds in
  `/private/tmp/omacvm-edk2-build` whatever the checkout: the DEBUG build
  carries its file paths, so every checkout gives the same bytes and the
  firmware carries no user name (the build checks that). The flash layout and the
  boot variables are the same either way: a VM's `efi-vars.fd` works with
  both
- `patches/virgl-texture-integer-samplers.patch`: shaders that read integer
  textures (`usampler2D`) compile on the Mac's OpenGL. Before, Apple's
  compiler refused them and the guest's GL context stopped for good: Chrome's
  GPU process hung (Basemark Web 3.0 at test 5). The build checks it with
  `Tests/virgl/test-integer-sampler-shader.c`, which compiles the generated
  GLSL with the Mac's OpenGL
- `patches/virgl-transfer-row-size.patch`: no texture transfer moves more
  bytes per row in GL than the guest's buffers hold. The YUYV plane format
  (R8G8_R8B8) moved twice as many, and its readback overflowed QEMU's heap:
  mpv's VA-API probe stopped the VM. That format is gone; the row check covers
  the others. Tested at build time by `Tests/virgl/test-transfer-row-size.c`

Build: `./build-qemu-gpu-runtime.sh` (about 70 seconds, needs only the Command
Line Tools; the firmware about 2 minutes more the first time, then kept in
`.build/edk2`). Output: `.build/qemu-gpu-runtime` and `.build/firmware`.

QEMU is GPL-2.0. Anyone who gets a built app must also be able to get this
source and the patches.
