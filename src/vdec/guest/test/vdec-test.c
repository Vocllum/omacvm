// SPDX-License-Identifier: MIT
/*
 * vdec-test: drives the omacvm-vdec V4L2 decoder the way Chromium does and
 * checks every picture against FFmpeg's software decoder.
 *
 *   vdec-test FILE [FILE...]      (root or the video group, omacvm-vdecd running)
 *
 * Per file: OUTPUT buffers with one frame each, CAPTURE buffers taken from
 * the driver (MMAP) and exported (EXPBUF), each picture read back through EGL
 * the way the compositor imports it, compared with FFmpeg's software picture
 * converted to RGB (PSNR, lowest of all frames). Then a seek (OUTPUT
 * STREAMOFF/STREAMON from the first key frame), then a drain (DEC_CMD_STOP:
 * an empty LAST buffer and the EOS event). A size change in the stream must
 * come as LAST + SOURCE_CHANGE. Prints one JSON line per file; exit 1 when a
 * check fails.
 *
 * Build: cc -O2 -o vdec-test vdec-test.c $(pkg-config --cflags --libs \
 *          libavformat libavcodec libavutil libswscale egl glesv2 gbm libdrm)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include <linux/videodev2.h>

#define NOUT 8
#define NCAP 6
#define MIN_PSNR 35.0

static int vfd;
static EGLDisplay egl;
static PFNEGLCREATEIMAGEKHRPROC create_image;
static PFNEGLDESTROYIMAGEKHRPROC destroy_image;
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target;

static void die(const char *what)
{
	fprintf(stderr, "vdec-test: %s: %s\n", what, strerror(errno));
	exit(1);
}

static int xioctl(unsigned long req, void *arg)
{
	int r;

	do
		r = ioctl(vfd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

/* ---- the reference: FFmpeg's software decoder, converted to RGBA --------------- */

struct ref {
	AVFormatContext *fc;
	AVCodecContext *cc;
	AVBSFContext *bsf;	/* MP4 H.264 -> Annex B, as Chromium sends it */
	int stream;
	struct SwsContext *sws;
	int sw, sh;
};

static void ref_open(struct ref *r, const char *path)
{
	const AVCodec *dec;

	memset(r, 0, sizeof(*r));
	if (avformat_open_input(&r->fc, path, NULL, NULL) || avformat_find_stream_info(r->fc, NULL) < 0)
		die(path);
	r->stream = av_find_best_stream(r->fc, AVMEDIA_TYPE_VIDEO, -1, -1, &dec, 0);
	if (r->stream < 0)
		die("no video stream");
	r->cc = avcodec_alloc_context3(dec);
	avcodec_parameters_to_context(r->cc, r->fc->streams[r->stream]->codecpar);
	r->cc->thread_count = 1;
	if (avcodec_open2(r->cc, dec, NULL))
		die("software decoder");
	if (dec->id == AV_CODEC_ID_H264) {
		av_bsf_alloc(av_bsf_get_by_name("h264_mp4toannexb"), &r->bsf);
		avcodec_parameters_copy(r->bsf->par_in, r->fc->streams[r->stream]->codecpar);
		r->bsf->time_base_in = r->fc->streams[r->stream]->time_base;
		if (av_bsf_init(r->bsf))
			die("annexb filter");
	}
}

/* The next packet of the stream as the decoder gets it (NULL at the end). */
static AVPacket *ref_packet(struct ref *r)
{
	AVPacket *p = av_packet_alloc();

	for (;;) {
		if (r->bsf && av_bsf_receive_packet(r->bsf, p) == 0)
			return p;
		if (av_read_frame(r->fc, p) < 0) {
			av_packet_free(&p);
			return NULL;
		}
		if (p->stream_index != r->stream) {
			av_packet_unref(p);
			continue;
		}
		if (!r->bsf)
			return p;
		av_bsf_send_packet(r->bsf, p);
	}
}

/* ---- CAPTURE buffers, imported through EGL ----------------------------------------- */

struct cap {
	int fd;
	EGLImageKHR img;
	GLuint tex, fbo;
};

static struct cap caps[NCAP];
static int ncap, cap_w, cap_h, vis_w, vis_h, cap_stride;

