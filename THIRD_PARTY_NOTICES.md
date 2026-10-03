# Third-party notices

OmacVM's own code is MIT (`LICENSE`). It reuses, with credit at the top of
each file taken from them:

- **try-omarchy** (github.com/omacom/try-omarchy), MIT, (c) Try Omarchy
  contributors, `app/runtime/LICENSE.try-omarchy`: OmacVM.app's QEMU build
  scripts and patches (`app/runtime`), `QMPConnection.swift`,
  `VMHostSleepController.swift`, `NativeBridgeSocket.swift` and
  `NativeClipboardBridge.swift` (`app/app/Sources/OmacVM`), and the VM's
  `omacvm-clipboard` and `omacvm-display-sync` (`src/app/guest`). Its release
  is also downloaded at build time as the temporary live system.
- **omarchy-parallels** (github.com/vincenzopalazzo/omarchy-parallels), MIT,
  (c) Vincenzo Palazzo, `src/vm/live/LICENSE`: the live image builder in
  `src/vm/live`.
- **omarchy-arm-utm** (github.com/ggalancs/omarchy-arm-utm), MIT, by ggalancs:
  `src/utm/guest/omacvm-vdagent` is based on its Wayland SPICE agent, and
  `src/utm/guest/90-omacvm-utm.conf` comes from it.
- **Omarchy** (github.com/basecamp/omarchy), MIT, (c) David Heinemeier Hansson:
  the bar widgets in `src/bridge/plugins` and `src/workspaces/plugins` are
  derived from Omarchy's own, each with its `LICENSE`; the icon
  (`src/icon/omacvm.svg`) uses Omarchy's mark.

What OmacVM.app ships (QEMU, edk2, QEMU's libraries) is listed in
[app/THIRD_PARTY_NOTICES.md](app/THIRD_PARTY_NOTICES.md).
