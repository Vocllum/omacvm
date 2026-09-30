# Why Parallels (and not UTM)?

Both were set up side by side on the same M4 Max MacBook Pro, same Omarchy
guest, same 16 cores and 48 GB:

| | macOS native | Parallels | UTM (QEMU) |
|---|---|---|---|
| Geekbench 7 single-core | 3286 | **3240** (98.6 %) | 3020 (91.9 %) |
| Geekbench 7 multi-core | 26999 | **26823** (99.3 %) | 24230 (89.7 %) |
| Speedometer 3.1 (Chrome) | 46.3 | **43.9** | 25.8 |
| Second monitor | — | GPU-accelerated, follows the macOS arrangement | flickers (non-accelerated second display) |
| Notch strip | — | black (hence this project) | black (a UTM option exists on macOS 27) |

Parallels runs Omarchy at practically native speed and drives an external
monitor flawlessly. The only thing missing was the notch — which is what this
fixes. All measurements, the setup and what helped:
[performance.md](performance.md).
