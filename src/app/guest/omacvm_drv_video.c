/*
 * OmacVM's VA-API driver shim for OmacVM.app: Mesa's virtio_gpu driver with
 * one change. Mesa's virgl driver offers I420 and YV12 surfaces for decoding
 * next to NV12; FFmpeg then picks I420 (it matches yuv420p), and Firefox
 * cannot show I420 surfaces, so it falls back to decoding on the CPU. This
 * shim loads Mesa's driver unchanged and hides I420/YV12 from the surface
 * formats, as drivers for real hardware do. Everything else is Mesa's.
 *
 * Built in the VM by install.sh; used through LIBVA_DRIVER_NAME=omacvm.
 * MIT, part of OmacVM.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <va/va.h>
#include <va/va_backend.h>

#ifndef MESA_DRIVER
#define MESA_DRIVER "/usr/lib/dri/virtio_gpu_drv_video.so"
#endif

static VAStatus (*mesa_query_surface_attributes)(VADriverContextP, VAConfigID,
                                                 VASurfaceAttrib *, unsigned int *);

static VAStatus query_surface_attributes(VADriverContextP ctx, VAConfigID config,
                                         VASurfaceAttrib *attribs, unsigned int *num)
{
    VAStatus st = mesa_query_surface_attributes(ctx, config, attribs, num);
    unsigned int i, n = 0;
    int has_nv12 = 0;

    if (st != VA_STATUS_SUCCESS || !attribs)
        return st;
    for (i = 0; i < *num; i++)
        if (attribs[i].type == VASurfaceAttribPixelFormat &&
            attribs[i].value.value.i == VA_FOURCC_NV12)
            has_nv12 = 1;
    if (!has_nv12)
        return st;
    for (i = 0; i < *num; i++) {
        if (attribs[i].type == VASurfaceAttribPixelFormat &&
            (attribs[i].value.value.i == VA_FOURCC_I420 ||
             attribs[i].value.value.i == VA_FOURCC_YV12))
            continue;
        attribs[n++] = attribs[i];
    }
    *num = n;
    return st;
}

typedef VAStatus (*init_fn)(VADriverContextP);

static VAStatus shim_init(VADriverContextP ctx)
{
    static void *mesa;
    char name[32];
    init_fn init = NULL;
    VAStatus st;
    int minor;

    if (!mesa)
        mesa = dlopen(MESA_DRIVER, RTLD_NOW | RTLD_GLOBAL);
    if (!mesa)
        return VA_STATUS_ERROR_UNKNOWN;
    for (minor = 99; minor >= 0 && !init; minor--) {
        snprintf(name, sizeof(name), "__vaDriverInit_1_%d", minor);
        init = (init_fn)dlsym(mesa, name);
    }
    if (!init)
        return VA_STATUS_ERROR_UNKNOWN;
    st = init(ctx);
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaQuerySurfaceAttributes) {
        mesa_query_surface_attributes = ctx->vtable->vaQuerySurfaceAttributes;
        ctx->vtable->vaQuerySurfaceAttributes = query_surface_attributes;
    }
    return st;
}

/* libva looks for its own minor version first, then older ones. */
#define INIT(m) VAStatus __vaDriverInit_1_##m(VADriverContextP ctx); \
    __attribute__((visibility("default"))) VAStatus __vaDriverInit_1_##m(VADriverContextP ctx) { return shim_init(ctx); }
INIT(20) INIT(21) INIT(22) INIT(23) INIT(24) INIT(25) INIT(26) INIT(27) INIT(28)
INIT(29) INIT(30) INIT(31) INIT(32)
