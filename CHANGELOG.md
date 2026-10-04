# Changelog

What's new in each OmacVM release. The release notes on GitHub say the same
in more words.

## 2.7.0

- OmacVM.app: videos are decoded by the Mac's media engine instead of the
  VM's CPU. Google Chrome, Brave and Firefox (H.264 and VP9; AV1 in Chrome,
  not yet in Firefox), mpv, FFmpeg and GStreamer apps use it: YouTube in 4K
  at 60 fps plays with the VM's CPU nearly idle. HEVC and 10-bit video work
  too (mpv, FFmpeg, GStreamer; in Chrome HEVC stops after a seek for now). Omarchy's own Chromium
  (Arch Linux ARM) is built without VA-API and still decodes on the CPU; a
  route for it (V4L2) is planned. OmacVM installs no browser for this; Google
  Chrome for Linux ARM comes from `src/bench/install-chrome.sh`. See
  [docs/video-decode.md](docs/video-decode.md).
- OmacVM.app: a Linux app could stop the VM by reading back a texture in the
  YUYV plane format (mpv's VA-API check did): QEMU's heap overflowed. Fixed in
  the app's virglrenderer, with a build-time test for every texture format.
- Mac mini, iMac and Studio: a Studio Display or LG UltraFine's brightness
  follows the brightness keys; no keyboard light, notch or trackpad is a skip
  in `omacvm check`, not a failure; a Parallels VM on a Mac without a battery
  says so; Gestures finds VMware Fusion VMs when Fusion started after it; the
  Bridge picks the main display first.
- The menu says a suspended VM is suspended, not stopped.
- UTM and VMware Fusion: right after the first boot, the battery agent waits
  for the Bridge instead of failing (`omacvm check` reported it, and the
  Wi-Fi QR card, until a minute later).
- VMs from the 2.5 and 2.6 prebuilt images: the desktop background was black
  (links into the image's placeholder home). First boot now fixes the links;
  `omacvm apply` or `omacvm update` repairs older VMs.
- OmacVM.app: building a VM under the name of a deleted one no longer stops
  at step 5 (the old SSH host key), and a build works again after macOS
  cleared the live system's cache.
- Gestures: with two OmacVM.app VMs running, each keeps its connection (they
  all come from 127.0.0.1 and pushed each other out every second).

## 2.6.0

- OmacVM.app: Omarchy in its own Mac app, without Parallels, UTM or VMware
  Fusion. It brings QEMU (try-omarchy's patched build) and runs it with
  Apple's Hypervisor framework. Download `OmacVM-2.6.0.zip` from the release,
  signed with a Developer ID. See [docs/routes/app.md](docs/routes/app.md).
- `omacvm build --vm-type app`: builds the VM through OmacVM.app with the same
  questions as the other routes. It downloads the app when it is missing
  (after asking), checks the zip against its `.sha256` and that the app is
  signed with OmacVM's Developer ID. `omacvm update` replaces an older app.
- Omanotch is built in: it lives in `src/omanotch` and OmacVM installs it
  from there, on the Mac and in the VM, with no clone of its own repo.
- Proofs between the VM and the Mac, so another program on the Mac can't pose
  as Gestures, the Bridge or Omanotch: Gestures and Omanotch never get the
  Bridge's token; the VM and the helper each prove they know it (HMAC-SHA256
  over fresh nonces and the Mac address). The Bridge gets the token only
  after its own proof checks out.
- The Mac's battery in Omarchy's bar on a MacBook: charge, charging and
  Omarchy's battery panel, as on a laptop (feature `battery`, on for UTM,
  VMware Fusion and OmacVM.app; Parallels shows it itself). The VM never
  suspends for a low battery. Time left and the low-battery warning are not
  tested yet with the Mac on battery. See
  [src/battery/README.md](src/battery/README.md).
- The Mac's camera as *Mac Camera* for Linux apps and video calls in the
  browser (feature `camera`). It is on only while an app uses it. UTM and
  Fusion get it through OmacVM Bridge (installed for it also with the
  Bridge off), OmacVM.app over its own port, Parallels shares it itself.
  Programs on the Mac can't use the Bridge's camera.
- Sound and the Mac's microphone on UTM and Fusion: new VMs get a sound card,
  an existing one gets it the next time `omacvm apply` starts it from shut
  down. macOS must allow the VM's app the microphone; `omacvm check` says
  when it doesn't. OmacVM.app asks for it when it starts a VM; its QEMU
  starts the recording on a thread of its own, so a slow start never stops
  the VM (the VM records silence until the microphone runs).
- WebGL pages no longer hang in OmacVM.app. Basemark Web 3.0 stopped at its
  fifth test because the app's virglrenderer turned shaders that read integer
  textures into GLSL the Mac refuses (finding 23 in
  [docs/troubleshooting.md](docs/troubleshooting.md)).
- Omanotch can make its bar exactly as tall as the notch:
  `defaults write ch.gillesgoetsch.omanotch flush -bool true`. Off by default.
- The Mac's keyboard light goes three steps dimmer than macOS's lowest with
  Shift and the brightness keys (`"keyboard_low_steps": false` in the
  Bridge's `config.json` turns them off).
- One event stream from the Mac per VM, shared by the bar widgets and the
  on-screen display, instead of up to nine.
- Benchmarks: the GPU as a share of the Mac in the README (Basemark Web 3.0
  and WebGL Aquarium in Chrome). `bench.sh` runs Basemark too, and Geekbench's
  GPU test with Metal and OpenCL on the Mac. No VM can run Geekbench's GPU
  test: its Linux ARM preview has none, and no VM offers Vulkan or OpenCL.
