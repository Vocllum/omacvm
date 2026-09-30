// notchcast — stream the Omarchy bar from a hidden Hyprland output to the
// macOS notch helper, and relay the helper's input back to the bar.
//
// Capture: ext-image-copy-capture-v1 session on the output named $NOTCHBAR_OUTPUT
// (default NOTCH), shared-memory buffer. A capture request blocks until
// Hyprland re-renders the output, so an idle bar costs nothing.
//
// Stream: TCP client to $NOTCHBAR_HOST:$NOTCHBAR_PORT (default
// 10.211.55.2:47811, the macOS side of the Parallels shared network). Each
// change is sent as the bounding box of changed pixels, LZ4-compressed. A full
// frame is sent after every (re)connect.
//
// Input/control: the helper sends text lines; they are validated and passed to
// the bar's "notchbar" IPC target (`qs ipc call`), never through a shell.
//
// Cursor: Hyprland draws the software cursor into every output that contains
// it, and the hidden output overlaps the top of the built-in display. The
// cursor area is therefore masked with the last clean pixels.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <lz4.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

#define FRAME_MAGIC 0x4843544eu  // "NTCH" little-endian
#define TEXT_MAGIC 0x5458544eu   // "NTXT"
#define CURSOR_BEFORE 28         // logical px masked left of / above the hotspot
#define CURSOR_AFTER 44          // logical px masked right of / below the hotspot

struct __attribute__((packed)) frame_header {
    uint32_t magic;
    uint32_t seq;
    uint16_t full_w, full_h;  // frame size in pixels
    uint16_t x, y, w, h;      // rectangle carried by this message
    uint8_t codec;            // 0 = raw, 1 = LZ4 block
    uint8_t format;           // wl_shm format (0 ARGB8888, 1 XRGB8888): BGRA bytes
    uint16_t scale;           // output scale x100
    uint32_t payload_len;
};

struct __attribute__((packed)) text_header {
    uint32_t magic;
    uint32_t len;
};

static const char *cfg_output, *cfg_host, *cfg_shell;
static int cfg_port;
static int verbose;

// Shared between the capture thread and the network thread.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int sock_fd = -1;
static uint8_t *prev;  // last frame as sent (cursor-masked)
static uint32_t W, H, fmt = UINT32_MAX;
static int have_frame;
static uint32_t seq;
static int scale100 = 200;

static void logf_(const char *f, ...) {
    va_list a;
    va_start(a, f);
    fprintf(stderr, "notchcast: ");
    vfprintf(stderr, f, a);
    fputc('\n', stderr);
    va_end(a);
}
#define LOG(...) logf_(__VA_ARGS__)
#define DBG(...) do { if (verbose) logf_(__VA_ARGS__); } while (0)

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

// ---------------------------------------------------------------- network --

static int write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

// Caller holds `lock`.
static void drop_socket_locked(void) {
    if (sock_fd >= 0) {
        shutdown(sock_fd, SHUT_RDWR);
        close(sock_fd);
        sock_fd = -1;
    }
}

// Caller holds `lock`. Sends rows [y, y+h) x [x, x+w) of `src` (stride W*4).
static void send_rect_locked(const uint8_t *src, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (sock_fd < 0 || !w || !h) return;
    size_t raw_len = (size_t)w * h * 4;
    uint8_t *raw = malloc(raw_len);
    int bound = LZ4_compressBound((int)raw_len);
    uint8_t *packed = malloc((size_t)bound);
    if (!raw || !packed) {
        free(raw);
        free(packed);
        return;
    }
    for (uint32_t r = 0; r < h; r++)
        memcpy(raw + (size_t)r * w * 4, src + ((size_t)(y + r) * W + x) * 4, (size_t)w * 4);
    int clen = LZ4_compress_default((const char *)raw, (char *)packed, (int)raw_len, bound);
    struct frame_header hd = {
        .magic = FRAME_MAGIC, .seq = ++seq, .full_w = (uint16_t)W, .full_h = (uint16_t)H,
        .x = (uint16_t)x, .y = (uint16_t)y, .w = (uint16_t)w, .h = (uint16_t)h,
        .format = (uint8_t)fmt, .scale = (uint16_t)scale100,
    };
    const uint8_t *payload = raw;
    if (clen > 0 && (size_t)clen < raw_len) {
        hd.codec = 1;
        hd.payload_len = (uint32_t)clen;
        payload = packed;
    } else {
        hd.codec = 0;
        hd.payload_len = (uint32_t)raw_len;
    }
    if (write_all(sock_fd, &hd, sizeof hd) || write_all(sock_fd, payload, hd.payload_len)) {
        LOG("send failed (%s), dropping connection", strerror(errno));
        drop_socket_locked();
    }
    free(raw);
    free(packed);
}

