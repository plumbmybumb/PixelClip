/* tharness.h — minimal single-header test harness + helpers shared by the core tests.
 * Each test executable is one translation unit, so all state here is static. */
#ifndef THARNESS_H
#define THARNESS_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "hca.h"

static int th_checks __attribute__((unused)), th_failures __attribute__((unused)), th_tests __attribute__((unused)), th_failed_tests __attribute__((unused));

#define CHECK(cond) do { th_checks++; if (!(cond)) { th_failures++; \
    fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CHECK_EQ(a, b) do { long long _a = (long long)(a), _b = (long long)(b); th_checks++; \
    if (_a != _b) { th_failures++; fprintf(stderr, "%s:%d: CHECK_EQ failed: %s == %s (%lld vs %lld)\n", \
    __FILE__, __LINE__, #a, #b, _a, _b); } } while (0)
#define RUN(fn) do { int _f0 = th_failures; th_tests++; fn(); \
    if (th_failures != _f0) th_failed_tests++; \
    printf("%-4s %s\n", th_failures == _f0 ? "ok" : "FAIL", #fn); } while (0)
#define TH_DONE(name) (printf("%s: %d tests, %d checks, %d failed checks, %d failed tests\n", \
    name, th_tests, th_checks, th_failures, th_failed_tests), th_failures ? 1 : 0)

/* xorshift32 PRNG: deterministic across platforms. */
static uint32_t th_rng = 0x12345678u;
static inline uint32_t th_rand(void) {
    uint32_t x = th_rng;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return th_rng = x;
}

/* Native RGB565 value -> in-memory RGB565BE (file byte order). */
static inline uint16_t th_be(uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v };
    uint16_t r;
    memcpy(&r, b, 2);
    return r;
}

static inline void th_put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void th_put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

/* Assemble an .hca file in `out` from `nframes` frames of w*h pixels (frames stored back to back
 * in `px`). Returns the file size, or 0 if `cap` is too small. */
static inline size_t th_build_hca(const uint16_t *px, uint16_t w, uint16_t h, uint16_t nframes, int compression,
                           uint16_t flags, const uint16_t *durations, uint8_t *out, size_t cap) {
    size_t npx = (size_t)w * h;
    size_t table = HCA_HEADER_SIZE + (size_t)nframes * HCA_FRAME_ENTRY_SIZE;
    if (cap < table) return 0;
    memset(out, 0, table);
    size_t off = table;
    for (uint16_t i = 0; i < nframes; i++) {
        const uint16_t *f = px + (size_t)i * npx;
        size_t len;
        if (compression == HCA_COMP_RAW) {
            if (cap - off < npx * 2) return 0;
            memcpy(out + off, f, npx * 2);
            len = npx * 2;
        } else {
            len = hca_rle16_encode(f, npx, out + off, cap - off);
            if (!len) return 0;
        }
        uint8_t *e = out + HCA_HEADER_SIZE + (size_t)i * HCA_FRAME_ENTRY_SIZE;
        th_put32(e, (uint32_t)off);
        th_put32(e + 4, (uint32_t)len);
        th_put16(e + 8, durations ? durations[i] : 0);
        off += len;
    }
    memcpy(out, "HCA1", 4);
    th_put16(out + 4, w);
    th_put16(out + 6, h);
    th_put16(out + 8, nframes);
    out[10] = 0;
    out[11] = (uint8_t)compression;
    th_put16(out + 12, 0);
    th_put16(out + 14, flags);
    th_put32(out + 16, HCA_HEADER_SIZE);
    th_put32(out + 20, (uint32_t)off);
    return off;
}

#endif /* THARNESS_H */
