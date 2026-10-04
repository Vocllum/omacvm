# 0017: Wait for GPU fences in short sleeps, not a spin

Status: accepted. Built on `gpu-native` (`virgl-darwin-fence-wait.patch`),
not merged. Builds on [0011](0011-async-fences.md).

## Context

With fences reported by `vrend-sync` ([0011](0011-async-fences.md)) the
thread calls `glClientWaitSync`. Apple's version spins on the CPU
(`gleTestSync` in a loop) until the GPU is done, so the thread kept a core
busy whenever the guest rendered: QEMU at 195% during glmark2 and 194%
during WebGL Aquarium (bench lock held), against about 160% with the 1 ms
poll. On a laptop that is battery and heat for nothing.

## Options

1. Keep the spin. Lowest latency, one core gone while anything renders.
2. Test the fence, then `nanosleep` between tests. macOS stretches short
   sleeps (timer coalescing): Aquarium fell to 7-15 fps. Rejected.
3. Test the fence, spin only for the first 100 us (most fences are done by
   then), then wait 50 us at a time with `mach_wait_until` on a thread with
   `THREAD_TIME_CONSTRAINT_POLICY` (computation 50 us, constraint 1 ms), so
   the scheduler wakes it when asked.
4. Signal from Metal (`MTLSharedEvent`): not reachable while vrend runs on
   Apple's OpenGL.

## Decision

Option 3, only on macOS. The fence still reports within about 50 us of
being done; nothing changes when the GPU is idle (the thread then blocks on
its fence list as before).

## Consequences

- QEMU's CPU, bench lock held: glmark2 195% -> 165%, Aquarium 194% -> 176%.
- Frame rates the same within noise: glmark2 short set 3351/3417 (spin) vs
  3361/3310; Aquarium 19.2-20.1 vs 19.6-20.4 fps.
- One time-constraint thread in QEMU. It runs for at most 50 us per wake, so
  it cannot starve the Mac.
- Going back is a rebuild without the patch; the app's `gpuSafeMode`
  ([0018](0018-gpu-safe-mode.md)) does not use the sync thread at all.
