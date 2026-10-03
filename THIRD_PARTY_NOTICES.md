# Third-party notices

OmacVM's own code is MIT (`LICENSE`). Parts of it come from other projects,
under their own licences, with credit at the top of each file taken from them:

- **try-omarchy** (github.com/omacom/try-omarchy), MIT, (c) Try Omarchy
  contributors, `app/runtime/LICENSE.try-omarchy`:
  - the Mac's camera in the VM: `src/bridge/mac/camera.swift` (from
    `NativeCameraBridge.swift`; OmacVM.app uses it too), the VM's
    `src/camera/guest/omacvm-camera` (from `omarchy-native-camera-bridge`)
    and its v4l2loopback and udev settings
  - OmacVM.app's clipboard (`src/app/guest/omacvm-clipboard`) and display
    sync, and what [app/THIRD_PARTY_NOTICES.md](app/THIRD_PARTY_NOTICES.md)
    lists for the app
  - its release, downloaded at build time as the temporary live system
- **omarchy-parallels** (github.com/vincenzopalazzo/omarchy-parallels), MIT,
  (c) Vincenzo Palazzo: the live installer in `src/vm/live/` (its `LICENSE`
  is there).
- **omarchy-arm-utm** (github.com/ggalancs/omarchy-arm-utm), MIT, by ggalancs:
  `src/utm/guest/omacvm-vdagent` is based on its Wayland SPICE agent.
- **Omanotch** (`src/omanotch/`) has its own README and licence.
- In the VM, nothing else is bundled: Arch Linux ARM and Omarchy
  (omarchy-mac) come from their own servers, v4l2loopback too (built in the
  VM by DKMS, GPL-2.0), each package under its own licence.
