# Benchmarks

How OmacVM measures the three routes against the Mac itself, so anyone can run
the same tests and get numbers that compare. The results so far are at the
end. The tools are in [`src/bench/`](../../src/bench).

> [!NOTE]
> **In progress.** The new runs (Google Chrome on both sides, 16 CPUs and 48 GB
> per VM) are not complete. Older numbers in the README used another method and
> don't compare with these.

## What we measure

| Test | What it tells you | Mac | VMs |
|---|---|---|---|
| Geekbench 7 CPU | CPU, single-core and multi-core | ✓ | ✓ (Linux ARM preview) |
| Speedometer 3.1 | web apps: browser and CPU together | ✓ | ✓ |
| MotionMark 1.3.1 | 2D graphics drawn through the browser | ✓ | ✓ |
| WebGL Aquarium, 30,000 fish | 3D in the browser, frames per second | ✓ | ✓ |
| Geekbench 7 GPU | GPU compute | ✓ (Metal) | ✗ see below |
| glmark2 | OpenGL ES in the VM, absolute score | ✗ no macOS build | ✓ |

**GPU compute is not possible in any of the three VMs.** Geekbench's GPU test
needs Vulkan or OpenCL, and none of Parallels, UTM or VMware Fusion offers
either to a Linux guest. `bench.sh` records that as "not available in this VM".
The browser tests (MotionMark, WebGL Aquarium) and glmark2 measure graphics
instead, not raw compute. glmark2 has no Mac version, so it has no Mac
baseline: compare its score between the routes only.

## The setup

Do all of this, or the numbers won't compare:

| | |
|---|---|
| Mac | MacBook Pro M4 Max, macOS 15.7.4 (ours; use yours and say which) |
| Each VM | 16 CPUs, 48 GB memory. On Parallels that needs Pro or the trial: Standard stops at 4 CPUs and 8 GB |
| One VM at a time | the VM under test runs alone. Quit the other VM apps, Parallels' background service included: `pgrep -l prl_` should print nothing while you test UTM or Fusion |
| Full screen | the VM app in full screen. `bench.sh` also starts Chrome full screen |
| No screensaver | Omarchy's screensaver and lock off: `omacvm disable idle-lock --vm NAME`. It can start in the middle of a run otherwise |
| Google Chrome everywhere | Google Chrome on the Mac and in the VM. Arch's Chromium is much slower than Chrome (Parallels: 35.4 with Chromium 153 vs about 45 with Chrome), so it would not compare |
| Chrome's flags | in a VM, `bench.sh` starts Chrome with the flags in Omarchy's `~/.config/chrome-flags.conf`. On Fusion that file must have `--ignore-gpu-blocklist`, or Chrome draws in software ([why](../troubleshooting.md#2-fusion-chrome-draws-everything-in-software)) |
| Runs | 3 of each test, report the median. Single runs land within 2 to 3 % of each other |

## Run it

### On the Mac

You need Google Chrome and Geekbench 7 in `/Applications`.

```bash
cd ~/.omacvm                      # or your clone of OmacVM
src/bench/bench.sh ~/bench/mac.jsonl
```

### In a VM

OmacVM copies its tools into the VM, so they are in
`/usr/local/share/omacvm/bench/` after `omacvm update` (or `omacvm apply`).

1. Install Google Chrome for Linux ARM (Arch Linux ARM has no package; this
   unpacks Google's own `.deb` to `/opt/google/chrome`). Run it again to update:

   ```bash
   sudo /usr/local/share/omacvm/bench/install-chrome.sh
   ```

2. For glmark2 and the renderer line, also install `glmark2` and `mesa-utils`
   with pacman.
3. Put the VM in full screen, open a terminal in Omarchy (as your desktop user,
   in the session, not over SSH) and run:

   ```bash
   /usr/local/share/omacvm/bench/bench.sh \
     --only geekbench,speedometer,motionmark,aquarium,gpu,glmark2 ~/fusion.jsonl
   ```

   glmark2 is not in the default list, hence `--only`. Leave the VM alone until
   it prints `results:`. Chrome opens and closes by itself.

4. Copy the file to the Mac. Name it after the route (`parallels`, `utm`,
   `fusion`), because the report and chart use the file names:

   ```bash
   scp -i ~/.ssh/omacvm root@<vm-ip>:/home/<user>/fusion.jsonl ~/bench/
   ```

### Options

```text
bench.sh [--runs N] [--only geekbench,speedometer,motionmark,aquarium,gpu,glmark2] [OUT.jsonl]
```

Each result is one JSON line: host, OS, test, run, value, and the browser
version or Geekbench link.

## Report and chart

On the Mac, with all files in one folder:

```bash
cd ~/bench
~/.omacvm/src/bench/report.py mac.jsonl parallels.jsonl utm.jsonl fusion.jsonl --json results.json
~/.omacvm/src/bench/chart.py results.json ~/.omacvm/docs/images/benchmarks.svg \
  "MacBook Pro M4 Max · macOS 15.7 · 16 CPUs, 48 GB per VM"
```

- `report.py` prints a Markdown table: the median of each test, and each route
  as a share of the first file (the Mac).
- `chart.py` draws the bar chart for the README from `results.json`: each route
  as a percentage of the Mac. glmark2 is left out, since it has no Mac value.

**About Geekbench.** The free version uploads every result to
browser.geekbench.com and prints only a link. `bench.sh` saves the link;
`report.py` opens each link in a visible Chrome window on the Mac and reads the
scores from the page. Geekbench's site turns away plain downloads, so curl
does not work. Your results are public on Geekbench's site.

## Results so far

2026-10-03, MacBook Pro M4 Max, macOS 15.7.4, Google Chrome 154. Medians of 3
runs. **In progress:** empty cells are not measured yet.

| | Mac | Parallels | UTM | VMware Fusion 26.0.1 |
|---|---|---|---|---|
| Speedometer 3.1 | 62.9 | to be measured again with Chrome | | 43.9 (70 %) |
| MotionMark 1.3.1 | 5865 | | | |
| WebGL Aquarium (fps) | | | | |
| Geekbench 7 single-core | | | | |
| Geekbench 7 multi-core | | | | |
| Geekbench 7 GPU | | ✗ | ✗ | ✗ |
| glmark2 | ✗ | | | |

The single runs:

| Test | Where | Runs | Median |
|---|---|---|---|
| Speedometer 3.1 | Mac | | 62.9 |
| MotionMark 1.3.1 | Mac | 5973, 5865, 5854 | 5865 |
| Speedometer 3.1 | Fusion, Chrome 154 in the VM | 43.9, 44.4, 43.2 | 43.9 |

Not counted: Parallels' Speedometer 35.4 was measured with Arch's Chromium 153
in the VM, not Chrome. It will be measured again.

### Older numbers

The README's "How fast" table and the Fusion numbers in
[experiments/vmware-fusion.md](../experiments/vmware-fusion.md) were measured
before this method: partly headless, partly with Arch's Chromium in the VM, on
other VM sizes and, for Fusion, on an M4 Mac mini. Don't mix them with the
table above.

## Draft README section

The comparison of the three routes for the README, with placeholders for these
numbers, is in [routes/comparison-draft.md](../routes/comparison-draft.md).