static void send_text(const char *s) {
    struct text_header th = {.magic = TEXT_MAGIC, .len = (uint32_t)strlen(s)};
    pthread_mutex_lock(&lock);
    if (sock_fd >= 0 && (write_all(sock_fd, &th, sizeof th) || write_all(sock_fd, s, th.len)))
        drop_socket_locked();
    pthread_mutex_unlock(&lock);
}

// Runs `qs ipc call -- notchbar <fn> <args...>`; returns its stdout (malloc'd)
// when want_output is set.
static char *ipc_call(int want_output, const char *fn, const char *a1, const char *a2, const char *a3) {
    int pfd[2] = {-1, -1};
    if (want_output && pipe2(pfd, O_CLOEXEC)) return NULL;
    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        dup2(devnull, 0);
        dup2(want_output ? pfd[1] : devnull, 1);
        dup2(devnull, 2);
        const char *argv[12];
        int n = 0;
        argv[n++] = "qs";
        argv[n++] = "ipc";
        argv[n++] = "-n";
        argv[n++] = "-p";
        argv[n++] = cfg_shell;
        argv[n++] = "call";
        argv[n++] = "--";
        argv[n++] = "notchbar";
        argv[n++] = fn;
        if (a1) argv[n++] = a1;
        if (a2) argv[n++] = a2;
        if (a3) argv[n++] = a3;
        argv[n] = NULL;
        execvp("qs", (char **)argv);
        _exit(127);
    }
    char *out = NULL;
    if (want_output) {
        close(pfd[1]);
        size_t cap = 4096, len = 0;
        out = malloc(cap);
        ssize_t r;
        while (out && (r = read(pfd[0], out + len, cap - len - 1)) > 0) {
            len += (size_t)r;
            if (cap - len < 2) out = realloc(out, cap *= 2);
        }
        if (out) {
            out[len] = 0;
            while (len && (out[len - 1] == '\n' || out[len - 1] == '\r')) out[--len] = 0;
        }
        close(pfd[0]);
    }
    if (pid > 0) waitpid(pid, NULL, 0);
    return out;
}

static int is_number(const char *s) {
    if (!s || !*s) return 0;
    char *end;
    strtod(s, &end);
    return *end == 0;
}

// One command line from the helper. Everything is validated before use.
static void handle_command(char *line) {
    char *argv[6] = {0};
    int argc = 0;
    for (char *tok = strtok(line, " \t"); tok && argc < 6; tok = strtok(NULL, " \t")) argv[argc++] = tok;
    if (!argc) return;
    const char *c = argv[0];
    DBG("cmd: %s %s %s %s", c, argv[1] ? argv[1] : "", argv[2] ? argv[2] : "", argv[3] ? argv[3] : "");
    if (!strcmp(c, "park") && argc == 2) {
        free(ipc_call(0, "setParked", !strcmp(argv[1], "1") ? "true" : "false", NULL, NULL));
    } else if (!strcmp(c, "beat") && argc == 1) {
        free(ipc_call(0, "heartbeat", NULL, NULL, NULL));
    } else if (!strcmp(c, "notch") && argc == 3 && is_number(argv[1]) && is_number(argv[2])) {
        free(ipc_call(0, "setNotch", argv[1], argv[2], NULL));
    } else if (!strcmp(c, "click") && argc == 4 && is_number(argv[1]) && is_number(argv[2]) && is_number(argv[3])) {
        free(ipc_call(0, "click", argv[1], argv[2], argv[3]));
    } else if (!strcmp(c, "wheel") && argc == 4 && is_number(argv[1]) && is_number(argv[2]) && is_number(argv[3])) {
        free(ipc_call(0, "wheel", argv[1], argv[2], argv[3]));
    } else if (!strcmp(c, "targets") && argc == 1) {
        char *out = ipc_call(1, "targets", NULL, NULL, NULL);
        if (out) {
            char *msg;
            if (asprintf(&msg, "targets %s", out) > 0) {
                send_text(msg);
                free(msg);
            }
            free(out);
        }
    } else if (!strcmp(c, "key") && argc == 1) {
        // Helper asks for a full frame (e.g. after it re-created its buffer).
        pthread_mutex_lock(&lock);
        int had = have_frame;
        if (had) send_rect_locked(prev, 0, 0, W, H);
        pthread_mutex_unlock(&lock);
        if (!had) free(ipc_call(0, "poke", NULL, NULL, NULL));
    } else {
        LOG("ignored command: %s", c);
    }
}

