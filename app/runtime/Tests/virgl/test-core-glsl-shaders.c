/* The GLSL version the renderer asks for on a core profile.
 * Apple's core profile (GLSL 4.10) refuses "#version 130", extensions it does
 * not list (GL_ARB_draw_instanced) and floatBitsToInt() and friends below
 * GLSL 3.30. One refused shader used to stop the guest's whole GL context, so
 * every later draw of that app was black. Translates TGSI offline, checks the
 * text, then compiles it with the Mac's own OpenGL (a CGL core profile context,
 * no window) when one is available. */
#include <dlfcn.h>
#include <epoxy/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tgsi/tgsi_text.h"
#include "vrend/vrend_shader.h"
#include "vrend/vrend_strbuf.h"

typedef int (*choose_fn)(const int *, void **, int *);
typedef int (*create_fn)(void *, void *, void **);
typedef int (*current_fn)(void *);

/* A core profile context like the renderer's (OpenGL 4.1 on the Mac). */
static bool gl_init(void)
{
   void *cgl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY);
   if (!cgl)
      return false;
   choose_fn choose = (choose_fn)dlsym(cgl, "CGLChoosePixelFormat");
   create_fn create = (create_fn)dlsym(cgl, "CGLCreateContext");
   current_fn current = (current_fn)dlsym(cgl, "CGLSetCurrentContext");
   if (!choose || !create || !current)
      return false;
   const int attrs[] = {99 /* kCGLPFAOpenGLProfile */, 0x3200 /* 3.2 core and later */, 0};
   void *pix = NULL, *ctx = NULL;
   int n = 0;
   return !choose(attrs, &pix, &n) && pix && !create(pix, NULL, &ctx) && ctx && !current(ctx);
}

static bool gl_compiles(const char *name, GLenum type, const char *glsl)
{
   GLuint s = glCreateShader(type);
   GLint ok = 0;
   glShaderSource(s, 1, &glsl, NULL);
   glCompileShader(s);
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[2048] = {0};
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      printf("FAIL: %s does not compile:\n%s\n%s\n", name, log, glsl);
   }
   glDeleteShader(s);
   return ok;
}