static void egl_init(void)
{
	int drm = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	struct gbm_device *gbm = drm >= 0 ? gbm_create_device(drm) : NULL;
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_display = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
	EGLint attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	EGLContext ctx;

	create_image = (void *)eglGetProcAddress("eglCreateImageKHR");
	destroy_image = (void *)eglGetProcAddress("eglDestroyImageKHR");
	image_target = (void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	if (!gbm || !get_display)
		die("gbm/egl");
	egl = get_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	if (!eglInitialize(egl, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API))
		die("eglInitialize");
	ctx = eglCreateContext(egl, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
	if (!ctx || !eglMakeCurrent(egl, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
		die("egl context");
}

static void cap_release(void)
{
	struct v4l2_requestbuffers rb = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, .memory = V4L2_MEMORY_MMAP };

	for (int i = 0; i < ncap; i++) {
		glDeleteFramebuffers(1, &caps[i].fbo);
		glDeleteTextures(1, &caps[i].tex);
		destroy_image(egl, caps[i].img);
		close(caps[i].fd);
	}
	ncap = 0;
	xioctl(VIDIOC_REQBUFS, &rb);
}

static void cap_queue(int i)
{
	struct v4l2_plane pl[1] = { 0 };
	struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, .memory = V4L2_MEMORY_MMAP,
				 .index = i, .length = 1, .m.planes = pl };

	if (xioctl(VIDIOC_QBUF, &b))
		die("QBUF CAPTURE");
}

/* After SOURCE_CHANGE: the new format, buffers, exports, imports, stream on. */
static void cap_setup(void)
{
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE };
	struct v4l2_selection sel = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .target = V4L2_SEL_TGT_COMPOSE };
	struct v4l2_requestbuffers rb = { .count = NCAP, .type = f.type, .memory = V4L2_MEMORY_MMAP };
	int type = f.type;

	if (xioctl(VIDIOC_G_FMT, &f) || xioctl(VIDIOC_G_SELECTION, &sel))
		die("G_FMT/G_SELECTION CAPTURE");
	if (f.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_ABGR32 || f.fmt.pix_mp.num_planes != 1) {
		errno = EPROTO;
		die("CAPTURE format is not single-plane ABGR32");
	}
	cap_w = f.fmt.pix_mp.width;
	cap_h = f.fmt.pix_mp.height;
	cap_stride = f.fmt.pix_mp.plane_fmt[0].bytesperline;
	vis_w = sel.r.width;
	vis_h = sel.r.height;
	if (xioctl(VIDIOC_REQBUFS, &rb) || rb.count < 2)
		die("REQBUFS CAPTURE");
	ncap = rb.count > NCAP ? NCAP : rb.count;
	for (int i = 0; i < ncap; i++) {
		struct v4l2_exportbuffer e = { .type = type, .index = i, .plane = 0, .flags = O_CLOEXEC | O_RDWR };
		EGLint a[] = {
			EGL_WIDTH, cap_w, EGL_HEIGHT, cap_h, EGL_LINUX_DRM_FOURCC_EXT, DRM_FORMAT_ARGB8888,
			EGL_DMA_BUF_PLANE0_FD_EXT, 0, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
			EGL_DMA_BUF_PLANE0_PITCH_EXT, cap_stride, EGL_NONE,
		};

		if (xioctl(VIDIOC_EXPBUF, &e))
			die("EXPBUF");
		caps[i].fd = e.fd;
		/* The check Chromium makes before it imports a frame. */
		if (lseek(e.fd, 0, SEEK_END) < (off_t)cap_stride * cap_h) {
			errno = EPROTO;
			die("CAPTURE dmabuf smaller than its plane");
		}
		a[7] = e.fd;
		caps[i].img = create_image(egl, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, a);
		if (!caps[i].img)
			die("EGL import of a CAPTURE buffer");
		glGenTextures(1, &caps[i].tex);
		glBindTexture(GL_TEXTURE_2D, caps[i].tex);
		image_target(GL_TEXTURE_2D, caps[i].img);
		glGenFramebuffers(1, &caps[i].fbo);
		glBindFramebuffer(GL_FRAMEBUFFER, caps[i].fbo);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, caps[i].tex, 0);
		cap_queue(i);
	}
	if (xioctl(VIDIOC_STREAMON, &type))
		die("STREAMON CAPTURE");
}

/* ---- one file ------------------------------------------------------------------------ */

struct result {
	int frames, sizes, seeks, errors;
	double min_psnr;
	bool drained, eos;
};

static double psnr_rgb(const uint8_t *a, const uint8_t *b, int w, int h, int bstride)
{
	double se = 0;

	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++)
			for (int c = 0; c < 3; c++) {
				int d = a[((size_t)y * w + x) * 4 + c] - b[(size_t)y * bstride + x * 4 + c];

				se += d * d;
			}
	se /= (double)w * h * 3;
	return se == 0 ? 99 : 10 * log10(255.0 * 255.0 / se);
}