static void *net_thread(void *unused) {
    (void)unused;
    int backoff_ms = 250;
    for (;;) {
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = htons((uint16_t)cfg_port)};
        inet_pton(AF_INET, cfg_host, &sa.sin_addr);
        if (fd < 0 || connect(fd, (struct sockaddr *)&sa, sizeof sa)) {
            if (fd >= 0) close(fd);
            usleep((useconds_t)backoff_ms * 1000);
            if (backoff_ms < 2000) backoff_ms *= 2;
            continue;
        }
        backoff_ms = 250;
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
        LOG("connected to %s:%d", cfg_host, cfg_port);

        pthread_mutex_lock(&lock);
        sock_fd = fd;
        if (have_frame) send_rect_locked(prev, 0, 0, W, H);  // keyframe
        pthread_mutex_unlock(&lock);

        char buf[4096];
        size_t len = 0;
        for (;;) {
            ssize_t n = recv(fd, buf + len, sizeof buf - 1 - len, 0);
            if (n <= 0) {
                if (n < 0 && errno == EINTR) continue;
                break;
            }
            len += (size_t)n;
            buf[len] = 0;
            char *start = buf, *nl;
            while ((nl = memchr(start, '\n', len - (size_t)(start - buf)))) {
                *nl = 0;
                handle_command(start);
                start = nl + 1;
            }
            len -= (size_t)(start - buf);
            memmove(buf, start, len);
            if (len >= sizeof buf - 1) len = 0;  // oversized line: discard
        }
        LOG("helper disconnected");
        pthread_mutex_lock(&lock);
        if (sock_fd == fd) drop_socket_locked();
        else close(fd);
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

// ------------------------------------------------------- Hyprland socket --

// Sends one request to Hyprland's command socket and returns the reply.
static char *hypr_request(const char *req) {
    const char *rt = getenv("XDG_RUNTIME_DIR"), *sig = getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if (!rt || !sig) return NULL;
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s/hypr/%s/.socket.sock", rt, sig);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return NULL;
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) || write_all(fd, req, strlen(req))) {
        close(fd);
        return NULL;
    }
    size_t cap = 8192, len = 0;
    char *out = malloc(cap);
    ssize_t r;
    while (out && (r = read(fd, out + len, cap - len - 1)) > 0) {
        len += (size_t)r;
        if (cap - len < 2) out = realloc(out, cap *= 2);
    }
    close(fd);
    if (out) out[len] = 0;
    return out;
}

static int json_int(const char *json, const char *key, double *out) {
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\":", key);
    const char *p = strstr(json, pat);
    if (!p) return -1;
    *out = strtod(p + strlen(pat), NULL);
    return 0;
}

// Logical geometry of the capture output.
static double out_x, out_y, out_scale = 2;

static void refresh_output_geometry(void) {
    char *j = hypr_request("j/monitors all");
    if (!j) return;
    char pat[96];
    snprintf(pat, sizeof pat, "\"name\": \"%s\"", cfg_output);
    char *p = strstr(j, pat);
    if (!p) {
        snprintf(pat, sizeof pat, "\"name\":\"%s\"", cfg_output);
        p = strstr(j, pat);
    }
    if (p) {
        char *end = strchr(p, '}');
        if (end) *end = 0;
        // hyprctl -j prints `"x": 0` with a space; normalise by trying both.
        double v;
        char *q;
        if ((q = strstr(p, "\"x\": ")) || (q = strstr(p, "\"x\":"))) out_x = strtod(strchr(q, ':') + 1, NULL);
        if ((q = strstr(p, "\"y\": ")) || (q = strstr(p, "\"y\":"))) out_y = strtod(strchr(q, ':') + 1, NULL);
        if ((q = strstr(p, "\"scale\": ")) || (q = strstr(p, "\"scale\":"))) {
            v = strtod(strchr(q, ':') + 1, NULL);
            if (v > 0) out_scale = v;
        }
    }
    free(j);
    scale100 = (int)(out_scale * 100 + 0.5);
}

static int cursor_pos(double *x, double *y) {
    char *j = hypr_request("j/cursorpos");
    if (!j) return -1;
    int ok = !json_int(j, "x", x) && !json_int(j, "y", y);
    free(j);
    return ok ? 0 : -1;
}

