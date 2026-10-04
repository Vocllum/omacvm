/* gl-lost: what a GLES app sees when the host loses its virgl context.
 * Surfaceless EGL, a context with EGL_LOSE_CONTEXT_ON_RESET_EXT when the driver
 * offers EGL_EXT_create_context_robustness. Draws into an FBO and reads it back every
 * frame; from frame 30 on it also draws with a shader whose constant 4242.25 a test
 * build of the host refuses (OMACVM_VIRGL_TEST_FAIL_GLSL=1166316032, its bits).
 * One JSON line per frame: readback ok?, glGetGraphicsResetStatusEXT.
 * Build: cc -O2 -o gl-lost gl-lost.c -lEGL -lGLESv2 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static GLuint program(const char *vs, const char *fs)
{
   GLuint p = glCreateProgram();
   const char *src[2] = { vs, fs };
   GLenum type[2] = { GL_VERTEX_SHADER, GL_FRAGMENT_SHADER };
   for (int i = 0; i < 2; i++) {
      GLuint s = glCreateShader(type[i]);
      glShaderSource(s, 1, &src[i], NULL);
      glCompileShader(s);
      glAttachShader(p, s);
   }
   glBindAttribLocation(p, 0, "pos");
   glLinkProgram(p);
   return p;
}

static double now(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
   int frames = argc > 1 ? atoi(argv[1]) : 120;
   setvbuf(stdout, NULL, _IOLBF, 0);
   EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
   if (!eglInitialize(dpy, NULL, NULL)) {
      printf("{\"error\":\"eglInitialize\"}\n");
      return 2;
   }
   const char *exts = eglQueryString(dpy, EGL_EXTENSIONS);
   int robust = exts && strstr(exts, "EGL_EXT_create_context_robustness");
   eglBindAPI(EGL_OPENGL_ES_API);
   EGLint attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2,
                      robust ? EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT : EGL_NONE,
                      EGL_LOSE_CONTEXT_ON_RESET_EXT, EGL_NONE };
   EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attrs);
   if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      printf("{\"error\":\"context\"}\n");
      return 2;
   }
   PFNGLGETGRAPHICSRESETSTATUSEXTPROC reset_status =
      (PFNGLGETGRAPHICSRESETSTATUSEXTPROC)eglGetProcAddress("glGetGraphicsResetStatusEXT");
   printf("{\"renderer\":\"%s\",\"robust_context\":%d,\"reset_query\":%d}\n",
          glGetString(GL_RENDERER), robust, reset_status != NULL);

   GLuint tex, fbo, buf;
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
   glViewport(0, 0, 64, 64);
   const float quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
   glGenBuffers(1, &buf);
   glBindBuffer(GL_ARRAY_BUFFER, buf);
   glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
   glEnableVertexAttribArray(0);
   glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
   const char *vs = "attribute vec2 pos; varying vec2 v; void main(){ v = pos * 0.5 + 0.5; gl_Position = vec4(pos * 0.5, 0.0, 1.0); }";
   GLuint good = program(vs, "precision mediump float; varying vec2 v; void main(){ gl_FragColor = vec4(0.2, v.x, v.y, 1.0); }");
   GLuint poison = 0;

   double t0 = now();
   int ok = 0, bad = 0;
   GLenum first_status = GL_NO_ERROR;
   int first_status_frame = -1;
   for (int f = 0; f < frames; f++) {
      int g = 40 + f % 200;
      glClearColor(0, g / 255.0f, 0, 1);
      glClear(GL_COLOR_BUFFER_BIT);
      glUseProgram(good);
      glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
      if (f >= 30 && first_status == GL_NO_ERROR) {
         if (!poison)
            poison = program(vs, "precision highp float; varying vec2 v; void main(){ gl_FragColor = vec4(min(v.x * 4242.25, 1.0), 0.0, v.y, 1.0); }");
         glUseProgram(poison);
         glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
      }
      unsigned char px[4] = { 0 };
      glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
      int match = abs(px[1] - g) <= 1 && px[0] == 0;
      ok += match;
      bad += !match;
      GLenum st = reset_status ? reset_status() : GL_NO_ERROR;
      if (st != GL_NO_ERROR && first_status == GL_NO_ERROR) {
         first_status = st;
         first_status_frame = f;
      }
      printf("{\"frame\":%d,\"t\":%.3f,\"readback_ok\":%d,\"reset_status\":\"0x%04x\"}\n",
             f, now() - t0, match, st);
   }
   printf("{\"done\":true,\"ok\":%d,\"bad\":%d,\"reset_status\":\"0x%04x\",\"reset_frame\":%d}\n",
          ok, bad, first_status, first_status_frame);
   return 0;
}