/* Software pictures by timestamp, kept until the driver's picture comes. */
#define NREF 64
static AVFrame *refs[NREF];

static void ref_keep(AVFrame *f)
{
	for (int i = 0; i < NREF; i++)
		if (!refs[i]) {
			refs[i] = f;
			return;
		}
	av_frame_free(&f);
}

static AVFrame *ref_take(int64_t ts)
{
	for (int i = 0; i < NREF; i++)
		if (refs[i] && refs[i]->pts == ts) {
			AVFrame *f = refs[i];

			refs[i] = NULL;
			return f;
		}
	return NULL;
}

static void refs_clear(void)
{
	for (int i = 0; i < NREF; i++)
		av_frame_free(&refs[i]);
}

static void compare(struct ref *r, struct result *res, int idx, int64_t ts)
{
	AVFrame *sf = ref_take(ts);
	static uint8_t *px;
	uint8_t *rgb[1];
	int stride[1];

	if (!sf) {
		res->errors++;
		fprintf(stderr, "vdec-test: no software picture for timestamp %lld\n", (long long)ts);
		return;
	}
	if (sf->width != vis_w || sf->height != vis_h) {
		res->errors++;
		fprintf(stderr, "vdec-test: picture %dx%d, software %dx%d\n", vis_w, vis_h, sf->width, sf->height);
		av_frame_free(&sf);
		return;
	}
	px = realloc(px, (size_t)vis_w * vis_h * 4);
	glBindFramebuffer(GL_FRAMEBUFFER, caps[idx].fbo);
	glReadPixels(0, 0, vis_w, vis_h, GL_RGBA, GL_UNSIGNED_BYTE, px);
	r->sws = sws_getCachedContext(r->sws, sf->width, sf->height, sf->format, sf->width, sf->height,
				      AV_PIX_FMT_RGBA, SWS_BILINEAR | SWS_ACCURATE_RND | SWS_FULL_CHR_H_INT,
				      NULL, NULL, NULL);
	{
		int cs = sf->colorspace == AVCOL_SPC_BT470BG || sf->colorspace == AVCOL_SPC_SMPTE170M ? SWS_CS_ITU601 :
			 sf->colorspace == AVCOL_SPC_BT709 || sf->height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601;
		const int *coef = sws_getCoefficients(cs);

		sws_setColorspaceDetails(r->sws, coef, sf->color_range == AVCOL_RANGE_JPEG, coef, 1, 0, 1 << 16, 1 << 16);
	}
	stride[0] = sf->width * 4;
	rgb[0] = malloc((size_t)stride[0] * sf->height);
	sws_scale(r->sws, (const uint8_t *const *)sf->data, sf->linesize, 0, sf->height, rgb, stride);
	double p = psnr_rgb(px, rgb[0], vis_w, vis_h, stride[0]);

	if (p < res->min_psnr)
		res->min_psnr = p;
	free(rgb[0]);
	av_frame_free(&sf);
}

/* Feeds the software decoder too, so both see the same packets. */
static void ref_decode(struct ref *r, AVPacket *p)
{
	AVFrame *f = av_frame_alloc();

	avcodec_send_packet(r->cc, p);
	while (avcodec_receive_frame(r->cc, f) == 0) {
		ref_keep(f);	/* by pts, as the driver copies it */
		f = av_frame_alloc();
	}
	av_frame_free(&f);
}

