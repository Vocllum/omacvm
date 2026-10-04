<h1 align="center">OmacVM</h1>

<h3 align="center">Omarchy in a VM on your Mac, feeling native</h3>

<p align="center">One command builds the VM, in its own app OmacVM.app, UTM, VMware Fusion or Parallels Desktop. Then your Mac's Wi-Fi, Bluetooth, sound, keys, trackpad, displays, Night Shift and wallpaper all work in Omarchy.</p>

<p align="center">
  <b>With <a href="src/omanotch/README.md">Omanotch</a></b>: Omarchy's real bar beside the MacBook's notch, where the VM leaves a black strip.
</p>

```bash
curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | bash
```

<p align="center">Using a coding agent? <a href="docs/agents.md">Copy the prompt for it</a>.</p>

<p align="center">
  <img src="docs/images/hero.svg" alt="Animated overview. A MacBook runs Omarchy full screen; the VM leaves a black strip beside the notch. The VM's invisible notch monitor appears above, Omanotch streams Omarchy's real bar into the strip piece by piece, the windows grow to full height, the pointer glides into the strip and a click on the clock opens Omarchy's calendar. Then, with the macOS host shown above the VM and OmacVM Bridge between them: the Mac's Wi-Fi and volume arrive in Omarchy's bar; volume and brightness keys drive the Mac while Omarchy shows the popup; three- and four-finger swipes and pinch arrive through OmacVM Gestures while macOS's Spaces swipe is off; Super+Ctrl+N switches the Mac's Night Shift; an external display joins in the macOS arrangement." width="100%">
</p>

| What you get in Omarchy | How you run it |
|---|---|
| 🔳 **Omanotch**<br>Omarchy's real bar beside the MacBook's notch, where the VM leaves a black strip. | 🍎 **Standalone app, UTM, VMware Fusion or Parallels**<br>Pick one, OmacVM sets it up the same way. |
| 🎬 **Hardware video decoding**<br>YouTube 4K on the Mac's media engine, not the CPU. | 💻 **Runs on M1, M2, M3, M4, M5, M6**<br>Adapts to notch, ProMotion, HDR and missing hardware on its own. |
| 🎮 **Real GPU performance**<br>Vulkan, WebGPU and OpenCL in the VM. *(coming with 2.9.0)* | 🛠️ **A setup script that fits your needs**<br>Pick the app, CPUs, memory, disk, keyboard, user and every feature; change them later anytime. |
| 🖥️ **Multiple external monitors**<br>Every display in your macOS arrangement, hardware accelerated. *(coming with 2.8.0)* | ⏱️ **Ready in 5 minutes**<br>Download a prebuilt VM, or build it fully yourself. |
| 👆 **Mac trackpad gestures**<br>2, 3 and 4 finger swipes and pinch zoom, plus optional macOS-like momentum scrolling. | 🎨 **Theme and wallpaper sync**<br>Your Omarchy theme and wallpaper carry over to macOS. |
| ⌨️ **Mac keys, fully Omarchy**<br>Cmd works as Super, macOS shortcuts stay out of the way. | 🔋 **Optimized for battery**<br>Measured power draw on every route, tuned to stay close to macOS. |
| 📶 **Wi-Fi, audio and battery from the Mac**<br>The bar shows your real networks, sound devices and battery. | 🔀 **Features on or off anytime**<br>`omacvm features` switches them on an existing VM. |
| 🔊 **Native volume and brightness**<br>The Mac's keys with Omarchy's own popups. | 🩺 **One check for everything**<br>`omacvm check` tells you what works and what to fix. |
| 💡 **Keyboard backlight**<br>Shift+F1/F2 dims and brightens the Mac's keyboard, like Omarchy on a laptop. | 🔄 **One command to update**<br>`omacvm update` brings the Mac side and the VM up to date. |
| 📷 **Camera and microphone**<br>Video calls in the VM. | 🔐 **Token-secured bridge to the Mac**<br>Only your own VM can talk to the Mac side, proven with a secret token. |
| 📋 **Copy and paste, both ways**<br>Plus Night Shift, True Tone and the Mac's clock format. | |

