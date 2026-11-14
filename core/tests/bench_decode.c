/* bench_decode.c — host throughput of the RLE16 decoder on 536x240 frames.
 * Usage: bench_decode [--quick]   (prints frames/s and MB/s of output per content type) */
#include "tharness.h"
#include "hca.h"
#include <time.h>

#define W 536
#define H 240
#define NPX (W * H)

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint16_t src[NPX], dst[NPX];
static uint8_t enc[NPX * 2 + 64];

static uint16_t rgb(int r, int g, int b) { return th_be((uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))); }

static void bench(const char *name, double budget) {
    size_t n = hca_rle16_encode(src, NPX, enc, sizeof enc);
    hca_header_t hdr = { W, H, 1, 0, HCA_COMP_RLE16, 0, 0, 32, 0 };
    if (hca_decode_frame_from(&hdr, enc, n, dst, W) != HCA_OK || memcmp(src, dst, sizeof src)) {
        printf("%s: DECODE MISMATCH\n", name);
        exit(1);
    }
    long iters = 0;
    double t0 = now_s(), t;
    do {
        for (int k = 0; k < 16; k++) (void)hca_decode_frame_from(&hdr, enc, n, dst, W);
        iters += 16;
        t = now_s() - t0;
    } while (t < budget);
    double fps = (double)iters / t;
    printf("  %-26s %7zu B (%5.1f%% of raw)  %9.0f frames/s  %7.0f MB/s out\n", name, n,
           100.0 * (double)n / (NPX * 2), fps, fps * NPX * 2 / 1e6);
}

int main(int argc, char **argv) {
    double budget = (argc > 1 && !strcmp(argv[1], "--quick")) ? 0.15 : 1.0;
    printf("RLE16 decode, 536x240 RGB565 (%d px), contiguous destination:\n", NPX);

    memset(src, 0, sizeof src);
    bench("all black", budget);

    /* typical dark animation frame: black, a filled circle, some horizontal bars */
    memset(src, 0, sizeof src);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int dx = x - 200, dy = y - 120;
            if (dx * dx + dy * dy < 70 * 70) src[y * W + x] = rgb(255, 120, 40);
            else if (y > 200 && y < 215 && x > 50 && x < 480 && (x / 9) % 2) src[y * W + x] = rgb(255, 255, 255);
        }
    bench("dark frame (circle+bars)", budget);

    /* sign-like: dark panel, white header band, yellow blocks */
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            uint16_t c = rgb(10, 20, 40);
            if (y < 40) c = rgb(255, 255, 255);
            else if (y > 228) c = rgb(255, 205, 0);
            else if (y > 92 && y < 192 && ((x > 110 && x < 230) || (x > 290 && x < 410)) && ((x / 6 + y / 10) % 3)) c = rgb(255, 199, 44);
            src[y * W + x] = c;
        }
    bench("sign-like", budget);

    /* dithered gradient: lots of short literal runs */
    static const int bayer[4][4] = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } };
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int b = bayer[y & 3][x & 3];
            int r = x * 255 / (W - 1), g = y * 255 / (H - 1), bl = 128;
            int R = (r * 31 * 32 + (2 * b + 1) * 255) / (255 * 32);
            int G = (g * 63 * 32 + (2 * b + 1) * 255) / (255 * 32);
            int B = (bl * 31 * 32 + (2 * b + 1) * 255) / (255 * 32);
            src[y * W + x] = th_be((uint16_t)((R << 11) | (G << 5) | B));
        }
    bench("dithered gradient", budget);

    for (int i = 0; i < NPX; i++) src[i] = (uint16_t)th_rand();
    bench("noise (worst case)", budget);

    /* memcpy reference */
    double t0 = now_s(), t;
    long iters = 0;
    do { memcpy(dst, src, sizeof dst); iters++; t = now_s() - t0; } while (t < budget);
    printf("  %-26s %9.0f frames/s (memcpy of a raw frame, reference)\n", "raw memcpy", iters / t);
    return 0;
}
