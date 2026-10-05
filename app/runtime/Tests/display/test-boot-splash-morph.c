/*
 * The start animation's core (ui/omacvm-splash.h of
 * omacvm-cocoa-boot-splash.patch), built on its own:
 *
 * - it starts as the word OMACVM, every cell still, and ends as exactly the
 *   logo's cells (the firmware's), still, with no glow;
 * - still cells end on the pixels where GL's nearest sampling of the logo
 *   texture ends them (omacvm_splash_draw), at several window sizes, so the
 *   animation's last frame is the GL splash's and the firmware's logo;
 * - no cell jumps from one frame to the next (120 Hz);
 * - the glow comes and goes: none at the start and the end, some mid-flight;
 *   the background is plain navy without it;
 * - a guest picture is told apart: the firmware's logo, black, anything else.
 *
 * build-qemu-gpu-runtime.sh builds it with -I the patched ui/;
 * check-boot-splash.sh with the header taken from the patch.
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define g_new0(T, n) ((T *)calloc((n), sizeof(T)))

#include "omacvm-splash.h"

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "test-boot-splash-morph: " __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

static IntroCell cells[INTRO_MAX];

/* The cells at t as a grid of whole/half cells: grid[y][2x] = on. */
static bool word[SPLASH_ROWS][2 * SPLASH_COLS + 2];

static int still_grid(double t, double *glow)
{
    int n = omacvm_intro_cells(t, cells, glow);

    memset(word, 0, sizeof(word));
    for (int i = 0; i < n; i++) {
        double x2 = cells[i].x * 2, y = cells[i].y;
        if (!cells[i].rest || cells[i].size != 1 || x2 != floor(x2) || y != floor(y) ||
            x2 < 0 || x2 > 2 * SPLASH_COLS || y < 0 || y >= SPLASH_ROWS) {
            return -1;
        }
        word[(int)y][(int)x2] = true;
    }
    return n;
}

static void test_ends(void)
{
    double glow;

    /* The end, and long after it: the logo, cell for cell. */
    for (double t = INTRO_END; t < INTRO_END + 5; t += 0.5) {
        CHECK(still_grid(t, &glow) > 0, "t=%.1f: a cell still moves after the end", t);
        CHECK(glow == 0, "t=%.1f: glow %.3f after the end", t, glow);
        for (int r = 0; r < SPLASH_ROWS; r++) {
            for (int c = 0; c < SPLASH_COLS; c++) {
                bool logo = omacvm_splash_cells[r][c] == '#';
                CHECK(word[r][2 * c] == logo, "t=%.1f: cell %d,%d is %s the logo's", t,
                      c, r, logo ? "missing from" : "not in");
                CHECK(!word[r][2 * c + 1], "t=%.1f: a cell between columns", t);
            }
        }
    }

    /* The start: OMACVM, 76 cells wide, 2.5 cells right of the logo. */
    CHECK(still_grid(0, &glow) > 0, "t=0: not every cell is still");
    CHECK(glow == 0, "t=0: glow %.3f", glow);
    int left = 2 * SPLASH_COLS, right = 0, on = 0;
    for (int r = 0; r < SPLASH_ROWS; r++) {
        for (int x2 = 0; x2 < 2 * SPLASH_COLS + 2; x2++) {
            if (word[r][x2]) {
                left = MIN(left, x2);
                right = MAX(right, x2);
                on++;
                /* O, M and A where the logo has them, 2.5 cells on. */
                if (x2 < 2 * MORPH_KEEP_COLS) {
                    CHECK(x2 % 2 == 1 && omacvm_splash_cells[r][(x2 - 5) / 2] == '#',
                          "t=0: %g,%d is not O, M or A", x2 / 2.0, r);
                }
            }
        }
    }
    CHECK(left == 5 && right == 5 + 2 * 75, "t=0: OMACVM spans %g..%g, not 2.5..77.5",
          left / 2.0, right / 2.0);
    CHECK(on > 300, "t=0: only %d cells", on);
}

/* GL_NEAREST over the 81 x 19 texture in the viewport omacvm_splash_draw()
 * sets: the first pixel (from the top left) of each cell. */