static void run(const char *path, struct result *res)
{
	struct ref r;
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE };
	struct v4l2_requestbuffers rb = { .count = NOUT, .type = f.type, .memory = V4L2_MEMORY_MMAP };
	struct v4l2_event_subscription sub = { .type = V4L2_EVENT_SOURCE_CHANGE };
	void *out_map[NOUT];
	bool out_free[NOUT];
	int out_type = f.type, cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	int64_t n = 0, seek_at, last_ts = -1, skip_below = -1, epoch = 0;
	AVRational tb;
	bool fed_all = false, stopped = false, sizing = false;
	AVPacket *pending = NULL;

	memset(res, 0, sizeof(*res));
	res->min_psnr = 99;
	ref_open(&r, path);
	seek_at = r.fc->streams[r.stream]->nb_frames > 40 ? 30 : -1;
	tb = r.fc->streams[r.stream]->time_base;

	f.fmt.pix_mp.pixelformat = r.cc->codec_id == AV_CODEC_ID_H264 ? V4L2_PIX_FMT_H264 :
				   r.cc->codec_id == AV_CODEC_ID_VP9 ? V4L2_PIX_FMT_VP9 : V4L2_PIX_FMT_HEVC;
	f.fmt.pix_mp.width = r.cc->width;
	f.fmt.pix_mp.height = r.cc->height;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = 2 << 20;
	if (xioctl(VIDIOC_S_FMT, &f) || xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub))
		die("S_FMT OUTPUT / subscribe");
	sub.type = V4L2_EVENT_EOS;
	if (xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub) || xioctl(VIDIOC_REQBUFS, &rb) || rb.count < NOUT)
		die("subscribe EOS / REQBUFS OUTPUT");
	for (int i = 0; i < NOUT; i++) {
		struct v4l2_plane pl[1];
		struct v4l2_buffer b = { .type = out_type, .memory = V4L2_MEMORY_MMAP, .index = i,
					 .length = 1, .m.planes = pl };

		if (xioctl(VIDIOC_QUERYBUF, &b))
			die("QUERYBUF");
		out_map[i] = mmap(NULL, pl[0].length, PROT_READ | PROT_WRITE, MAP_SHARED, vfd, pl[0].m.mem_offset);
		if (out_map[i] == MAP_FAILED)
			die("mmap OUTPUT");
		out_free[i] = true;
	}
	if (xioctl(VIDIOC_STREAMON, &out_type))
		die("STREAMON OUTPUT");

	for (int guard = 0; guard < 200000; guard++) {
		struct pollfd pfd = { .fd = vfd, .events = POLLIN | POLLOUT | POLLPRI };
		struct v4l2_event ev;
		struct v4l2_plane pl[1];
		struct v4l2_buffer b;

		/* Feed one frame per free OUTPUT buffer. */
		for (int i = 0; i < NOUT && !fed_all; i++) {
			if (!out_free[i])
				continue;
			if (!pending)
				pending = ref_packet(&r);
			if (!pending) {
				fed_all = true;
				break;
			}
			if (n == seek_at) {	/* seek: drop what is queued, start over */
				if (xioctl(VIDIOC_STREAMOFF, &out_type) || xioctl(VIDIOC_STREAMON, &out_type))
					die("seek (STREAMOFF/STREAMON OUTPUT)");
				for (int k = 0; k < NOUT; k++)
					out_free[k] = true;
				av_packet_free(&pending);
				av_seek_frame(r.fc, r.stream, 0, AVSEEK_FLAG_BACKWARD);
				if (r.bsf)
					av_bsf_flush(r.bsf);
				avcodec_flush_buffers(r.cc);
				refs_clear();
				res->seeks++;
				seek_at = -1;
				/* New timestamps after the seek (1000 s on): pictures
				 * decoded before it may still come out. */
				epoch += 1000000000;
				skip_below = epoch * 1000;
				last_ts = -1;
				i = -1;		/* feed again from the first buffer */
				continue;
			}
			memset(&b, 0, sizeof(b));
			memset(pl, 0, sizeof(pl));
			b.type = out_type;
			b.memory = V4L2_MEMORY_MMAP;
			b.index = i;
			b.length = 1;
			b.m.planes = pl;
			/* Presentation time in us, as Chromium passes it. */
			int64_t us = epoch + av_rescale_q(pending->pts == AV_NOPTS_VALUE ? n : pending->pts,
							  tb, (AVRational){ 1, 1000000 });

			b.timestamp.tv_sec = us / 1000000;
			b.timestamp.tv_usec = us % 1000000;
			pl[0].bytesused = pending->size;
			memcpy(out_map[i], pending->data, pending->size);
			pending->pts = us * 1000;	/* the driver's ns */
			ref_decode(&r, pending);
			if (xioctl(VIDIOC_QBUF, &b))
				die("QBUF OUTPUT");
			out_free[i] = false;
			av_packet_free(&pending);
			n++;
		}
		if (fed_all && !stopped && ncap) {
			struct v4l2_decoder_cmd dc = { .cmd = V4L2_DEC_CMD_STOP };

			ref_decode(&r, NULL);
			if (xioctl(VIDIOC_DECODER_CMD, &dc))
				die("DEC_CMD_STOP");
			stopped = true;
		}

		if (poll(&pfd, 1, 5000) <= 0) {
			fprintf(stderr, "vdec-test: no progress for 5 s\n");
			res->errors++;
			break;
		}
		if (pfd.revents & POLLPRI) {
			while (xioctl(VIDIOC_DQEVENT, &ev) == 0) {
				if (getenv("VDEC_TEST_DEBUG"))
					fprintf(stderr, "event %u (frames %d)\n", ev.type, res->frames);
				if (ev.type == V4L2_EVENT_EOS)
					res->eos = true;
				if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
					res->sizes++;
					if (ncap)
						sizing = true;	/* after the LAST buffer */
					else
						cap_setup();
				}
			}
		}
		memset(&b, 0, sizeof(b));
		b.type = out_type;
		b.memory = V4L2_MEMORY_MMAP;
		b.length = 1;
		b.m.planes = pl;
		while (xioctl(VIDIOC_DQBUF, &b) == 0)
			out_free[b.index] = true;
		b.type = cap_type;
		while (ncap && xioctl(VIDIOC_DQBUF, &b) == 0) {
			if (b.flags & V4L2_BUF_FLAG_ERROR) {
				res->errors++;
			} else if (b.m.planes[0].bytesused) {
				int64_t ts = ((int64_t)b.timestamp.tv_sec * 1000000 + b.timestamp.tv_usec) * 1000;

				if (ts >= skip_below) {
					if (ts <= last_ts)
						res->errors++;	/* display order */
					last_ts = ts;
					compare(&r, res, b.index, ts);
					res->frames++;
				}
			}
			if (b.flags & V4L2_BUF_FLAG_LAST) {
				/* As the V4L2 decoder spec says: a LAST buffer can come before
				 * we read the SOURCE_CHANGE event that goes with it. */
				while (xioctl(VIDIOC_DQEVENT, &ev) == 0) {
					if (ev.type == V4L2_EVENT_EOS)
						res->eos = true;
					if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
						res->sizes++;
						sizing = true;
					}
				}
				if (getenv("VDEC_TEST_DEBUG"))
					fprintf(stderr, "LAST (sizing %d, frames %d)\n", sizing, res->frames);
				if (sizing) {	/* a new size: new buffers */
					if (xioctl(VIDIOC_STREAMOFF, &cap_type))
						die("STREAMOFF CAPTURE");
					cap_release();
					cap_setup();
					sizing = false;
					break;
				}
				res->drained = true;
				break;
			}
			cap_queue(b.index);
		}
		if (res->drained && res->eos)
			break;
	}
	xioctl(VIDIOC_STREAMOFF, &out_type);
	xioctl(VIDIOC_STREAMOFF, &cap_type);
	cap_release();
	refs_clear();
	rb.count = 0;
	xioctl(VIDIOC_REQBUFS, &rb);
	for (int i = 0; i < NOUT; i++)
		munmap(out_map[i], f.fmt.pix_mp.plane_fmt[0].sizeimage);
	sws_freeContext(r.sws);
	av_bsf_free(&r.bsf);
	avcodec_free_context(&r.cc);
	avformat_close_input(&r.fc);
}

