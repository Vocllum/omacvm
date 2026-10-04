# Runtime

QEMU for OmacVM, built from source. The build scripts and patches come from
[try-omarchy](https://github.com/omacom/try-omarchy) (MIT, `LICENSE.try-omarchy`),
commit 82927e9. Changes here:

- scratch files go to `.build/tmp` instead of `/private/tmp`
- `patches/omacvm-cocoa-identity.patch`: the app name and icon come from the
  launcher (`OMACVM_PRODUCT_NAME`, `OMACVM_ICON`)
- QEMU's edk2 UEFI firmware is kept in `.build/firmware`, so an installed
  system boots through GRUB
- `patches/virgl-texture-integer-samplers.patch`: shaders that read integer
  textures (`usampler2D`) compile on the Mac's OpenGL. Before, Apple's
  compiler refused them and the guest's GL context stopped for good: Chrome's
  GPU process hung (Basemark Web 3.0 at test 5). The build checks it with
  `Tests/virgl/test-integer-sampler-shader.c`, which compiles the generated
  GLSL with the Mac's OpenGL

- `patches/virgl-shader-failure-skip-draws.patch`: a shader the Mac's OpenGL
  refuses (although the guest's Mesa accepted it) skips the draws that need it;
  the guest's context keeps running. `OMACVM_VIRGL_SHADER_FAILURES=lose` goes
  back to upstream (the whole context stops)
- `patches/virgl-context-loss-report.patch`: a context that is lost anyway tells
  the guest through a status buffer the guest's Mesa names
  (`src/app/guest/mesa/`), and the log says so once
- `patches/virgl-shader-variant-null-checks.patch`,
  `patches/virgl-shader-size-limits.patch`: a guest command stream could crash
  QEMU (NULL variant) or ask for 4 GiB per shader; found by
  `Tests/virgl/fuzz-cmd-stream.sh`
- `patches/virgl-core-instance-id.patch`: shaders that read `gl_InstanceID`
  (instanced WebGL) asked for `GL_ARB_draw_instanced`, which Apple's core
  profile refuses; checked by `Tests/virgl/test-integer-sampler-shader.c`
- `patches/virgl-transform-feedback-end.patch`: transform feedback ends with
  the program it began with bound; with none bound Apple's GL crashed QEMU
  (dEQP and WebGL 2 transform feedback tests); checked by
  `Tests/virgl/test-transform-feedback.c`
- `patches/virgl-venus-lost-context-fences.patch`: a Venus context the render
  server ended signals its fences, so the guest app ends instead of hanging
- `patches/virgl-test-shader-fault.patch`: test runtimes only
  (`OMACVM_RUNTIME_TEST_HOOKS=1 ./build-qemu-gpu-runtime.sh`): refuse shaders
  whose GLSL contains `OMACVM_VIRGL_TEST_FAIL_GLSL`. Such a runtime is marked
  (`.build/qemu-gpu-runtime.test-hooks`) and `build-app.sh` rebuilds instead of
  shipping it. `Tests/virgl/test-context-loss.c` runs in every build

Build: `./build-qemu-gpu-runtime.sh` (about 70 seconds, needs only the Command
Line Tools). Output: `.build/qemu-gpu-runtime` and `.build/firmware`.

QEMU is GPL-2.0. Anyone who gets a built app must also be able to get this
source and the patches.