static void gl_edges(int w, int h, int fw, int fh, int *xs, int *ys)
{
    double cw = (double)w * SPLASH_CELL / fw, ch = (double)h * SPLASH_CELL / fh;
    int lw = MAX(1, (int)lround(SPLASH_COLS * cw)), lh = MAX(1, (int)lround(SPLASH_ROWS * ch));
    int vx = (w - lw) / 2, vy = (h - lh) / 2;   /* GL: from the bottom */

    for (int c = 0; c <= SPLASH_COLS; c++) {
        xs[c] = -1;
    }
    for (int p = vx; p < vx + lw; p++) {
        int c = (int)floor((p + 0.5 - vx) / lw * SPLASH_COLS);
        if (xs[c] < 0) {
            xs[c] = p;
        }
    }
    xs[SPLASH_COLS] = vx + lw;
    for (int r = 0; r <= SPLASH_ROWS; r++) {
        ys[r] = -1;
    }
    /* Rows from the top: texture row 0 is the logo's top row. */
    for (int j = vy + lh - 1; j >= vy; j--) {
        int r = (int)floor((vy + lh - (j + 0.5)) / lh * SPLASH_ROWS);
        if (ys[r] < 0) {
            ys[r] = h - 1 - j;
        }
    }
    ys[SPLASH_ROWS] = h - vy;
}

static void test_geometry(void)
{
    static const int sizes[][4] = {
        { 1280, 720, 1920, 1080 }, { 1920, 1080, 1920, 1080 }, { 2880, 1800, 1920, 1080 },
        { 3456, 2234, 1920, 1080 }, { 1366, 768, 1920, 1080 }, { 2000, 1333, 1920, 1080 },
        { 1600, 1000, 2880, 1800 }, { 1217, 777, 1920, 1080 },
    };
    double glow;
    int n = omacvm_intro_cells(INTRO_END, cells, &glow);

    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
        int w = sizes[s][0], h = sizes[s][1], xs[SPLASH_COLS + 1], ys[SPLASH_ROWS + 1];
        IntroGeom g = omacvm_intro_geom(w, h, sizes[s][2], sizes[s][3]);
        int bad = 0;

        gl_edges(w, h, sizes[s][2], sizes[s][3], xs, ys);
        for (int i = 0; i < n; i++) {
            int c = (int)cells[i].x, r = (int)cells[i].y;
            double e[4];
            omacvm_intro_rect(&g, &cells[i], e);
            if (e[0] != xs[c] || e[2] != xs[c + 1] || e[1] != ys[r] || e[3] != ys[r + 1]) {
                if (!bad++) {
                    fprintf(stderr, "  %dx%d cell %d,%d: %g..%g x %g..%g, GL %d..%d x %d..%d\n",
                            w, h, c, r, e[0], e[2], e[1], e[3], xs[c], xs[c + 1],
                            ys[r], ys[r + 1]);
                }
            }
        }
        CHECK(!bad, "%dx%d: %d cells off GL's pixels", w, h, bad);
    }
}

static void test_motion(void)
{
    static IntroCell prev[INTRO_MAX];
    double glow, most = 0, glow_max = 0, step = 0;
    int n = omacvm_intro_cells(0, prev, &glow);

    for (int f = 1; f <= (int)(INTRO_END * 120) + 12; f++) {
        double t = f / 120.0;
        omacvm_intro_cells(t, cells, &glow);
        glow_max = fmax(glow_max, glow);
        for (int i = 0; i < n; i++) {
            step = fmax(fabs(cells[i].x - prev[i].x), fabs(cells[i].y - prev[i].y));
            most = fmax(most, step);
        }
        memcpy(prev, cells, sizeof(cells));
    }
    /* The fastest cell crosses ~30 cells in 0.8 s, eased: under 1 cell a frame. */
    CHECK(most < 1, "a cell moves %.2f cells in one frame", most);
    CHECK(glow_max > 0.3 && glow_max < 1, "glow peaks at %.3f", glow_max);
}

static void test_background(void)
{
    static uint8_t px[INTRO_BG_W * INTRO_BG_H * 4];
    double glow;
    int n = omacvm_intro_cells(INTRO_END, cells, &glow);
    int lit = 0, top = 0;

    omacvm_intro_background(cells, n, glow, px);
    for (int i = 0; i < INTRO_BG_W * INTRO_BG_H; i++) {
        lit += px[i * 4] != 0x1a || px[i * 4 + 1] != 0x1b || px[i * 4 + 2] != 0x26 ||
               px[i * 4 + 3] != 255;
    }
    CHECK(!lit, "the end's background is not plain navy (%d pixels)", lit);

    n = omacvm_intro_cells(2.05, cells, &glow);
    omacvm_intro_background(cells, n, glow, px);
    int out = 0;
    for (int i = 0; i < INTRO_BG_W * INTRO_BG_H; i++) {
        top = MAX(top, px[i * 4 + 1]);
        /* Never past the green, never under the navy. */
        out += px[i * 4 + 1] < 0x1b || px[i * 4 + 1] > 0xcd;
    }
    CHECK(!out, "%d glow pixels out of range", out);
    CHECK(top > 0x1b + 20, "no glow at its peak (green %d)", top);
}

