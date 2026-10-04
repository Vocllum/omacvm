/* Drawing into a framebuffer without attachments, through the public renderer
 * API on the Mac's own OpenGL (CGL core contexts, no window).
 * The guest sends such a framebuffer when all its draw buffers are GL_NONE
 * (WebGL conformance: webgl-draw-buffers.html, conformance2/rendering/
 * draw-buffers.html). Apple's GL has no ARB_framebuffer_no_attachments and
 * answered the draw with GL_INVALID_FRAMEBUFFER_OPERATION, which stopped the
 * guest's whole context: Chrome drew nothing for the rest of its life.
 * The draws must be accepted and the context must keep working. */
#include <OpenGL/OpenGL.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h>
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

/* Gallium values the protocol uses (pipe/p_defines.h needs the whole tree). */
enum { TEST_SHADER_VERTEX = 0, TEST_SHADER_FRAGMENT = 1, TEST_PRIM_TRIANGLES = 4,
       TEST_TEXTURE_2D = 2, TEST_CLEAR_COLOR0 = 1 << 2 };

static CGLContextObj main_ctx;
static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

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

struct cmds {
   uint32_t dw[1024];
   unsigned n;
};

static void emit(struct cmds *c, uint32_t v)
{
   c->dw[c->n++] = v;
}

static void emit_shader(struct cmds *c, uint32_t handle, uint32_t type, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER, 5 + words));
   emit(c, handle);
   emit(c, type);
   emit(c, VIRGL_OBJ_SHADER_OFFSET_VAL(bytes));
   emit(c, 300);
   emit(c, 0);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], text, bytes);
   c->n += words;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SHADER, 0, 2));
   emit(c, handle);
   emit(c, type);
}

static void emit_draw(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, 0);                      /* start */
   emit(c, 3);                      /* count */
   emit(c, TEST_PRIM_TRIANGLES);
   for (int i = 0; i < VIRGL_DRAW_VBO_SIZE - 3; i++)
      emit(c, 0);
}

/* nr_cbufs colour buffers (0 = none), no depth buffer */
static void emit_framebuffer(struct cmds *c, uint32_t nr_cbufs, uint32_t surface)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0,
                      VIRGL_SET_FRAMEBUFFER_STATE_SIZE(nr_cbufs)));
   emit(c, nr_cbufs);
   emit(c, 0);
   for (uint32_t i = 0; i < nr_cbufs; i++)
      emit(c, surface);
}

static void emit_clear_red(struct cmds *c)
{
   union { float f; uint32_t u; } one = { 1.0f };
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(c, TEST_CLEAR_COLOR0);
   emit(c, one.u);
   emit(c, 0);
   emit(c, 0);
   emit(c, one.u);
   emit(c, 0);                      /* depth (double) */
   emit(c, 0);
   emit(c, 0);                      /* stencil */
}

static int submit(int ctx_id, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx_id, c->n);
   c->n = 0;
   return r;
}

static const char *vs_text =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

static const char *fs_text =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

int main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   main_ctx = new_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }
   check(!virgl_renderer_context_create(1, 6, "chrome"), "context");

   /* a colour buffer, to switch to and from the empty framebuffer */
   struct virgl_renderer_resource_create_args args = {
      .handle = 5, .target = TEST_TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 16, .height = 16, .depth = 1,
      .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "colour buffer");
   virgl_renderer_ctx_attach_resource(1, 5);

   struct cmds c = { .n = 0 };
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(&c, 6);                     /* surface handle */
   emit(&c, 5);                     /* resource */
   emit(&c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(&c, 0);                     /* level */
   emit(&c, 0);                     /* layers */
   emit_shader(&c, 10, TEST_SHADER_VERTEX, vs_text);
   emit_shader(&c, 11, TEST_SHADER_FRAGMENT, fs_text);
   check(submit(1, &c) == 0, "shaders and surface");

   emit_framebuffer(&c, 0, 0);
   emit_draw(&c);
   emit_draw(&c);
   check(submit(1, &c) == 0, "draws into a framebuffer without attachments are accepted");

   emit_framebuffer(&c, 1, 6);
   emit_draw(&c);
   emit_framebuffer(&c, 0, 0);
   emit_draw(&c);
   emit_framebuffer(&c, 1, 6);
   emit_draw(&c);
   check(submit(1, &c) == 0, "switching between a colour buffer and none keeps working");

   /* Back on the colour buffer, nothing of the stand-in for "no attachments"
    * may remain: a clear covers the whole 16x16 buffer. */
   emit_clear_red(&c);
   check(submit(1, &c) == 0, "clear");
   uint32_t pixels[16 * 16] = {0};
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   check(!virgl_renderer_transfer_read_iov(5, 1, 0, 16 * 4, 0, &box, 0, &iov, 1) &&
         pixels[0] == 0xff0000ff && pixels[16 * 16 - 1] == 0xff0000ff,
         "the colour buffer is cleared corner to corner");

   virgl_renderer_ctx_detach_resource(1, 5);
   virgl_renderer_context_destroy(1);
   virgl_renderer_resource_unref(5);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "empty framebuffer: FAILED" : "empty framebuffer: all checks passed");
   return failures != 0;
}
