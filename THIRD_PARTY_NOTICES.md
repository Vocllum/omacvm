# Third-party notices

OmacVM's own code is MIT (`LICENSE`). Parts of it come from other projects,
under their own licences:

- **try-omarchy** (github.com/omacom/try-omarchy), MIT, (c) Try Omarchy
  contributors:
  - the Mac's battery in the VM: the kernel module
    `src/battery/guest/module/omacvm-battery.c` (GPL-2.0-only, as its
    original file `guest/native-module/try-omarchy-battery/try-omarchy-battery.c`
    says), its `Makefile` and `dkms.conf`, the agent
    `src/battery/guest/omacvm-battery` (from `omarchy-native-battery-bridge`),
    UPower's setting `90-omacvm-battery.conf`, and the Mac's side in
    `src/bridge/mac/battery.swift` and OmacVM.app's `HostBattery.swift` and
    `NativeBatteryBridge.swift`
  - OmacVM.app's clipboard (`src/app/guest/omacvm-clipboard`) and display
    sync, and what `app/THIRD_PARTY_NOTICES.md` lists for the app
  - its release, downloaded at build time as the temporary live system
- **omarchy-parallels** (github.com/vincenzopalazzo/omarchy-parallels), MIT,
  (c) Vincenzo Palazzo: the live installer in `src/vm/live/` (its `LICENSE`
  is there).
- **omarchy-arm-utm** (github.com/ggalancs/omarchy-arm-utm), MIT, by ggalancs:
  `src/utm/guest/omacvm-vdagent` is based on its Wayland SPICE agent.
- **Omanotch** (`src/omanotch/`) has its own README and licence.
- In the VM, nothing else is bundled: Arch Linux ARM and Omarchy
  (omarchy-mac) come from their own servers, each package under its own
  licence.

MIT licence of try-omarchy:

```
MIT License

Copyright (c) 2026 Try Omarchy contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