// ------------------------------------------------------------- wayland --

static struct wl_display *dpy;
static struct wl_shm *shm;
static struct ext_image_copy_capture_manager_v1 *copy_mgr;
static struct ext_output_image_capture_source_manager_v1 *source_mgr;
#define MAX_OUTPUTS 16
static struct wl_output *outputs[MAX_OUTPUTS];
static uint32_t output_ids[MAX_OUTPUTS];
static char *output_names[MAX_OUTPUTS];
static int n_outputs;
static int outputs_changed;

static void out_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp,
                         const char *mk, const char *md, int32_t t) {
    (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sp; (void)mk; (void)md; (void)t;
}
static void out_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {
    (void)d; (void)o; (void)f; (void)w; (void)h; (void)r;
}
static void out_done(void *d, struct wl_output *o) { (void)d; (void)o; }
static void out_scale_ev(void *d, struct wl_output *o, int32_t s) { (void)d; (void)o; (void)s; }
static void out_name(void *d, struct wl_output *o, const char *name) {
    (void)d;
    for (int i = 0; i < n_outputs; i++)
        if (outputs[i] == o) {
            free(output_names[i]);
            output_names[i] = strdup(name);
        }
}
static void out_desc(void *d, struct wl_output *o, const char *s) { (void)d; (void)o; (void)s; }
static const struct wl_output_listener output_listener = {out_geometry, out_mode, out_done, out_scale_ev, out_name, out_desc};

static void reg_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t ver) {
    (void)d;
    if (!strcmp(iface, wl_shm_interface.name)) {
        shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
    } else if (!strcmp(iface, ext_image_copy_capture_manager_v1_interface.name)) {
        copy_mgr = wl_registry_bind(r, id, &ext_image_copy_capture_manager_v1_interface, 1);
    } else if (!strcmp(iface, ext_output_image_capture_source_manager_v1_interface.name)) {
        source_mgr = wl_registry_bind(r, id, &ext_output_image_capture_source_manager_v1_interface, 1);
    } else if (!strcmp(iface, wl_output_interface.name) && ver >= 4 && n_outputs < MAX_OUTPUTS) {
        outputs[n_outputs] = wl_registry_bind(r, id, &wl_output_interface, 4);
        output_ids[n_outputs] = id;
        output_names[n_outputs] = NULL;
        wl_output_add_listener(outputs[n_outputs], &output_listener, NULL);
        n_outputs++;
        outputs_changed = 1;
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) {
    (void)d; (void)r;
    for (int i = 0; i < n_outputs; i++)
        if (output_ids[i] == id) {
            wl_output_destroy(outputs[i]);
            free(output_names[i]);
            outputs[i] = outputs[n_outputs - 1];
            output_ids[i] = output_ids[n_outputs - 1];
            output_names[i] = output_names[n_outputs - 1];
            n_outputs--;
            outputs_changed = 1;
            return;
        }
}
static const struct wl_registry_listener registry_listener = {reg_global, reg_remove};

// Session state.
static uint32_t sess_w, sess_h, sess_fmt;
static int sess_done, sess_stopped, frame_ready, frame_failed;

static void s_size(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t w, uint32_t h) {
    (void)d; (void)s;
    sess_w = w;
    sess_h = h;
}
static void s_shm(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t f) {
    (void)d; (void)s;
    // Prefer XRGB8888, accept ARGB8888 (both are BGRA bytes in memory).
    if (f == WL_SHM_FORMAT_XRGB8888 || (f == WL_SHM_FORMAT_ARGB8888 && sess_fmt != WL_SHM_FORMAT_XRGB8888))
        sess_fmt = f;
}
static void s_dmabuf_dev(void *d, struct ext_image_copy_capture_session_v1 *s, struct wl_array *a) {
    (void)d; (void)s; (void)a;
}
static void s_dmabuf_fmt(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t f, struct wl_array *m) {
    (void)d; (void)s; (void)f; (void)m;
}
static void s_done(void *d, struct ext_image_copy_capture_session_v1 *s) {
    (void)d; (void)s;
    sess_done = 1;
}
static void s_stopped(void *d, struct ext_image_copy_capture_session_v1 *s) {
    (void)d; (void)s;
    sess_stopped = 1;
}
static const struct ext_image_copy_capture_session_v1_listener session_listener = {
    s_size, s_shm, s_dmabuf_dev, s_dmabuf_fmt, s_done, s_stopped};

static void f_transform(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t t) { (void)d; (void)f; (void)t; }
static void f_damage(void *d, struct ext_image_copy_capture_frame_v1 *f, int32_t x, int32_t y, int32_t w, int32_t h) {
    (void)d; (void)f; (void)x; (void)y; (void)w; (void)h;
}
static void f_time(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t a, uint32_t b, uint32_t c) {
    (void)d; (void)f; (void)a; (void)b; (void)c;
}
static void f_ready(void *d, struct ext_image_copy_capture_frame_v1 *f) {
    (void)d; (void)f;
    frame_ready = 1;
}
static void f_failed(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason) {
    (void)d; (void)f;
    frame_failed = (int)reason + 1;
}
static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {f_transform, f_damage, f_time,
                                                                                f_ready, f_failed};

static struct wl_output *find_output(void) {
    for (int i = 0; i < n_outputs; i++)
        if (output_names[i] && !strcmp(output_names[i], cfg_output)) return outputs[i];
    return NULL;
}

// Restores the cursor rectangle(s) from the previous frame (logical coords).
static void mask_cursor(uint8_t *px, double cx, double cy) {
    double s = out_scale;
    int x0 = (int)((cx - out_x - CURSOR_BEFORE) * s), y0 = (int)((cy - out_y - CURSOR_BEFORE) * s);
    int x1 = (int)((cx - out_x + CURSOR_AFTER) * s), y1 = (int)((cy - out_y + CURSOR_AFTER) * s);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > (int)W) x1 = (int)W;
    if (y1 > (int)H) y1 = (int)H;
    if (x0 >= x1 || y0 >= y1) return;
    for (int r = y0; r < y1; r++)
        memcpy(px + ((size_t)r * W + (size_t)x0) * 4, prev + ((size_t)r * W + (size_t)x0) * 4, (size_t)(x1 - x0) * 4);
}