/* A firmware-like frame: black, the logo centred at SPLASH_CELL, x8r8g8b8
 * (or x8b8g8r8 with bgr), the logo moved by dx pixels. */
static uint8_t *frame(int w, int h, bool logo, bool bgr, int dx)
{
    uint8_t *f = calloc((size_t)w * h, 4);
    int x0 = (w - SPLASH_COLS * SPLASH_CELL) / 2 + dx, y0 = (h - SPLASH_ROWS * SPLASH_CELL) / 2;

    for (int y = 0; logo && y < SPLASH_ROWS * SPLASH_CELL; y++) {
        for (int x = 0; x < SPLASH_COLS * SPLASH_CELL; x++) {
            if (omacvm_splash_cells[y / SPLASH_CELL][x / SPLASH_CELL] == '#' &&
                x0 + x >= 0 && x0 + x < w) {
                uint8_t *p = f + ((size_t)(y0 + y) * w + x0 + x) * 4;
                p[0] = bgr ? 0xa8 : 0x76;
                p[1] = 0xcd;
                p[2] = bgr ? 0x76 : 0xa8;
            }
        }
    }
    return f;
}

static void test_seen(void)
{
    uint8_t *f = frame(1920, 1080, true, false, 0);
    CHECK(omacvm_splash_seen(f, 1920 * 4, 1920, 1080, false) == SPLASH_SEEN_LOGO,
          "the firmware's frame is not seen as the logo");
    /* The progress bar and "Start boot option" under the logo do not matter. */
    memset(f + (size_t)1000 * 1920 * 4, 0xff, (size_t)20 * 1920 * 4);
    CHECK(omacvm_splash_seen(f, 1920 * 4, 1920, 1080, false) == SPLASH_SEEN_LOGO,
          "the progress bar hides the logo");
    /* GRUB's text across the logo's place. */
    memset(f + (size_t)540 * 1920 * 4, 0xaa, (size_t)16 * 1920 * 4);
    CHECK(omacvm_splash_seen(f, 1920 * 4, 1920, 1080, false) == SPLASH_SEEN_OTHER,
          "text over the logo is seen as the logo");
    free(f);
    f = frame(2880, 1800, true, true, 0);
    CHECK(omacvm_splash_seen(f, 2880 * 4, 2880, 1800, true) == SPLASH_SEEN_LOGO,
          "a bigger bgr frame is not seen as the logo");
    CHECK(omacvm_splash_seen(f, 2880 * 4, 2880, 1800, false) == SPLASH_SEEN_OTHER,
          "the logo in the wrong colours is seen as the logo");
    free(f);
    f = frame(1920, 1080, true, false, SPLASH_CELL);
    CHECK(omacvm_splash_seen(f, 1920 * 4, 1920, 1080, false) == SPLASH_SEEN_OTHER,
          "a moved logo is seen as the logo");
    free(f);
    f = frame(1920, 1080, false, false, 0);
    CHECK(omacvm_splash_seen(f, 1920 * 4, 1920, 1080, false) == SPLASH_SEEN_EMPTY,
          "a black frame is not empty");
    CHECK(omacvm_splash_seen(f, 1920 * 4, 1024, 768, false) == SPLASH_SEEN_OTHER &&
          omacvm_splash_seen(NULL, 0, 1920, 1080, false) == SPLASH_SEEN_OTHER,
          "a frame too small for the logo, or none, is not other");
    free(f);
}

int main(void)
{
    test_ends();
    test_geometry();
    test_motion();
    test_background();
    test_seen();
    if (failures) {
        fprintf(stderr, "test-boot-splash-morph: %d failures\n", failures);
        return 1;
    }
    printf("test-boot-splash-morph: OMACVM to the logo, still ends on GL's pixels, no jumps, "
           "the firmware's logo told apart\n");
    return 0;
}
