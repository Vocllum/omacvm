/* The GLSL version the renderer asks for on a core profile.
 * Apple's core profile (GLSL 4.10) refuses "#version 130", extensions it does
 * not list (GL_ARB_draw_instanced) and floatBitsToInt() and friends below
 * GLSL 3.30. One refused shader used to stop the guest's whole GL context, so
 * every later draw of that app was black. Translates TGSI offline, checks the
 * text, then compiles it with the Mac's own OpenGL (a CGL core profile context,
 * no window) when one is available. */
#include <epoxy/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tgsi/tgsi_text.h"
#include "vrend/vrend_shader.h"
#include "vrend/vrend_strbuf.h"
#include "cgl-context.h"

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
   bool have_gl = cgl_init_current();
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

   /* A separable program (program pipelines) asks for explicit locations too;
    * they are core in GLSL 3.30. */
   memset(&key, 0, sizeof(key));
   failed |= convert("separable vertex shader",
                     "VERT\nPROPERTY SEPARABLE_PROGRAM 1\nDCL IN[0]\nDCL OUT[0], POSITION\n"
                     "DCL OUT[1], GENERIC[0]\nMOV OUT[0], IN[0]\nMOV OUT[1], IN[0]\nEND\n",
                     &key, "layout", NULL, have_gl);

   /* Integer render target written from a flat input. */
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("unsigned integer color output",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, NULL, NULL, have_gl);

   /* Results written straight to an integer render target (the guest's TGSI
    * folds floatBitsToUint(f(x)) or uint(i) into "OP OUT[n], ..."). Float results
    * must keep their bits: dEQP-GLES3 builtin_functions.precision.sqrt read 315
    * for sqrt(99463) (uint(1.0 / x)), and CMP, UCMP or SEQ into such an output
    * did not compile at all. Integer results are stored as they are, without a
    * detour through uintBitsToFloat() (uvec4(uintBitsToFloat(a + b)) converts). */
   static const struct {
      const char *op, *must, *must_not;
   } int_out[] = {
      {"RCP OUT[0].x, IN[0].xxxx", "floatBitsToUint(1.0/", NULL},
      {"RSQ OUT[0].x, IN[0].xxxx", "floatBitsToUint(inversesqrt", NULL},
      {"SQRT OUT[0], IN[0]", "floatBitsToUint(sqrt", NULL},
      {"DP3 OUT[0].x, IN[0], IN[0]", "floatBitsToUint(dot", NULL},
      {"MAD OUT[0], IN[0], IN[0], IN[0]", "floatBitsToUint(", NULL},
      {"POW OUT[0].x, IN[0].xxxx, IN[0].yyyy", "floatBitsToUint(pow", NULL},
      {"LRP OUT[0], IN[0], IN[0], IN[0]", "floatBitsToUint(mix", NULL},
      {"CMP OUT[0], IN[0], IN[0], IN[0]", "floatBitsToUint(mix", NULL},
      {"UCMP OUT[0], IN[0], IN[0], IN[0]", "floatBitsToUint(mix", NULL},
      {"SEQ OUT[0], IN[0], IN[0]", "floatBitsToUint(vec4(equal", NULL},
      {"I2F OUT[0], IN[0]", "floatBitsToUint(vec4(ivec4", NULL},
      {"U2F OUT[0], IN[0]", "floatBitsToUint(vec4(uvec4", NULL},
      {"UADD OUT[0], IN[0], IN[0]", "fsout_c0 = uvec4((uvec4(", "BitsToFloat"},
      {"AND OUT[0], IN[0], IN[0]", "fsout_c0 = uvec4((", "BitsToFloat"},
      {"NOT OUT[0], IN[0]", "fsout_c0 = uvec4((~", "BitsToFloat"},
      {"USEQ OUT[0], IN[0], IN[0]", "* uvec4(0xffffffff)", "BitsToFloat"},
      {"FSLT OUT[0], IN[0], IN[0]", "* uvec4(0xffffffff)", "BitsToFloat"},
      {"F2U OUT[0], IN[0]", "fsout_c0 = uvec4((uvec4(", "BitsToFloat"},
   };
   for (unsigned i = 0; i < sizeof(int_out) / sizeof(int_out[0]); i++) {
      char name[96], text[256];
      snprintf(name, sizeof(name), "%.*s into an integer color output",
               (int)strcspn(int_out[i].op, " "), int_out[i].op);
      snprintf(text, sizeof(text), "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n%s\nEND\n",
               int_out[i].op);
      memset(&key, 0, sizeof(key));
      key.fs.cbufs_unsigned_int_bitmask = 0x1;
      failed |= convert(name, text, &key, int_out[i].must, int_out[i].must_not, have_gl);
   }

   /* Query results (ints) into an integer output, and an integer op into
    * gl_SampleMask: stored as they are, not through intBitsToFloat() or
    * floatBitsToInt() (a vec assigned to a uvec, or floatBitsToInt(uint)). */
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("TXQ into an integer color output",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\nDCL SAMP[0]\n"
                     "DCL SVIEW[0], 2D, FLOAT\nTXQ OUT[0].xy, IN[0].xxxx, SAMP[0], 2D\nEND\n",
                     &key, "uvec2(textureSize", "BitsToFloat", have_gl);
   memset(&key, 0, sizeof(key));
   failed |= convert("AND into gl_SampleMask",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                     "DCL OUT[1], SAMPLEMASK\nMOV OUT[0], IN[0]\n"
                     "AND OUT[1].x, IN[0].xxxx, IN[0].yyyy\nEND\n",
                     &key, "gl_SampleMask[0] = int((", "BitsToFloat", have_gl);

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
   /* dEQP-GLES3.functional.shaders.texture_functions.texture.samplercubeshadow_bias_*:
    * texture(samplerCubeShadow, P, bias) is core GLSL 1.30 and ESSL 3.00; the
    * extension only adds lod forms and bias for array samplers. */
   failed |= convert("texture() with a bias on a shadow cube sampler",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL IN[1], GENERIC[1], PERSPECTIVE\n"
                     "DCL OUT[0], COLOR\nDCL SAMP[0]\nDCL SVIEW[0], SHADOWCUBE, FLOAT\nDCL TEMP[0]\n"
                     "TXB2 TEMP[0].x, IN[0], IN[1].xxxx, SAMP[0], SHADOWCUBE\n"
                     "MOV OUT[0], TEMP[0].xxxx\nEND\n",
                     &key, "texture(", "GL_EXT_texture_shadow_lod", have_gl);
   /* The compare value of a gather is no bias either (GLSL 4.00). */
   failed |= convert("textureGather on a shadow cube sampler",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\nDCL SAMP[0]\n"
                     "DCL SVIEW[0], SHADOWCUBE, FLOAT\nDCL TEMP[0]\nIMM[0] UINT32 {0, 0, 0, 0}\n"
                     "TG4 TEMP[0], IN[0], IMM[0].xxxx, SAMP[0], SHADOWCUBE\n"
                     "MOV OUT[0], TEMP[0]\nEND\n",
                     &key, "textureGather", "GL_EXT_texture_shadow_lod", have_gl);

   /* A plain float shader is unchanged apart from the version. */
   memset(&key, 0, sizeof(key));
   failed |= convert("float fragment shader",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, NULL, NULL, have_gl);
   return failed;
}
