/* The sampler limit the renderer reports to the guest must not exceed the
 * host's. The guest's Mesa takes caps.v2.max_texture_samplers as every
 * stage's limit (GL_MAX_TEXTURE_IMAGE_UNITS). It was always 32; the Mac has
 * 16 per stage, so a guest program with more samplers (dEQP-GLES3 uses the
 * reported limit) failed to link on the Mac and stopped the guest context.
 * Public renderer API on the Mac's own OpenGL (CGL core context, no window). */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include "virglrenderer.h"
#include "virgl_hw.h"

static CGLContextObj main_ctx;

static void write_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   (void)fence;
}

static CGLContextObj new_context(CGLContextObj share)
{
   CGLPixelFormatAttribute attrs[] = {
      kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, 0
   };
   CGLPixelFormatObj pix = NULL;
   CGLContextObj ctx = NULL;
   GLint n = 0;
   if (CGLChoosePixelFormat(attrs, &pix, &n) || !pix)
      return NULL;
   CGLCreateContext(pix, share, &ctx);
   CGLReleasePixelFormat(pix);
   return ctx;
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   return new_context(param->shared ? main_ctx : NULL);
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   CGLDestroyContext(ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   (void)scanout;
   return CGLSetCurrentContext(ctx) ? -1 : 0;
}

static struct virgl_renderer_callbacks callbacks = {
   .version = 1,
   .write_fence = write_fence,
   .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context,
   .make_current = make_current,
};

int main(void)
{
   main_ctx = new_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   GLint frag = 0, vert = 0;
   glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &frag);
   glGetIntegerv(GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS, &vert);

   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }
   uint32_t max_ver = 0, max_size = 0;
   virgl_renderer_get_cap_set(2 /* VIRTIO_GPU_CAPSET_VIRGL2 */, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2 /* VIRTIO_GPU_CAPSET_VIRGL2 */, max_ver, caps);
   uint32_t reported = caps->v2.max_texture_samplers;
   virgl_renderer_cleanup(&cookie);
   free(caps);

   int ok = reported >= 16 && (int)reported <= frag && (int)reported <= vert;
   printf("%s: samplers per stage: reported %u, host fragment %d, vertex %d\n",
          ok ? "ok" : "FAIL", reported, frag, vert);
   return !ok;
}
