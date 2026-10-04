/* alt-scanout W1 H1 W2 H2 SECONDS: switch the scanout between two framebuffer
 * sizes as fast as the host takes it (a guest trying to make the host
 * reallocate its present surfaces on every frame). Run as root on a text VT. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static uint32_t fb(int fd, uint32_t w, uint32_t h, uint32_t color)
{
   struct drm_mode_create_dumb c = { .width = w, .height = h, .bpp = 32 };
   if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &c)) { perror("create dumb"); exit(1); }
   struct drm_mode_map_dumb m = { .handle = c.handle };
   drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &m);
   uint32_t *p = mmap(0, c.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, m.offset);
   for (uint64_t i = 0; i < c.size / 4; i++) p[i] = color;
   uint32_t id;
   if (drmModeAddFB(fd, w, h, 24, 32, c.pitch, c.handle, &id)) { perror("addfb"); exit(1); }
   return id;
}

static drmModeModeInfo mode_for(drmModeModeInfo base, uint32_t w, uint32_t h)
{
   drmModeModeInfo m = base;
   m.hdisplay = w; m.hsync_start = w + 8; m.hsync_end = w + 16; m.htotal = w + 32;
   m.vdisplay = h; m.vsync_start = h + 2; m.vsync_end = h + 4; m.vtotal = h + 8;
   m.clock = (uint32_t)((uint64_t)m.htotal * m.vtotal * 60 / 1000);
   m.vrefresh = 60;
   snprintf(m.name, sizeof m.name, "%ux%u", w, h);
   return m;
}

int main(int argc, char **argv)
{
   if (argc < 6) { fprintf(stderr, "usage: alt-scanout W1 H1 W2 H2 SECONDS\n"); return 2; }
   uint32_t w1 = atoi(argv[1]), h1 = atoi(argv[2]), w2 = atoi(argv[3]), h2 = atoi(argv[4]);
   int secs = atoi(argv[5]);
   int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
   if (fd < 0 || drmSetMaster(fd)) { perror("card0 master"); return 1; }
   drmModeRes *res = drmModeGetResources(fd);
   drmModeConnector *con = drmModeGetConnector(fd, res->connectors[0]);
   uint32_t crtc = res->crtcs[0], conn = con->connector_id;
   drmModeCrtc *saved = drmModeGetCrtc(fd, crtc);
   drmModeModeInfo m1 = mode_for(con->modes[0], w1, h1), m2 = mode_for(con->modes[0], w2, h2);
   uint32_t a = fb(fd, w1, h1, 0x00c03030), b = fb(fd, w2, h2, 0x003030c0);
   struct timespec t0, t;
   clock_gettime(CLOCK_MONOTONIC, &t0);
   long n = 0, fail = 0;
   do {
      if (drmModeSetCrtc(fd, crtc, (n & 1) ? b : a, 0, 0, &conn, 1, (n & 1) ? &m2 : &m1)) fail++;
      n++;
      clock_gettime(CLOCK_MONOTONIC, &t);
   } while (t.tv_sec - t0.tv_sec < secs);
   printf("%ld switches in %d s (%.0f/s), %ld failed\n", n, secs, (double)n / secs, fail);
   if (saved && saved->mode_valid)
      drmModeSetCrtc(fd, crtc, saved->buffer_id, 0, 0, &conn, 1, &saved->mode);
   return 0;
}
