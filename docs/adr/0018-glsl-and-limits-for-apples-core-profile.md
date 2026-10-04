# 0018: GLSL and limits that Apple's core profile accepts

## Context

virglrenderer turns the guest's TGSI into GLSL and runs it on Apple's OpenGL 4.1
core profile. Upstream assumes a Linux driver: it writes `#version 130`/`140`,
asks for ARB extensions that are core in newer GLSL, reports 32 samplers per
stage and treats every host GL error as fatal (`check-gl-errors`). Apple refuses
GLSL 1.30, floatBitsToInt() below 3.30, extensions it does not list
(`GL_ARB_draw_instanced`, `GL_EXT_texture_shadow_lod`), more than 16 samplers per
stage and a framebuffer without attachments. Each refusal put the guest's whole
virgl context in error: dEQP-GLES3 in one process passed 455 of 896 cases (812 of
869 when restarted after each failure), Chrome drew black after its first bad
page (WebGL 1: 430 of 787 pages in one Chrome, 776 isolated).

## Options

1. Make host failures non-fatal everywhere (skip what the host refuses, build with
   `-Dcheck-gl-errors=false`). Hides the symptom, the refused work is still lost
   (black where the app drew), and every new gap stays invisible.
2. Fix the translation and the reported limits where they disagree with the Mac,
   one patch per gap, each with a build-time test on the Mac's own GL.
3. Rewrite emitted GLSL text before compiling (like the tap's
   `GL_EXT_shader_texture_lod` strip). Fragile, per symptom.

## Decision

Option 2, measured with the conformance harness without isolation (one dEQP
process, one Chrome):

- core profile shaders are at least `#version 330` (Apple supports 4.10), and no
  `#extension` line asks for what that version has in core;
- the blitter's shaders take their version from the blit context (4.00 on the Mac);
- shadow lookups ask for `GL_EXT_texture_shadow_lod` only for what it adds (lod
  forms, bias on array samplers);
- float math written to an integer output keeps its bits (floatBitsToUint),
  an upstream bug that also hits Linux hosts;
- a guest framebuffer without attachments gets a 1x1 depth stand-in on hosts
  without `ARB_framebuffer_no_attachments`;
- the reported sampler limit is the host's.

Option 1 stays useful as a safety net and is gpu-robust's track (ADR 0016: a
refused shader skips its draws, a lost context is reported to the guest).

## Consequences

- dEQP and WebGL pass rates in one process match the isolated ones (numbers in
  the graphics architecture document, "Shaders and limits on Apple's GL"). The
  whole dEQP-GLES3 list in one process: 21140 passed before, 42832 after.
- No setting: these are fixes of the translation, not a second path, so there
  is nothing to fall back to. GPU safe mode keeps them. Gaps not found yet are
  caught by gpu-robust's containment.
- GLSL 3.30 instead of 1.40/1.50 changes nothing for the guest: the translation
  writes no construct that 3.30 core removed; the build tests compile it.
- Occlusion queries in a framebuffer whose draw buffers are all GL_NONE count at
  most one pixel (the stand-in is 1x1); before, the context died.
- Guests see 16 samplers per stage instead of 32 (GLES 3.0 needs 16).
- Linux hosts: unchanged except the GLSL version on core profiles (3.30 where
  supported), the blitter version and the integer-output bit cast; all are
  spec-valid there too.
- What still fails in one process also fails isolated: real gaps (cube map
  filtering, one blit format conversion, WebGL pages listed in the architecture
  document), not a stopped context.
