# Every feature in detail

The short version is the grid at the top of the [README](../README.md).

| Feature | What it does |
|---|---|
| **The bar beside the notch** | With [Omanotch](../src/omanotch/README.md), Omarchy's real bar moves into the black strip beside the MacBook's notch, and your windows get the full height of the screen. The bar is as tall as macOS's menu bar, or exactly as tall as the notch (`defaults write ch.gillesgoetsch.omanotch flush -bool true`). OmacVM.app does it on its own |
| **Trackpad gestures** | Three- and four-finger swipes switch workspaces and pinch zooms while the VM is full screen; macOS's own Spaces swipe is off meanwhile. ⌃⌥⌘Esc hands the trackpad back to macOS. The MacBook's trackpad, or a Magic Trackpad on a Mac mini, iMac or Studio |
| **macOS-native scroll momentum** *(experimental, but awesome)* | Two-finger scrolling in every direction with your Mac's own acceleration and momentum, pinch included. Off unless you choose it ([how it works](#macos-native-scroll-momentum)) |
| **The Mac's Wi-Fi in the bar** | Real network name and signal, nearby networks, and Omarchy's QR card to share the password (macOS asks you first). Joining a network and switching Wi-Fi stay on the Mac for now |
| **The Mac's Bluetooth in the bar** | Omarchy's own Bluetooth panel for the Mac's devices: connect and disconnect them, battery levels (AirPods left, right and case), Bluetooth on and off, forget a device. Pairing a new one opens the Mac's Bluetooth settings |
| **The Mac's audio in the bar** | Volume, mute, microphone, switching outputs (AirPods show up when they connect), with Omarchy's input meter |
| **The Mac's camera** | Linux apps and video calls in the browser see the Mac's camera as *Mac Camera*. It is on, green light included, only while one of them uses it. Parallels passes the camera itself; on UTM, VMware Fusion and OmacVM.app OmacVM brings it ([how](how-it-works.md#the-mac-and-the-vm)). On UTM and Fusion it comes through OmacVM Bridge, which is then installed even with the Bridge turned off |
| **External display brightness** | With the VM in front on an external display, the brightness keys set *that* display, over DDC/CI, in macOS's 16 steps (Option: small steps), with Omarchy's popup. So do Omarchy's own brightness keys, `omarchy brightness display` and its monitor panel in the VM. A Studio Display or Pro Display XDR goes through macOS's own control. OmacVM.app: also in a window; Parallels, UTM and VMware Fusion: in full screen. On the built-in display nothing changes. Some displays and connections have no DDC/CI (some Macs' HDMI ports, or DDC/CI switched off in the display's own menu): there the keys do what they did before, and `omacvm check` says so. Off: `omacvm disable external-brightness` ([how it works](#external-display-brightness)) |
| **Media keys, Omarchy's popup** | Volume, mute and brightness keys drive the Mac and Omarchy shows its own on-screen display instead of macOS's. Shift with the brightness keys sets the Mac's keyboard light, with three dimmer steps below macOS's lowest, Option takes small steps, as in Omarchy |
| **Displays that follow the Mac** | Native Retina resolution and 120 Hz ProMotion. On Parallels and VMware Fusion also every external display, in exactly the arrangement you set in macOS, with Omarchy's scaling menu kept |
| **The GPU, in the desktop and the browsers** | Hyprland's animations, and pages and WebGL in Chromium, Chrome, Brave and Firefox, drawn by the Mac's GPU on every route (OmacVM fixes what each app gets wrong: [UTM](troubleshooting.md#14-utm-chrome-has-no-gpu-then-webgl-comes-out-empty), [Fusion](troubleshooting.md#2-fusion-browsers-draw-everything-in-software)) |
| **Per-display workspaces** | Each display has its own workspaces 1…0, like Spaces. Unplug and they park on the Mac's screen; plug back in and they return |
| **Clipboard both ways, Cmd+V** | Copy in Omarchy, paste on the Mac and back; Cmd+V pastes everywhere, terminals included |
| **Night Shift and True Tone** | The Mac's Night Shift in Omarchy's bar, with Omarchy's own night light icon, lit while it is on. A click opens a panel like Omarchy's own: Night Shift, its strength and True Tone, all on the Mac (Super+Ctrl+N switches Night Shift directly). It replaces Omarchy's own night light, so the screen is never tinted twice |
| **Wallpaper follows the theme** | Switch Omarchy's theme or background and the Mac's desktop wallpaper follows, on every Space (macOS also shows it behind its own lock screen) |
| **The Mac's clock** | Omarchy's clock at the far right of the bar, in your Mac's menu bar format (day, date, 12 or 24 hours, seconds, language) |
| **The Mac's battery** | On a MacBook, Omarchy's battery icon and panel show the Mac's charge and charging, as on a laptop, plus time left and Omarchy's low-battery warning (not tested yet with the Mac on battery; the VM never suspends for it). Parallels does this itself; OmacVM adds it on UTM, VMware Fusion and OmacVM.app |
| **Your keyboard layout** | Taken from the Mac |
| **Fast network** *(experimental, OmacVM.app, off by default)* | The VM on macOS's own VM network (vmnet) instead of QEMU's built-in one: faster to and from the Mac, steady latency, an address of its own. A small system service, so macOS asks for your password once: `omacvm enable fast-network` ([how](routes/app.md#fast-network-experimental-off-by-default)). On it the VM is a machine on a network of the Mac (`192.168.77.0/24`, the Mac at `192.168.77.1`), as with Parallels and UTM: it reaches every service the Mac offers on all its addresses (Remote Login, File Sharing, a dev server on `0.0.0.0`), not only OmacVM's own as on QEMU's built-in network |
| **Fast** | Near-native speed on Parallels; memory tuning so the VM does not hoard the Mac's RAM; btrfs snapshots you can boot from GRUB; optionally a memory-optimized kernel (transparent huge pages, MGLRU) |

<p align="center">
  <img src="images/features.svg" alt="Eight small animations: clipboard both ways with Cmd+V, Omarchy's Wi-Fi QR card after macOS asks, AirPods switching Omarchy's audio output, the Mac's wallpaper following the Omarchy theme, workspaces per display that park when unplugged, the keyboard layout taken from the Mac, the Omarchy Dock icon, and the omacvm command." width="100%">
</p>

<p align="center">
  <img src="images/displays.svg" alt="The macOS display arrangement and the Omarchy VM's monitors: when a display is moved in macOS, the VM's monitor moves the same way." width="100%">
</p>

## Full screen and the escape keys

Put the VM in full screen for the trackpad gestures, the scroll momentum and
the media keys. While it is full screen and in front, the Mac's trackpad
gestures and ⌘ shortcuts go to Omarchy, and macOS's own Spaces swipe is off.

**⌃⌥⌘ Esc** (Control + Option + Command + Escape) hands the trackpad back to
macOS (Omarchy shows a notification), so you can swipe to your other Spaces.
Press it again, or come back to the full-screen VM, to hand it to Omarchy
again. Volume and brightness keys always change the Mac, with Omarchy's popup
while you are in the VM.

<p align="center">
  <img src="images/capture.svg" alt="A MacBook shows Omarchy full screen, marked as captured with a lock. Three fingers swipe and Omarchy changes workspace while macOS's Spaces swipe is blocked; Command+Space opens Omarchy's launcher. Control+Option+Command+Escape opens the lock: Omarchy shows a notification, the trackpad belongs to macOS again and a four-finger swipe moves to the Mac's other Space. Back on the full-screen VM it is captured again. A panel shows where trackpad gestures, Command shortcuts and media keys go in each moment." width="100%">
</p>

## External display brightness

macOS sets the brightness of its own displays only: the built-in one and
Apple's Studio Display and Pro Display XDR. Most other monitors take it over
DDC/CI, a small command channel in the display cable, which macOS does not
use (apps like MonitorControl do). OmacVM Bridge does it for the display your
VM is on:

- **Which display.** The one the VM's window is in front on: under the
  pointer when the VM covers several displays. OmacVM.app counts in a window
  too; Parallels, UTM and VMware Fusion in full screen, as for the other media
  keys. On the MacBook's own display the keys work as before.
- **How.** It reads the display's level first, then steps in macOS's 16
  steps (Option or Shift+Option: 64), and shows Omarchy's popup. Held keys
  are sent at most every 50 ms, only the latest level, and the keys never wait
  for the display.
- **From the VM.** Omarchy drives an external monitor with `ddcutil`; OmacVM
  puts a small `ddcutil` in the VM (`/usr/local/bin/ddcutil`) that asks the
  Bridge instead: "set the brightness of the display this output is on, 0 to
  100". The Bridge checks which display that is itself and only ever touches
  an external display with a VM window on it: the VM never reaches the
  display's I2C bus.
- **What works where.** `omacvm check` lists each external display: DDC/CI,
  its own control (Apple displays), or why not. No DDC/CI: on some Macs'
  built-in HDMI ports (try USB-C or DisplayPort), through some docks, or when
  DDC/CI is switched off in the display's own menu.
- **Off.** `omacvm disable external-brightness` takes it out of the VM and,
  through the Bridge's `config.json` (`external_brightness`), out of the
  keys. The Bridge is one for all VMs, so the last `omacvm apply` decides.

## macOS-native scroll momentum

Parallels, UTM and Fusion give Linux a mouse wheel: your trackpad's two-finger
scrolling arrives as wheel steps, and the feel of macOS (acceleration,
momentum, precise slow scrolling) is gone. With this on, the full-screen
VM gets the real thing instead:

- **Your fingers**, as raw positions from the trackpad, precise to
  hundredths of a millimetre, on a virtual Apple trackpad in the VM: slow
  scrolling follows them exactly;
- **macOS's own acceleration**, blended in as you speed up;
- **macOS's own momentum** after you lift, continued on the same virtual
  fingers, so apps add no fling of their own. Measured side by side with macOS,
  the glide after a flick lands within 5–10 % of macOS's distance, with the
  same decay;
- **pinch** whenever macOS recognizes one.

It is tuned against a MacBook Pro 16" and scales itself to yours: the
trackpad's size, your scrolling direction and speed setting, and Omarchy's
display scale. Chromium-based apps (Chrome, Slack, VS Code, …) scroll about 3×
further per movement than GTK apps, so they get their own factor.

It is **experimental**: tuned on one Mac, by feel and by measurement, over 29
rounds. The whole story, with every measurement and the analysis scripts, is in
[experiments/trackpad-scrolling.md](experiments/trackpad-scrolling.md).
Try it with `omacvm enable scroll-momentum`, go back with `omacvm disable scroll-momentum`.
