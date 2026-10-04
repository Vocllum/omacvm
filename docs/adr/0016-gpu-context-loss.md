# 0016: A refused shader skips its draws; a lost context tells the guest

Status: accepted. Built on `gpu-robust` (`virgl-shader-failure-skip-draws.patch`,
`virgl-context-loss-report.patch`, guest `src/app/guest/mesa/`). The host part is
on by default; the guest Mesa is built and tested, not installed by default.

## Context

virglrenderer stops a guest context for good on any error it calls fatal
(`in_error`): a malformed command, an unknown handle, and also a shader that the
Mac's OpenGL refuses although the guest's Mesa accepted it. Only draws, clears and
blits of that context stop; nothing tells the guest. Stock Mesa's virgl driver has
no reset query at all, so the app keeps drawing into nothing. That is how the
Basemark Web 3.0 hang looked (finding 23): one refused Chrome shader, then
Chrome's GPU process drew blank frames forever and the tab froze.

Shader refusals are the common case on the Mac: TGSI to GLSL translation gaps
(the Basemark one) and Apple's limits (4096 uniform components, see the build
test). Real protocol errors mean a guest driver bug or a hostile guest.

## Options

1. Keep upstream: the context dies silently (today).
2. Treat a refused shader like a native driver: skip the draws that need it,
   keep the context, log it. Nothing in the guest has to change.
3. Report a context loss the guest understands. virtio-gpu has no channel for
   it: QEMU ignores `virgl_renderer_submit_cmd`'s result, the kernel only logs
   error responses, Mesa never sees them. Ways to add one:
   a. a new virgl command that names a guest-memory buffer; the host writes
      "guilty" there (like query results); Mesa's virgl driver answers
      `get_device_reset_status` from it. Needs a patched guest Mesa.
   b. a kernel change (fence errors, a new ioctl): a patched guest kernel, more
      moving parts than (a).
   c. make the guest app crash or hang so Chrome's watchdog restarts its GPU
      process: no clean way from the host, and a hang is what we want to avoid.
4. Revive a lost context (clear `in_error`): the guest's state may be
   inconsistent after a refused command; unsafe.

## Decision

2 for refused shaders, by default (`OMACVM_VIRGL_SHADER_FAILURES=lose` keeps
upstream behaviour), and 3a for every loss that remains: the host side ships in
the runtime (an unused buffer costs nothing), the guest side is a Mesa patch
built into `/opt/omacvm-mesa`.

Chrome's ANGLE creates its native GL context without reset notification, so
the reset status alone never reaches it. For such contexts the guest Mesa ends
the app at the next flush (abort, like Mesa's venus); Chrome restarts its GPU
process and the WebGL page gets `webglcontextlost` and `webglcontextrestored`.
`VIRGL_KEEP_LOST_CONTEXT=1` keeps an app running instead.

Venus already has its channel: a fatal decoder error sets
`VK_RING_STATUS_FATAL_BIT_MESA` in the ring's shared memory, and the guest's
Mesa aborts the app on it (Mesa's choice, not `VK_ERROR_DEVICE_LOST`). But the
proxy dropped the fences of a context the render server had ended, so the app
hung in `vkWaitForFences` before it ever looked at the ring.
`virgl-venus-lost-context-fences.patch` signals them; the app then ends within
seconds. `VK_ERROR_DEVICE_LOST` instead of abort() would need a change in the
guest's Mesa venus (not done: upstream chose abort).

## Consequences

- A WebGL page with one bad shader keeps running; only that object is missing.
  Chrome needs no help (1978 of 1978 frames read back right after the refusal,
  `tests/graphics/context-loss.sh --expect contain`).
- A lost context with the guest Mesa: Chrome's page gets its context back in
  about 1 s, on the GPU (`--expect recover`). Without the guest Mesa: the app
  draws nothing until it is restarted (`--expect dead`), as before.
- Logging: at most three lines per context for refused shaders (the first with
  the GLSL), one "dropping rendering" line, one "context N is lost" line.
- With the guest Mesa, a robust context answers `glGetGraphicsResetStatus` with
  `GL_GUILTY_CONTEXT_RESET` on the frame it was lost (`gl-lost`), and Mesa offers
  `EXT/KHR_robustness` and `EGL_EXT_create_context_robustness` on virgl. KHR
  robustness without robust buffer access (Apple's GL 4.1 lacks
  ARB_robust_buffer_access_behavior) is allowed by the spec. Robust buffer
  access stays off in the extension strings and in the context flags: an app
  that asks for a robust access context gets `EGL_BAD_CONFIG`/`EGL_BAD_MATCH`
  from EGL (Mesa's own check) and a refused context from GLX (the guest patch
  adds the same check to the dri frontend), never a context with
  `GL_CONTEXT_FLAG_ROBUST_ACCESS_BIT` and unbounded reads. ANGLE keeps its own
  bounds checks.
- Ending a non-robust app is the price of recovery: if the compositor's own
  context were lost, Hyprland would end too (before, the desktop froze). Losses
  are rare now that refused shaders no longer lose the context; they mean a
  guest driver bug or a hostile command stream.
- Protocol: command `VIRGL_CCMD_SET_RESET_STATUS_BUFFER` (next free number) and
  capset bit `1 << 30`. A stock guest never sends the command; a newer upstream
  that assigns the same numbers would need a rebase of both sides.
- Shipping the guest Mesa (a package, or LD_LIBRARY_PATH for chosen apps) is a
  separate decision; it must follow Arch's Mesa version.
