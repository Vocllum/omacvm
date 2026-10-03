/* UTM's virglrenderer tells Linux the GPU has no multisampling (max_samples 1).
 * OpenGL ES 3.0 needs 4 samples, so Chrome's ANGLE refuses ES 3.0 and Chrome
 * turns its GPU off (no WebGL, pages drawn in software). The Mac's GPU has
 * them: raise the value when Mesa reads it. Loaded from /etc/ld.so.preload;
 * only touches that one ioctl result. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <drm/drm.h>
#include <drm/virtgpu_drm.h>

/* uint32 offsets in Mesa's virgl_caps_v1 (src/virtio/virtio-gpu/virgl_hw.h) */
#define BSET 65                /* bool set 1; bit 14 = texture_multisample */
#define MAX_SAMPLES 71

int ioctl(int fd, unsigned long req, ...)
{
	static int (*real)(int, unsigned long, ...);
	va_list ap;
	va_start(ap, req);
	void *arg = va_arg(ap, void *);
	va_end(ap);
	if (!real)
		real = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
	int r = real(fd, req, arg);
	if (r == 0 && req == DRM_IOCTL_VIRTGPU_GET_CAPS) {
		struct drm_virtgpu_get_caps *g = arg;
		uint32_t *c = (uint32_t *)(uintptr_t)g->addr;
		if ((g->cap_set_id == 1 || g->cap_set_id == 2) && g->size > MAX_SAMPLES * 4 &&
		    (c[BSET] >> 14 & 1) && c[MAX_SAMPLES] < 4)
			c[MAX_SAMPLES] = 4;
	}
	return r;
}
