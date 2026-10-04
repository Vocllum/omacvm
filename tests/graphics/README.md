# Graphics conformance and soak

One command per suite. Each runs against a running app test VM and writes a JSON summary
(plus the raw per-case `.jsonl` and, for the soak, an artifacts folder) under `results/`.
Standards section 5: run these before and after every graphics change.

## The VM

```bash
./vm.sh start            # VM="OmacVM T-conf" RT=<runtime dir> PORT=52291 CPUS=6 MEM_MB=8192
./vm.sh stop
```

`vm.sh` starts QEMU like the app does (virtio-gpu-gl, cocoa GL window). `RT` picks the runtime
(default: the rc tree, `omacvm-rc/app/runtime/.build/qemu-gpu-runtime`); `GPUX` adds virtio-gpu
options, e.g. `GPUX=",blob=true,venus=true,hostmem=4G"` with a Venus runtime. The VM needs the
desktop user logged in (autologin), Chrome, glmark2, vkmark, mpv, ffmpeg.
`vm.sh ssh CMD` and `vm.sh session CMD` (as the desktop user, in the Hyprland session) are the
helpers the suites use.

## Suites

| Command | What | Time |
|---|---|---|
| `./deqp.sh gles2 [--filter RE] [--stride N]` | dEQP GLES2 mustpass (VK-GL-CTS), pbuffer 256x256 | full: ~1 h; `--stride 20`: minutes |
| `./deqp.sh gles3 [...]` | dEQP GLES3 mustpass | full: hours; use a filter or stride |
| `./deqp.sh vk [--env "VK_ICD_FILENAMES=..."]` | Vulkan CTS `vk-default` list, for Venus | use a filter (e.g. `^dEQP-VK\.(api\|memory)\.`) |
| `./webgl.sh --version 1.0.4 [--filter RE]` | Khronos WebGL conformance 2.0.0 suite, WebGL 1 pages, Chrome in the guest session | full: ~15-30 min |
| `./webgl.sh --version 2.0.0 --filter '^conformance2/'` | same, WebGL 2 pages | longer |
| `./soak.sh [--minutes 30] [--vk]` | glmark2 (or vkmark) loop + Chrome WebGL page + mpv 1080p60 loop, with hang detection | 30 min |

dEQP has no Arch Linux ARM package: build it once in the guest with `guest/build-cts.sh`
(copied to `/opt/vk-gl-cts`, ~15 min for GLES, much longer for `deqp-vk`). It records the CTS
commit in `/opt/vk-gl-cts/commit`; pass a tag or commit (`build-cts.sh <ref>`) to pin it.
`guest/deqp-run.py` restarts dEQP after a crash or watchdog timeout and records the case.

WebGL: the guest serves `conformance-suites/2.0.0` (sparse clone of KhronosGroup/WebGL; commit in
the result) and `guest/webgl-runner.html`, which loads each page in an iframe and receives results
through `webglTestHarness`, the hook the official harness uses. It is not headless Chrome on
purpose: headless takes SwiftShader, the session Chrome takes the real virgl/ANGLE path. The
result records the unmasked renderer so a software fallback shows.

## Soak hang detection

Every `--interval` (15 s):
- guest heartbeat over SSH; two misses in a row = hang;
- virtio-gpu fences from guest debugfs (`virtio-gpu-irq-fence`: signalled, emitted); signalled
  not moving for 45 s while behind emitted = stuck fence;
- progress of each load (glmark2 loops, WebGL frames posted by the page, mpv frame number);
  nothing moving for 90 s = stall;
- QEMU CPU% and RSS (memory growth), guest MemAvailable.

On a failure it takes `sample` of QEMU, and always saves the new QEMU log lines, guest dmesg,
glmark2 scores and every sample (`samples.jsonl`) next to the JSON.

## Result fields

- dEQP: `status` counts (Pass, Fail, NotSupported, Crash, ...), `pass_rate` = passed / (ran and
  not NotSupported), `failures` (first 500 cases), CTS commit, renderer.
- WebGL: pages pass/fail/timeout, subtests pass/fail, `subtest_pass_rate`, failed pages with the
  first messages, renderer, Chrome version.
- Soak: `verdict`, `reason`, loads' progress, fences signalled, QEMU RSS first/last/max,
  guest MemAvailable first/last.

These are correctness and stability results; performance numbers go through the benchmark
harness under the bench lock (standards section 10).