**[See the full compatibility list per app below](#which-app), or [every feature in detail](docs/features.md).**

<p align="center">
  <img src="docs/images/demo.webp" alt="Filmed on a MacBook Pro: a swipe from macOS into the full-screen Omarchy VM, Omarchy's bar beside the notch, and the Mac's Wi-Fi, sound and battery in Omarchy's bar, then a swipe to the next workspace." width="100%">
</p>

<a name="four-ways-parallels-utm-vmware-fusion-or-omacvmapp"></a>

### Which app?

**OmacVM.app** is the recommended way: free, open source, and the only one with hardware video and the full GPU. **UTM** is the free classic. **VMware Fusion** is free and supports external monitors. **Parallels** is the most polished, but paid.

| | OmacVM.app | UTM | VMware Fusion | Parallels |
|---|:---:|:---:|:---:|:---:|
| **Price** | free | free | free | paid |
| **Open source** | ✅ | ✅ | ❌ | ❌ |
| Omanotch | ✅ | ✅ | ✅ | ✅ |
| Hardware video decoding | ✅ | ❌ | ❌ | ❌ |
| GPU in desktop and browsers | ✅ | ✅ | ✅ | ✅ |
| Vulkan, WebGPU, OpenCL | 🔜 2.9.0 | ❌ | ❌ | ❌ |
| External monitors | 🔜 2.8.0 | ❌ | ✅ | ✅ |
| 120 Hz ProMotion | 🔜 2.9.0 | ✅ | ✅ | ✅ |
| Trackpad gestures | ✅ | ✅ | ✅ | ✅ |
| Momentum scrolling (optional) | ✅ | ✅ | ✅ | ✅ |
| Cmd as Super | ✅ | ✅ | ✅ | ✅ ¹ |
| Wi-Fi, Bluetooth, audio from the Mac | ✅ | ✅ | ✅ | ✅ |
| Battery in the bar | ✅ | ✅ | ✅ | ✅ |
| Volume and brightness | ✅ | ✅ | ✅ | ✅ |
| Keyboard backlight (Shift+F1/F2) | ✅ | ✅ | ✅ | ✅ |
| Camera and microphone | ✅ | ✅ | ✅ | ✅ |
| Copy and paste | ✅ | ✅ | ✅ ² | ✅ |
| Theme and wallpaper sync | ✅ | ✅ | ✅ | ✅ |
| Prebuilt VM (5 min) | 🔜 ³ | ✅ | ✅ | ✅ |
| CPU and memory limit | none | none | none | 4 CPUs, 8 GB on Standard |

¹ after one setting in Parallels · ² when the pointer crosses the VM's edge · ³ coming soon; until then the app builds its VM in about 12 minutes

Full comparison with benchmarks: [docs/compare.md](docs/compare.md).

## Get started

```bash
curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | bash
```

This puts OmacVM in `~/.omacvm`, adds the `omacvm` command and starts it. Run
`omacvm` any time after that: with no VM yet it builds one; otherwise it asks
what you want to do (build another VM, switch features, update, check).

Prefer git? `git clone https://github.com/gillesgoetsch/omacvm && cd omacvm && ./install.sh`
(or just `./omacvm`).

Or let your coding agent do it: [the prompt and more](docs/agents.md).

## Requirements

- An Apple Silicon Mac, M1 or newer. On an M1 or M2 you can also run Omarchy
  natively with [Asahi Linux](https://asahilinux.org); OmacVM is for M3 and
  newer, which Asahi does not support yet, and for anyone who wants macOS and
  Omarchy side by side.
- macOS 15 or newer for OmacVM.app, macOS 14 or newer for the other apps.
- About 30 GB of free disk space for the build (a finished VM takes 10–12 GB
  and grows as you use it), and a decent connection.
- One of the apps:
  - **OmacVM.app**: nothing to install, `omacvm` downloads it
    ([details](docs/routes/app.md)).
  - **UTM 5** (a beta): `brew install --cask utm@beta`. UTM 4.7 does not work
    ([details](docs/routes/utm.md)).
  - **VMware Fusion** 13 or newer: a free download after a Broadcom sign-in
    ([details](docs/routes/vmware-fusion.md)).
  - **Parallels Desktop** 19 or newer ([details](docs/routes/parallels.md)).
- Xcode Command Line Tools (`xcode-select --install`). For UTM, Fusion and
  Parallels also [Homebrew](https://brew.sh) with `brew install zstd e2fsprogs`.

`omacvm` tells you about anything missing before it starts, and installs it
or waits while you do.

## Build a VM

```bash
omacvm            # or: omacvm build
```

It asks a few questions (the app, build or download, how much of the Mac the
VM gets, where it goes, features, your user and password), shows a summary
and builds. That takes 30 to 70 minutes (OmacVM.app about 12, VMware Fusion
about 15 more), or a few minutes after a 3.5 to 6 GB download with a prebuilt VM. A VM window
opens on the way: that is the temporary installer, leave it alone.

Main options:

- `--vm-type app|utm|fusion|parallels`: the app
- `--prebuilt` or `--build`: download a prebuilt VM, or build it here
- `--resources low|balanced|high|best`, or `--cpus N --memory-gb N`
- `--vm-dir PATH`: where the VM goes, an external drive too
- `--FEATURE` / `--no-FEATURE`, for example `--scroll-momentum` or `--no-wallpaper`
- `--dry-run`: ask everything, stop at the summary
- `--yes`: no questions; the password comes from `OMACVM_PASSWORD`

`omacvm build --help` lists them all. Every step in detail:
[docs/guide.md](docs/guide.md).

When it is done, allow the macOS prompts for *OmacVM Bridge* and *OmacVM
Gestures* ([which ones](docs/guide.md#after-the-build)). On Parallels, change
[one setting](docs/routes/parallels.md#after-the-build-let-cmd-reach-omarchy)
so Cmd reaches Omarchy.

## Everyday use

```bash
omacvm features                 # switch features on or off
omacvm enable scroll-momentum   # or straight away (disable works the same)
omacvm update                   # the newest OmacVM, on the Mac and in every running VM
omacvm check                    # what works and what to fix; it changes nothing
omacvm vms                      # your VMs and their OmacVM version
```

Add `--vm NAME` for a VM other than the default. Your feature choices survive
updates. Already have an Omarchy VM from omarchy-mac? `omacvm apply --vm NAME`
adds OmacVM to it. More: [docs/guide.md](docs/guide.md).

Put the VM in full screen for the trackpad gestures, the scroll momentum and
the media keys. **⌃⌥⌘ Esc** (Control + Option + Command + Escape) gives the
trackpad back to macOS, for example to swipe to your other Spaces; press it
again to hand it back to Omarchy ([more](docs/features.md#full-screen-and-the-escape-keys)).

## How it works

OmacVM installs [omarchy-mac](https://github.com/omacom/omarchy-mac), the Arch
Linux ARM port of Omarchy, onto the VM's own disk: a full Omarchy with your
user and `omarchy update`, not a demo. Small helpers on the Mac pass the Mac's
hardware to the VM over the VM's private network, with a secret token:
**OmacVM Bridge** (Wi-Fi, Bluetooth, audio, displays, media keys, wallpaper),
**OmacVM Gestures** (trackpad and ⌘ keys) and **Omanotch** (the bar beside
the notch). In the VM, small services feed Omarchy's own bar and popups.

Each piece in detail: [docs/how-it-works.md](docs/how-it-works.md). The whole
build, every VM setting and the dead ends: [AGENTS.md](AGENTS.md). Everything
else: [docs/](docs/README.md).

## Troubleshooting

Start with `omacvm check`: it names what is wrong and what to do.

- **The Mac's menu bar stays over the full-screen VM**: System Settings › Menu
  Bar › Automatically hide and show the menu bar: **In Full Screen Only**.
- **Gestures do nothing**: the VM must be full screen and in front, and
  ⌃⌥⌘ Esc may have handed the trackpad to macOS (press it again). Check the
  Accessibility and Input Monitoring permissions of *OmacVM Gestures*.
- **"answers with another SSH host key"** after rebuilding a VM:
  `omacvm apply --vm NAME --reset-host-key`.

More problems and their fixes: [docs/troubleshooting.md](docs/troubleshooting.md).

## Uninstall

```bash
omacvm uninstall            # --purge also removes the bridge token and settings
```

Then delete the VM in OmacVM.app, UTM, VMware Fusion or Parallels Desktop. In
System Settings › Privacy & Security, remove the OmacVM apps from Location
Services if still listed.

## Credits

[Omarchy](https://omarchy.org) (MIT), [omarchy-mac](https://github.com/omacom/omarchy-mac)
and [try-omarchy](https://github.com/omacom/try-omarchy) by the Omarchy team
(try-omarchy, MIT, gives the camera bridge, the Mac's battery in the VM:
kernel module, agent and the Mac's side, and OmacVM.app's pieces), [Arch Linux ARM](https://archlinuxarm.org),
[omarchy-parallels](https://github.com/vincenzopalazzo/omarchy-parallels) by
Vincenzo Palazzo (MIT), whose image builder is the temporary installer here, and
[omarchy-arm-utm](https://github.com/ggalancs/omarchy-arm-utm), whose UTM
findings (virtio-gpu settings, UTM's scripting) shaped the UTM route and
whose Wayland SPICE agent (MIT) OmacVM's `omacvm-vdagent` is based on. The bar
widgets are clones of Omarchy's own. OmacVM is a community project, not
affiliated with the Omarchy team, Parallels, UTM, VMware (Broadcom) or Apple.

## License

MIT, see [LICENSE](LICENSE). The code OmacVM reuses from others is listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
