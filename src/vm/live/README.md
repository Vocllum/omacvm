# vm/live — temporary live installer

`build-live.sh`, `lib/` and `templates/` come from
[vincenzopalazzo/omarchy-parallels](https://github.com/vincenzopalazzo/omarchy-parallels)
(MIT, `LICENSE` in this folder). They repackage the ARM64 root file system of
the official [try-omarchy](https://github.com/omacom/try-omarchy) release into
a disk that Parallels' ARM64 EFI boots, and inject an SSH key through the
initramfs.

OmacVM's build (`omacvm build`) uses that only as a temporary live Linux: it boots it,
installs Arch Linux ARM and omarchy-mac onto the VM's real NVMe disk, and then
removes the live disk again. Nothing from try-omarchy stays in the VM.