// Runs one capture session until it stops or the output disappears.
static void capture_session(struct wl_output *out) {
    struct ext_image_capture_source_v1 *src = ext_output_image_capture_source_manager_v1_create_source(source_mgr, out);
    struct ext_image_copy_capture_session_v1 *ses = ext_image_copy_capture_manager_v1_create_session(copy_mgr, src, 0);
    ext_image_copy_capture_session_v1_add_listener(ses, &session_listener, NULL);
    sess_done = sess_stopped = 0;
    sess_fmt = UINT32_MAX;
    while (!sess_done && !sess_stopped)
        if (wl_display_dispatch(dpy) < 0) goto out_no_buf;
    if (sess_stopped || sess_fmt == UINT32_MAX) goto out_no_buf;

    refresh_output_geometry();
    uint32_t stride = sess_w * 4;
    size_t size = (size_t)stride * sess_h;
    int fd = memfd_create("notchcast", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)size)) goto out_no_buf;
    uint8_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, (int32_t)sess_w, (int32_t)sess_h, (int32_t)stride, sess_fmt);
    wl_shm_pool_destroy(pool);
    close(fd);

    pthread_mutex_lock(&lock);
    if (W != sess_w || H != sess_h) {
        free(prev);
        prev = calloc(1, size);
        have_frame = 0;
    }
    W = sess_w;
    H = sess_h;
    fmt = sess_fmt;
    pthread_mutex_unlock(&lock);
    LOG("capturing %s: %ux%u format 0x%x scale %.2f", cfg_output, W, H, fmt, out_scale);
    // A capture only completes when the output repaints; ask the bar for one
    // so the helper gets its first frame straight away.
    if (!have_frame) free(ipc_call(0, "poke", NULL, NULL, NULL));

    double pcx = -1e9, pcy = -1e9;  // cursor position at the previous frame
    while (!sess_stopped && !outputs_changed) {
        frame_ready = frame_failed = 0;
        struct ext_image_copy_capture_frame_v1 *f = ext_image_copy_capture_session_v1_create_frame(ses);
        ext_image_copy_capture_frame_v1_add_listener(f, &frame_listener, NULL);
        ext_image_copy_capture_frame_v1_attach_buffer(f, buf);
        ext_image_copy_capture_frame_v1_damage_buffer(f, 0, 0, (int32_t)W, (int32_t)H);
        ext_image_copy_capture_frame_v1_capture(f);
        int alive = 1;
        while (!frame_ready && !frame_failed && !sess_stopped)
            if (wl_display_dispatch(dpy) < 0) {
                alive = 0;
                break;
            }
        ext_image_copy_capture_frame_v1_destroy(f);
        if (!alive) break;
        if (frame_failed) {
            DBG("frame failed, reason %d", frame_failed - 1);
            if (frame_failed - 1 == EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS) break;
            usleep(50000);
            continue;
        }
        double t0 = now_ms();
        double cx, cy;
        pthread_mutex_lock(&lock);
        if (have_frame && !cursor_pos(&cx, &cy)) {
            mask_cursor(px, cx, cy);
            mask_cursor(px, pcx, pcy);
            pcx = cx;
            pcy = cy;
        }
        // Bounding box of changed pixels.
        int y0 = -1, y1 = -1, x0 = (int)W, x1 = -1;
        if (!have_frame) {
            y0 = 0; y1 = (int)H - 1; x0 = 0; x1 = (int)W - 1;
        } else {
            for (int r = 0; r < (int)H; r++) {
                const uint32_t *a = (const uint32_t *)(px + (size_t)r * stride);
                const uint32_t *b = (const uint32_t *)(prev + (size_t)r * stride);
                if (!memcmp(a, b, stride)) continue;
                if (y0 < 0) y0 = r;
                y1 = r;
                int l = 0, rr = (int)W - 1;
                while (l < x0 && a[l] == b[l]) l++;
                while (rr > x1 && a[rr] == b[rr]) rr--;
                if (l < x0) x0 = l;
                if (rr > x1) x1 = rr;
            }
        }
        if (y0 >= 0) {
            for (int r = y0; r <= y1; r++)
                memcpy(prev + (size_t)r * stride + (size_t)x0 * 4, px + (size_t)r * stride + (size_t)x0 * 4,
                       (size_t)(x1 - x0 + 1) * 4);
            have_frame = 1;
            send_rect_locked(prev, (uint32_t)x0, (uint32_t)y0, (uint32_t)(x1 - x0 + 1), (uint32_t)(y1 - y0 + 1));
            DBG("sent %d,%d %dx%d in %.2f ms", x0, y0, x1 - x0 + 1, y1 - y0 + 1, now_ms() - t0);
        }
        pthread_mutex_unlock(&lock);
    }

    wl_buffer_destroy(buf);
    munmap(px, size);
