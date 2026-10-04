# OmacVM docs

The background to OmacVM: how each route works, how we measure speed, and what
we found along the way. To set OmacVM up, start with the
[README](../README.md); coding agents start with [AGENTS.md](../AGENTS.md).

| Page | What it is for |
|---|---|
| [routes/vmware-fusion.md](routes/vmware-fusion.md) | Everything about the VMware Fusion route: what you need, what OmacVM does differently there, what works, fixes |
| [prebuilt.md](prebuilt.md) | Prebuilt VMs: using one, downloading one by hand, how they are made and checked, licences |
| [benchmarks/README.md](benchmarks/README.md) | How we benchmark the routes against the Mac, step by step, and the results so far |
| [troubleshooting.md](troubleshooting.md) | Non-obvious problems we hit, each as symptom, cause, fix and where in the code |
| [experiments/kosmickrisp.md](experiments/kosmickrisp.md) | Vulkan in the VM on KosmicKrisp (macOS 26+): what it took, numbers, and what still blocks Zink GL 3+, ANGLE on Vulkan and WebGPU |
| [experiments/vmware-fusion.md](experiments/vmware-fusion.md) | The plan and test log from building the Fusion route |
| [experiments/trackpad-scrolling.md](experiments/trackpad-scrolling.md) | How the macOS-native scroll momentum was tuned, over 29 rounds, with every measurement |
| [experiments/scroll-analysis/](experiments/scroll-analysis/) | The analysis scripts for the scroll momentum |
| [images/](images/) | The README's graphics (hand-written SVG with SMIL animation) and the demo video |

Parallels and UTM have no page of their own yet: their settings, failure
modes and dead ends are in [AGENTS.md](../AGENTS.md) (sections 4, 7 and 8).

`parallels-shortcuts.svg` stays in this folder, not in `images/`: `omacvm`
opens it from there (`src/mac/parallels-system-shortcuts.sh`).