static int convert(const char *name, const char *text, const struct vrend_shader_key *key,
                   const char *must, const char *must_not, bool have_gl)
{
   struct tgsi_token tokens[512];
   struct vrend_shader_cfg cfg = {
      .glsl_version = 410,
      .max_draw_buffers = 8,
      .use_core_profile = 1,
      .use_explicit_locations = 1,
      .has_gpu_shader5 = 1,
      .use_integer = 1,
   };
   struct vrend_shader_info info = {0};
   struct vrend_variable_shader_info variable_info = {0};
   struct vrend_strarray output = {0};
   if (!tgsi_text_translate(text, tokens, 512)) {
      printf("FAIL: %s TGSI parsing\n", name);
      return 1;
   }
   if (!strarray_alloc(&output, 3) ||
       !vrend_convert_shader(NULL, &cfg, tokens, 0, key, &info, &variable_info, &output)) {
      printf("FAIL: %s translation\n", name);
      return 1;
   }
   char glsl[32768] = {0};
   for (int i = 0; i < output.num_strings; i++)
      strncat(glsl, output.strings[i].buf, sizeof(glsl) - strlen(glsl) - 1);
   strarray_free(&output, true);
   /* Every core profile shader: GLSL 3.30, no extension that 3.30 has in core. */
   if (strncmp(glsl, "#version 330\n", 13) || strstr(glsl, "GL_ARB_shader_bit_encoding") ||
       strstr(glsl, "GL_ARB_explicit_attrib_location") || (must && !strstr(glsl, must)) ||
       (must_not && strstr(glsl, must_not))) {
      printf("FAIL: %s:\n%s\n", name, glsl);
      return 1;
   }
   GLenum type = strncmp(text, "VERT", 4) ? GL_FRAGMENT_SHADER : GL_VERTEX_SHADER;
   if (have_gl && !gl_compiles(name, type, glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
}

int main(void)
{
   bool have_gl = gl_init();
   if (!have_gl)
      puts("SKIP: no OpenGL context here; checking the GLSL text only");
   int failed = 0;
   struct vrend_shader_key key;

   /* dEQP-GLES3.functional.shaders.precision.int.*: integer vertex attributes
    * passed on as they are. The copy goes through intBitsToFloat() without
    * SHADER_REQ_INTS, which gave "#version 140" and a refused shader. */
   memset(&key, 0, sizeof(key));
   key.vs.attrib_signed_int_bitmask = 0x6;
   failed |= convert("signed integer attributes passed on",
                     "VERT\nDCL IN[0]\nDCL IN[1]\nDCL IN[2]\nDCL OUT[0], POSITION\n"
                     "DCL OUT[1], GENERIC[0]\nDCL OUT[2], GENERIC[1]\n"
                     "MOV OUT[0], IN[0]\nMOV OUT[1], IN[1]\nMOV OUT[2], IN[2]\nEND\n",
                     &key, "intBitsToFloat", NULL, have_gl);
   memset(&key, 0, sizeof(key));
   key.vs.attrib_unsigned_int_bitmask = 0x2;
   failed |= convert("unsigned integer attribute passed on",
                     "VERT\nDCL IN[0]\nDCL IN[1]\nDCL OUT[0], POSITION\nDCL OUT[1], GENERIC[0]\n"
                     "MOV OUT[0], IN[0]\nMOV OUT[1], IN[1]\nEND\n",
                     &key, "uintBitsToFloat", NULL, have_gl);

   /* Integer render target written from a flat input. */
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("unsigned integer color output",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, NULL, NULL, have_gl);

   /* dEQP-GLES3.functional.shaders.builtin_functions.precision.*: the guest
    * writes floatBitsToUint(sqrt(x)) to an integer render target; its TGSI
    * puts the float math straight into the output. The bits must be kept
    * (floatBitsToUint), not the value converted (uint(1.0 / x) gave 315 for
    * sqrt(99463) instead of the float's bits). */
   static const struct {
      const char *name, *op;
   } float_ops[] = {
      {"RCP into an integer color output", "RCP OUT[0].x, IN[0].xxxx\n"},
      {"RSQ into an integer color output", "RSQ OUT[0].x, IN[0].xxxx\n"},
      {"SQRT into an integer color output", "SQRT OUT[0], IN[0]\n"},
      {"DP3 into an integer color output", "DP3 OUT[0].x, IN[0], IN[0]\n"},
      {"MAD into an integer color output", "MAD OUT[0], IN[0], IN[0], IN[0]\n"},
      {"POW into an integer color output", "POW OUT[0].x, IN[0].xxxx, IN[0].yyyy\n"},
      {"LRP into an integer color output", "LRP OUT[0], IN[0], IN[0], IN[0]\n"},
   };
   for (unsigned i = 0; i < sizeof(float_ops) / sizeof(float_ops[0]); i++) {
      char text[256];
      snprintf(text, sizeof(text), "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n%sEND\n",
               float_ops[i].op);
      memset(&key, 0, sizeof(key));
      key.fs.cbufs_unsigned_int_bitmask = 0x1;
      failed |= convert(float_ops[i].name, text, &key, "floatBitsToUint(", NULL, have_gl);
   }

   /* Instanced drawing (WebGL through ANGLE): gl_InstanceID is core GLSL;
    * Apple's core profile refuses "#extension GL_ARB_draw_instanced". */
   memset(&key, 0, sizeof(key));
   failed |= convert("vertex shader reading gl_InstanceID",
                     "VERT\nDCL IN[0]\nDCL SV[0], INSTANCEID\nDCL OUT[0], POSITION\n"
                     "DCL TEMP[0]\nI2F TEMP[0].x, SV[0].xxxx\nADD OUT[0], IN[0], TEMP[0].xxxx\nEND\n",
                     &key, "gl_InstanceID", "GL_ARB_draw_instanced", have_gl);

   /* dEQP-GLES3.functional.shaders.texture_functions.texturegradoffset.*:
    * textureGrad() on shadow array and cube samplers is core GLSL, but the
    * renderer asked for GL_EXT_texture_shadow_lod, which the Mac lacks. */
   memset(&key, 0, sizeof(key));
   failed |= convert("textureGradOffset on a shadow array sampler",
                     "VERT\nDCL IN[0]\nDCL IN[1]\nDCL IN[2]\nDCL IN[3]\nDCL OUT[0], POSITION\n"
                     "DCL OUT[1].x, GENERIC[0]\nDCL SAMP[0]\nDCL SVIEW[0], SHADOW2D_ARRAY, FLOAT\n"
                     "IMM[0] UINT32 {4294967288, 7, 0, 0}\n"
                     "TXD OUT[1].x, IN[1], IN[2].xyyy, IN[3].xyyy, SAMP[0], SHADOW2D_ARRAY, IMM[0].xyx\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, "textureGradOffset", "GL_EXT_texture_shadow_lod", have_gl);
   failed |= convert("textureGrad on a shadow cube sampler",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\nDCL SAMP[0]\n"
                     "DCL SVIEW[0], SHADOWCUBE, FLOAT\nDCL TEMP[0]\n"
                     "TXD TEMP[0].x, IN[0], IN[0].xyzz, IN[0].zyxx, SAMP[0], SHADOWCUBE\n"
                     "MOV OUT[0], TEMP[0].xxxx\nEND\n",
                     &key, "textureGrad", "GL_EXT_texture_shadow_lod", have_gl);

   /* A plain float shader is unchanged apart from the version. */
   memset(&key, 0, sizeof(key));
   failed |= convert("float fragment shader",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, NULL, NULL, have_gl);
   return failed;
}
