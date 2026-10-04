# Browsers and the GPU in the VMs

Status: round 1 done. Where the time goes is measured on all four routes; no
browser flag or preference we tried makes WebGL faster, so OmacVM keeps
Chrome's and Firefox's defaults (Fusion keeps `--ignore-gpu-blocklist`, which
turns the GPU on there at all).

## The question

WebGL Aquarium with 30,000 fish runs at 107.7 fps in Chrome on the Mac and
at 24 to 43 fps in the VMs (Parallels 26.7, UTM 28.1, Fusion 42.9,
OmacVM.app 23.9; Chrome 154, full screen, 2026-10-04). Parallels has by far
the best glmark2 score (7306), yet it is not faster in the browser. Why, and
what can the guest change?

## How we measured

Own test VMs per route (prebuilt 2.4.0 updated to 2.6.0, 8 CPUs, 16 GB,
in a window, not full screen; OmacVM.app: a copy of a test VM started like
the app starts it), Google Chrome 154, Chrome full screen inside Hyprland.
Every number below was taken holding the benchmark lock with the other test
VMs paused. Same flags, alternating runs (A B A B ...), median.

- Aquarium fps: `g_fpsTimer.averageFPS`, mean over 15 s after 10 s warm-up.
- CPU per frame: `utime + stime` of Chrome's GPU process and of the busiest
  renderer from `/proc`, and of the VM process on the Mac (`ps`), over 10 s,
  divided by the frames drawn.
- Where it goes: `perf record -e cpu-clock` on the GPU process in the guest,
  `perf` tracepoints `virtio_gpu:*` and `dma_fence:*` (submits, fence
  latency), `sample` of the VM process on the Mac, virglrenderer's
  `VREND_DEBUG=cmd` (OmacVM.app) for the command stream.
- Correctness: a WebGL 1 and 2 probe (antialias on and off, a texture from a
  2D canvas, instancing, primitive restart, `readPixels` and a 2D read-back)
  hashed per setting.

## Results

Aquarium, 30,000 fish = 30,000 draw calls per frame (1,000 fish reach the
display's refresh rate everywhere: it is the draw calls, not the pixels).

| Route | Window | fps | GPU process ms/frame | VM process on the Mac ms/frame | Busy where |
|---|---|---|---|---|---|
| Parallels | 1280x960 | 27.0 | 8.4 | 60 | one host thread at 100 %: Apple's OpenGL |
| VMware Fusion | 1280x800 | 39.3 | 26.6 (100 %) | 48 | the guest's GPU process: Mesa's svga driver |
| OmacVM.app | 2880x1620 | 22.7 | 45 (100 %, a third of it waiting) | 73 | QEMU's main loop at 100 %: Apple's OpenGL |
| UTM | 3456x2160 | 12.0 | 80 | 172 | UTM in the background: virtual CPUs waiting for QEMU's lock (see below) |

### Parallels

The guest is nearly idle: the GPU process spends 8 ms of a 37 ms frame.
Chrome sends about 34 fenced submits per frame, and each is signalled about
50 ms after it was queued: the host has a backlog. On the Mac one thread of
`prl_vm_app` ("video.worker") runs at 100 %. `sample` shows 59 % of it inside
Apple's OpenGL (`glDrawElements` → `AppleMetalOpenGLRenderer`
`setRenderState`: textures, samplers, uniforms and the Metal pipeline set up
again for every draw) and about a third in Parallels' own command decoding.
Parallels translates virgl to Apple's OpenGL, which runs on Metal: a large
fixed cost per draw call, on a single thread. glmark2 draws few, large
batches, so it doesn't notice; WebGL pages that draw many small objects do.

### VMware Fusion

Here the guest is the limit: Chrome's GPU process is busy for the whole
frame. `perf`: 46 % in Mesa's `svga` driver, 20 % in Chrome and ANGLE, 16 %
in the `vmwgfx` kernel driver, most of it `__vmw_fences_update` behind
`DRM_VMW_FENCE_SIGNALED` (Mesa asking whether a buffer is still busy).
Fusion's host side keeps up, which is why it is the fastest route in the
browser.

