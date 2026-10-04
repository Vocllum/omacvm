# Decision records

Short records of decisions with real trade-offs: context, options, decision,
consequences. Numbers start at 0010 (0001-0009 left free for older
decisions we may write down later). A record is not edited once accepted;
a new record replaces it and says so.

| No. | Decision | Status |
|---|---|---|
| [0010](0010-iosurface-present.md) | Show the guest's frames as IOSurfaces | accepted, built (`gpu-native`) |
| [0011](0011-async-fences.md) | Report GPU fences from a sync thread, not a timer | accepted, built, open hang |
| [0012](0012-venus-in-process.md) | Venus render server as a thread of QEMU on macOS | accepted, built (`gpu-venus`) |
| [0013](0013-moltenvk-then-kosmickrisp.md) | MoltenVK now, KosmicKrisp on macOS 26 | accepted, MoltenVK built |
| [0014](0014-videotoolbox-in-virglrenderer.md) | VideoToolbox inside virglrenderer's video path | accepted, built (`video-decode`) |
| [0015](0015-one-window-per-display.md) | One window per Mac display | accepted, built (`app-displays`) |
| [0016](0016-gpu-context-loss.md) | A refused shader skips its draws; a lost context tells the guest | accepted, built (`gpu-robust`) |
| [0017](0017-guest-gpu-ranges.md) | The host checks every buffer range a guest draw reaches | accepted, built (`gpu-robust`) |
| [0018](0018-guest-gpu-memory.md) | Every GL context is flushed; guest resources have a memory budget | accepted, built (`gpu-robust`) |

The whole chain: [../architecture/graphics.md](../architecture/graphics.md).
