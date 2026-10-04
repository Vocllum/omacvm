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
- GLSL and limits that Apple's core profile accepts (one refused shader or GL
  error stopped the guest's whole GL context; the app drew black from then on):
  `patches/virgl-shader-core-glsl-version.patch` (GLSL 3.30, no extensions that
  are core), `virgl-shader-shadow-lod-extension.patch`,
  `virgl-shader-float-ops-integer-outputs.patch`, `virgl-blitter-core-glsl-version.patch`,
  `virgl-blitter-integer-msaa.patch`, `virgl-framebuffer-no-attachments.patch`,
  `virgl-caps-sampler-limit.patch`. Checked at build time by
  `Tests/virgl/test-core-glsl-shaders.c`, `test-blitter-shaders.c`,
  `test-empty-framebuffer.c` and `test-sampler-limit.c` on the Mac's OpenGL
  (docs/architecture/graphics.md, ADR 0018)

Build: `./build-qemu-gpu-runtime.sh` (about 70 seconds, needs only the Command
Line Tools). Output: `.build/qemu-gpu-runtime` and `.build/firmware`.

QEMU is GPL-2.0. Anyone who gets a built app must also be able to get this
source and the patches.
