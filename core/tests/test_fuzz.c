/* test_fuzz.c — feed thousands of random / mutated inputs to every .hca decoder entry point.
 * Passing means: no crash, no sanitizer report (build with HCA_SANITIZE=ON or run_asan.sh), and
 * invariants hold (decoders only return documented codes). Inputs live in exact-size heap
 * allocations so AddressSanitizer catches any out-of-bounds read or write. */
#include "tharness.h"

/* Iteration counts; multiply with HCA_FUZZ_SCALE=<n> in the environment for longer runs. */
static int scale = 1;
#define ITER_RANDOM (3000 * scale)
#define ITER_MUTATE (4000 * scale)
#define ITER_STREAM (3000 * scale)

static int valid_status(hca_status_t s) { return s >= HCA_OK && s <= HCA_ERR_ARG; }

static size_t opened, decoded_ok, blits;

/* Exercise every accessor on a buffer. */
static void poke(const uint8_t *buf, size_t n) {
    uint8_t *copy = malloc(n ? n : 1);
    memcpy(copy, buf, n);
    hca_asset_t a;
    hca_status_t st = hca_open(&a, copy, n);
    CHECK(valid_status(st));
    if (st == HCA_OK) {
        opened++;
        uint64_t npx = (uint64_t)a.hdr.width * a.hdr.height;
        uint16_t frames = a.hdr.frame_count < 8 ? a.hdr.frame_count : 8;
        for (uint16_t i = 0; i < frames + 1; i++) {
            hca_frame_info_t fi;
            CHECK(valid_status(hca_frame_info(&a, i, &fi)));
            (void)hca_frame_duration(&a, i, 100);
            if (npx <= (1u << 20)) {
                uint16_t *dst = malloc((size_t)npx * 2);
                st = hca_decode_frame(&a, i, dst, a.hdr.width);
                CHECK(valid_status(st));
                if (st == HCA_OK) decoded_ok++;
                free(dst);
                if (a.hdr.width < 60000) {   /* strided */
                    uint16_t stride = (uint16_t)(a.hdr.width + 3);
                    uint16_t *d2 = malloc(((size_t)a.hdr.height - 1) * stride * 2 + (size_t)a.hdr.width * 2);
                    CHECK(valid_status(hca_decode_frame(&a, i, d2, stride)));
                    free(d2);
                }
            }
            uint16_t *fb = malloc(37 * 23 * 2);
            int x = (int)(th_rand() % 120) - 60, y = (int)(th_rand() % 80) - 40;
            CHECK(valid_status(hca_blit_frame(&a, i, fb, 37, 23, x, y)));
            blits++;
            free(fb);
        }
    }
    free(copy);
}

static size_t make_valid(uint8_t *out, size_t cap) {
    uint16_t w = (uint16_t)(1 + th_rand() % 24), h = (uint16_t)(1 + th_rand() % 12);
    uint16_t nf = (uint16_t)(1 + th_rand() % 4);
    static uint16_t px[24 * 12 * 4];
    uint16_t colour = (uint16_t)th_rand();
    for (int i = 0; i < w * h * nf; i++) {
        if (th_rand() % 4 == 0) colour = (uint16_t)th_rand();
        px[i] = colour;
    }
    return th_build_hca(px, w, h, nf, (int)(th_rand() % 2), (uint16_t)(th_rand() % 2), NULL, out, cap);
}

static void fuzz_hca(void) {
    static uint8_t buf[4096];
    /* pure random, half of them with a valid magic and plausible header */
    for (int it = 0; it < ITER_RANDOM; it++) {
        size_t n = th_rand() % 2048;
        for (size_t i = 0; i < n; i++) buf[i] = (uint8_t)th_rand();
        if ((it & 1) && n >= 32) {
            memcpy(buf, "HCA1", 4);
            th_put16(buf + 4, 1 + th_rand() % 40);
            th_put16(buf + 6, 1 + th_rand() % 40);
            th_put16(buf + 8, 1 + th_rand() % 6);
            buf[10] = 0;
            buf[11] = (uint8_t)(th_rand() % 2);
            th_put32(buf + 16, 32);
            th_put32(buf + 20, (uint32_t)n);
        }
        poke(buf, n);
    }
    /* mutated valid files */
    for (int it = 0; it < ITER_MUTATE; it++) {
        size_t n = make_valid(buf, sizeof buf);
        CHECK(n > 0);
        int muts = 1 + (int)(th_rand() % 6);
        for (int m = 0; m < muts; m++) {
            switch (th_rand() % 5) {
            case 0: buf[th_rand() % n] ^= (uint8_t)(1u << (th_rand() % 8)); break;
            case 1: buf[th_rand() % n] = (uint8_t)th_rand(); break;
            case 2: n = 1 + th_rand() % n; break;                                  /* truncate */
            case 3: if (n + 16 < sizeof buf) { for (int k = 0; k < 16; k++) buf[n++] = (uint8_t)th_rand(); } break;
            case 4: if (n > 32) buf[32 + th_rand() % (n - 32)] = (uint8_t)(th_rand() & 1 ? 0xFF : 0x00); break;
            }
        }
        poke(buf, n);
    }
    /* raw RLE streams against small geometries via hca_decode_frame_from */
    for (int it = 0; it < ITER_STREAM; it++) {
        hca_header_t h = { (uint16_t)(1 + th_rand() % 50), (uint16_t)(1 + th_rand() % 20), 1, 0, HCA_COMP_RLE16, 0, 0, 32, 0 };
        size_t n = th_rand() % 600;
        uint8_t *s = malloc(n ? n : 1);
        for (size_t i = 0; i < n; i++) s[i] = (uint8_t)th_rand();
        /* bias control words toward plausible run lengths */
        for (size_t i = 0; i + 1 < n; i += 2 + (th_rand() % 3) * 2) {
            s[i] = (uint8_t)(th_rand() % 64);
            s[i + 1] = (uint8_t)(th_rand() & 0x80);
        }
        uint16_t *d = malloc((size_t)h.width * h.height * 2);
        CHECK(valid_status(hca_decode_frame_from(&h, s, n, d, h.width)));
        free(d);
        free(s);
    }
    printf("     opened %zu, decoded %zu frames, %zu blits\n", opened, decoded_ok, blits);
    CHECK(opened > 1000);
    CHECK(decoded_ok > 1000);
}

int main(void) {
    const char *env = getenv("HCA_FUZZ_SCALE");
    if (env && atoi(env) > 0) scale = atoi(env);
    if (getenv("HCA_FUZZ_SEED")) th_rng = (uint32_t)strtoul(getenv("HCA_FUZZ_SEED"), NULL, 0) | 1u;
    RUN(fuzz_hca);
    return TH_DONE("test_fuzz");
}