### OmacVM.app

The same wall as Parallels, in QEMU: its main loop thread runs at about 100 %,
88 % of it decoding Chrome's draws in virglrenderer and two thirds of the
thread inside Apple's OpenGL (`glDrawElementsInstanced`). Chrome's GPU
process in the guest is busy for the whole frame too, but 36 % of that is
`vp_notify`, the write that tells the virtual GPU there is work: with
Hypervisor.framework every exit of a virtual CPU takes QEMU's big lock first
(`hvf.c`: `bql_lock()` after `hv_vcpu_run`), and the main loop holds it while
it decodes. So the guest simply waits for the busy host thread; Mesa (24 %)
and Chrome/ANGLE (24 %) are the rest. gpu-native's asynchronous fences don't
change this (Aquarium 21.5 fps with its runtime v4 vs 22.5, same VM, bench
lock): the host thread is the limit, not the fences.

The command stream per draw (virglrenderer's `VREND_DEBUG=cmd`) is
`DRAW_VBO`, `SET_CONSTANT_BUFFER` and `SET_INDEX_BUFFER` every time, plus
sampler views, vertex buffers and sampler states every third draw.

### UTM

UTM was in the background during our runs (we may not take the focus), and
a backgrounded UTM runs slower: even Chrome's renderer needed 64 ms per frame
(8 ms on the other routes). A `sample` of UTM's QEMU shows why: its main
thread decodes the virgl commands (through ANGLE on Metal, not Apple's
OpenGL) about a third of the time, and the eight virtual CPUs spend about
60 % of theirs waiting for QEMU's big lock, which that thread holds. Its
numbers here only compare settings with each other; last night's
full-screen run gave 28.1 fps.

## What we tried

| Setting | Result |
|---|---|
| `--use-angle=gles` (ANGLE on OpenGL ES instead of desktop GL) | no gain: Parallels 24.9 vs 27.0, Fusion 38.6 vs 39.3, UTM 11.4 vs 12.0, OmacVM.app 22.9 vs 22.7; Basemark (Fusion) 2710 vs 2713. Pixels identical |
| `--use-gl=egl` (no ANGLE) | Chrome 154 turns the GPU off: never use it |
| `mesa_glthread` (Mesa's GL worker thread) | not available: Mesa enables it neither for `virgl` nor for `svga` (no worker thread even with `mesa_glthread=true`). Chrome also doesn't pass its environment on to its GPU process, so environment variables never reach the GL driver; only a drirc file would |
| Hyprland `render:direct_scanout = 1` | never engages: Hyprland reports it blocked by the software cursor and by overlays; composition is a few draws per frame anyway |
| Firefox 157 | already hardware WebRender on virgl (Parallels: Aquarium 18.1 fps vs Chrome's ~20 in the same window); nothing to switch on. Fusion keeps its prefs (finding 2 in troubleshooting) |

## Also measured

- Basemark Web 3.0 is too noisy for small differences: the same settings
  scored 2590 to 3102 on Parallels (one subtest, draw-call stress, ranged from
  728 to 10,209). Its JavaScript and DOM subtests swing as much as its WebGL
  ones, and part of its gap to the Mac is the CPU side of the browser, not the
  GPU (Speedometer: 67 % of the Mac).
- MotionMark scores 3.6 to 4.4 on Parallels, yet Chrome's frame timing is
  steady: `requestAnimationFrame` runs at 120 Hz (8.3 ms, 99th percentile
  8.5 ms) with 2,000 canvas arcs or 1,000 CSS-animated elements per frame.
  Why MotionMark can't settle is still open (finding 16).

## What would help (outside the guest)

- OmacVM.app: decoding outside QEMU's big lock would stop the guest's other
  virtual CPUs from waiting on it, but the decoding thread would still be the
  limit.
- OmacVM.app and Parallels: less work per draw on the host. Apple's OpenGL sets up
  textures, samplers and the pipeline again for every draw; a Metal backend
  (or Venus with a Vulkan driver on Metal, gpu-venus track) avoids that layer.
- Parallels: their renderer runs on one thread on top of Apple's OpenGL;
  only Parallels can change that.