static int find_device(void)
{
	char path[32];

	for (int i = 0; i < 64; i++) {
		struct v4l2_capability c;
		int fd;

		snprintf(path, sizeof(path), "/dev/video%d", i);
		fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, VIDIOC_QUERYCAP, &c) == 0 && !strcmp((char *)c.driver, "omacvm-vdec"))
			return fd;
		close(fd);
	}
	return -1;
}

int main(int argc, char **argv)
{
	int fails = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: vdec-test FILE...\n");
		return 2;
	}
	egl_init();
	for (int i = 1; i < argc; i++) {
		struct result res;
		bool ok;

		vfd = find_device();
		if (vfd < 0) {
			fprintf(stderr, "vdec-test: no omacvm-vdec device (module loaded, omacvm-vdecd running?)\n");
			return 1;
		}
		run(argv[i], &res);
		close(vfd);
		ok = res.frames > 0 && !res.errors && res.min_psnr >= MIN_PSNR && res.drained && res.eos;
		fails += !ok;
		printf("{\"file\": \"%s\", \"ok\": %s, \"frames\": %d, \"min_psnr_rgb\": %.1f, \"sizes\": %d, "
		       "\"seeks\": %d, \"drained\": %s, \"eos\": %s, \"errors\": %d}\n", argv[i], ok ? "true" : "false",
		       res.frames, res.min_psnr, res.sizes, res.seeks, res.drained ? "true" : "false",
		       res.eos ? "true" : "false", res.errors);
	}
	return fails ? 1 : 0;
}