out_no_buf:
    ext_image_copy_capture_session_v1_destroy(ses);
    ext_image_capture_source_v1_destroy(src);
    wl_display_roundtrip(dpy);
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "-v")) verbose = 1;
    cfg_output = getenv("NOTCHBAR_OUTPUT") ? getenv("NOTCHBAR_OUTPUT") : "NOTCH";
    cfg_host = getenv("NOTCHBAR_HOST") ? getenv("NOTCHBAR_HOST") : "10.211.55.2";
    cfg_port = getenv("NOTCHBAR_PORT") ? atoi(getenv("NOTCHBAR_PORT")) : 47811;
    const char *op = getenv("OMARCHY_PATH") ? getenv("OMARCHY_PATH") : "/usr/share/omarchy";
    if (asprintf((char **)&cfg_shell, "%s/shell", op) < 0) return 1;

    pthread_t th;
    pthread_create(&th, NULL, net_thread, NULL);

    for (;;) {
        dpy = wl_display_connect(NULL);
        if (!dpy) {
            LOG("cannot connect to Wayland, retrying");
            sleep(2);
            continue;
        }
        n_outputs = 0;
        struct wl_registry *reg = wl_display_get_registry(dpy);
        wl_registry_add_listener(reg, &registry_listener, NULL);
        wl_display_roundtrip(dpy);
        wl_display_roundtrip(dpy);
        if (!shm || !copy_mgr || !source_mgr) {
            LOG("compositor lacks ext-image-copy-capture-v1");
            return 1;
        }
        while (wl_display_get_error(dpy) == 0) {
            outputs_changed = 0;
            struct wl_output *out = find_output();
            if (!out) {
                // Wait for the output to appear (registry events arrive via dispatch).
                struct pollfd p = {.fd = wl_display_get_fd(dpy), .events = POLLIN};
                wl_display_flush(dpy);
                if (poll(&p, 1, 1000) > 0 && wl_display_dispatch(dpy) < 0) break;
                wl_display_roundtrip(dpy);
                continue;
            }
            capture_session(out);
            if (!outputs_changed) usleep(200000);  // stopped session: brief pause before retrying
        }
        LOG("Wayland connection lost, reconnecting");
        for (int i = 0; i < n_outputs; i++) free(output_names[i]);
        n_outputs = 0;
        shm = NULL;
        copy_mgr = NULL;
        source_mgr = NULL;
        wl_display_disconnect(dpy);
        sleep(1);
    }
}
