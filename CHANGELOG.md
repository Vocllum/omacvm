# Changelog

What's new in each OmacVM release. The release notes on GitHub say the same
in more words.

## 2.6.0

- OmacVM.app: Omarchy in its own Mac app, without Parallels, UTM or VMware
  Fusion. It brings QEMU (try-omarchy's patched build) and runs it with
  Apple's Hypervisor framework. Download `OmacVM-2.6.0.zip` from the release,
  signed with a Developer ID. See [docs/routes/app.md](docs/routes/app.md).
- `omacvm build --vm-type app`: builds the VM through OmacVM.app with the same
  questions as the other routes. It downloads the app when it is missing
  (after asking) and checks the zip against its `.sha256`. `omacvm update`
  replaces an older app.
- Omanotch is built in: it lives in `src/omanotch` and OmacVM installs it
  from there, on the Mac and in the VM, with no clone of its own repo.
- Proofs between the VM and the Mac: the VM gives the Bridge's token to
  Gestures, the Bridge and Omanotch only after they have proved they know it
  (and the Mac address they answered on), so another program on the Mac
  can't catch it.
- TODO battery
- TODO camera
- TODO microphone
- TODO small items
