/* toolutil.h — shared helpers for the host tools: file I/O, RGB565BE <-> RGB888, a dependency-free
 * PNG writer (zlib with fixed-Huffman LZ77, adaptive row filters) and a PNG reader wrapper around
 * the vendored stb_image. Header-only: every tool is a single translation unit. */
#ifndef TOOLUTIL_H
#define TOOLUTIL_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("error: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(1);
}

/* Largest image the tools decode: 16 Mpx (a full strip is 8192 x 240 = 2 Mpx). A 0.5 MB .hca or a few-KB PNG can
 * claim 65535 x 65535 (8.6 GB of RGB565): refuse it before allocating. */
#define TOOL_MAX_PIXELS (16u * 1024u * 1024u)
static inline void check_pixels(const char *what, uint64_t w, uint64_t h) {
    if (w == 0 || h == 0 || w * h > TOOL_MAX_PIXELS) die("%s: %llu x %llu is more than the tools handle (%u pixels)", what,
                                                         (unsigned long long)w, (unsigned long long)h, TOOL_MAX_PIXELS);
}

static inline void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die("out of memory (%zu bytes)", n);
    return p;
}

static inline uint8_t *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) die("cannot open %s", path);
    if (fseek(f, 0, SEEK_END) != 0) die("cannot seek %s", path);
    long n = ftell(f);
    if (n < 0) die("cannot size %s", path);
    rewind(f);
    uint8_t *buf = xmalloc((size_t)n + 1);
    if (n && fread(buf, 1, (size_t)n, f) != (size_t)n) die("short read on %s", path);
    fclose(f);
    buf[n] = 0;
    *size = (size_t)n;
    return buf;
}

static inline void write_file(const char *path, const void *data, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) die("cannot create %s", path);
    if (n && fwrite(data, 1, n, f) != n) die("short write on %s", path);
    if (fclose(f) != 0) die("cannot close %s", path);
}

static inline void put16le(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void put32le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

/* In-memory RGB565BE pixel (uint16 holding bytes hi,lo) <-> RGB888 with bit replication. */
static inline uint16_t be565_from_rgb565(uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v };
    uint16_t r;
    memcpy(&r, b, 2);
    return r;
}
static inline void be565_to_rgb888(uint16_t px, uint8_t *rgb) {
    const uint8_t *b = (const uint8_t *)&px;
    unsigned v = ((unsigned)b[0] << 8) | b[1];
    unsigned r = v >> 11, g = (v >> 5) & 63, bl = v & 31;
    rgb[0] = (uint8_t)((r << 3) | (r >> 2));
    rgb[1] = (uint8_t)((g << 2) | (g >> 4));
    rgb[2] = (uint8_t)((bl << 3) | (bl >> 2));
}

/* ---- PNG writer --------------------------------------------------------------------------- */

typedef struct { uint8_t *buf; size_t len, cap; uint32_t bits; int nbits; } bytebuf_t;

static inline void bb_byte(bytebuf_t *b, uint8_t v) {
    if (b->len == b->cap) {
        b->cap = b->cap ? b->cap * 2 : 65536;
        b->buf = realloc(b->buf, b->cap);
        if (!b->buf) die("out of memory");
    }
    b->buf[b->len++] = v;
}
static inline void bb_bytes(bytebuf_t *b, const void *p, size_t n) {
    for (size_t i = 0; i < n; i++) bb_byte(b, ((const uint8_t *)p)[i]);
}
static inline void bb_be32(bytebuf_t *b, uint32_t v) {
    bb_byte(b, (uint8_t)(v >> 24)); bb_byte(b, (uint8_t)(v >> 16)); bb_byte(b, (uint8_t)(v >> 8)); bb_byte(b, (uint8_t)v);
}
/* LSB-first bit writer (deflate). */
static inline void bb_bits(bytebuf_t *b, uint32_t v, int n) {
    b->bits |= v << b->nbits;
    b->nbits += n;
    while (b->nbits >= 8) { bb_byte(b, (uint8_t)b->bits); b->bits >>= 8; b->nbits -= 8; }
}
/* Huffman codes are defined MSB-first: reverse before emitting. */
static inline void bb_huff(bytebuf_t *b, uint32_t code, int n) {
    uint32_t r = 0;
    for (int i = 0; i < n; i++) r |= ((code >> i) & 1u) << (n - 1 - i);
    bb_bits(b, r, n);
}
static inline void deflate_lit(bytebuf_t *b, unsigned v) {
    if (v < 144) bb_huff(b, 0x30 + v, 8);
    else if (v < 256) bb_huff(b, 0x190 + (v - 144), 9);
    else if (v < 280) bb_huff(b, v - 256, 7);
    else bb_huff(b, 0xC0 + (v - 280), 8);
}
static inline void deflate_match(bytebuf_t *b, unsigned len, unsigned dist) {
    static const uint16_t lbase[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
                                        67, 83, 99, 115, 131, 163, 195, 227, 258 };
    static const uint8_t lext[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    static const uint16_t dbase[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                                        1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
    static const uint8_t dext[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
    int li = 28;
    while (lbase[li] > len) li--;
    deflate_lit(b, 257u + (unsigned)li);
    if (lext[li]) bb_bits(b, len - lbase[li], lext[li]);
    int di = 29;
    while (dbase[di] > dist) di--;
    bb_huff(b, (uint32_t)di, 5);
    if (dext[di]) bb_bits(b, dist - dbase[di], dext[di]);
}

/* zlib stream: one fixed-Huffman block, greedy LZ77 with hash chains. */
static inline void zlib_compress(bytebuf_t *out, const uint8_t *d, size_t n) {
    enum { WIN = 32768, HBITS = 15, MAXCHAIN = 32 };
    int32_t *head = xmalloc(sizeof(int32_t) << HBITS);
    int32_t *prev = xmalloc(sizeof(int32_t) * WIN);
    for (size_t i = 0; i < (1u << HBITS); i++) head[i] = -1;
    bb_byte(out, 0x78); bb_byte(out, 0x01);
    bb_bits(out, 1, 1);           /* BFINAL */
    bb_bits(out, 1, 2);           /* BTYPE = fixed Huffman */
    size_t i = 0;
#define HASH3(p) ((((uint32_t)(p)[0] << 10) ^ ((uint32_t)(p)[1] << 5) ^ (p)[2]) & ((1u << HBITS) - 1))
    while (i < n) {
        unsigned best = 0, bdist = 0;
        if (i + 3 <= n) {
            uint32_t h = HASH3(d + i);
            int32_t c = head[h];
            for (int chain = 0; c >= 0 && chain < MAXCHAIN && i - (size_t)c <= WIN - 1; chain++) {
                unsigned l = 0, maxl = (unsigned)(n - i < 258 ? n - i : 258);
                while (l < maxl && d[(size_t)c + l] == d[i + l]) l++;
                if (l > best) { best = l; bdist = (unsigned)(i - (size_t)c); if (l == maxl) break; }
                int32_t nc = prev[c % WIN];
                if (nc >= c) break;
                c = nc;
            }
            prev[i % WIN] = head[h];
            head[h] = (int32_t)i;
        }
        if (best >= 3) {
            deflate_match(out, best, bdist);
            for (size_t k = 1; k < best; k++) {        /* index the skipped positions */
                size_t p = i + k;
                if (p + 3 <= n) { uint32_t h = HASH3(d + p); prev[p % WIN] = head[h]; head[h] = (int32_t)p; }
            }
            i += best;
        } else {
            deflate_lit(out, d[i]);
            i++;
        }
    }
#undef HASH3
    deflate_lit(out, 256);
    if (out->nbits) bb_bits(out, 0, 8 - out->nbits);
    uint32_t a = 1, b2 = 0;
    for (size_t k = 0; k < n; k++) { a = (a + d[k]) % 65521u; b2 = (b2 + a) % 65521u; }
    bb_be32(out, (b2 << 16) | a);
    free(head);
    free(prev);
}

static inline uint32_t crc32_update(uint32_t crc, const uint8_t *p, size_t n) {
    static uint32_t table[256];
    static int init;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = 1;
    }
    crc = ~crc;
    for (size_t i = 0; i < n; i++) crc = table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

static inline void png_chunk(bytebuf_t *f, const char *type, const uint8_t *data, size_t n) {
    bb_be32(f, (uint32_t)n);
    size_t start = f->len;
    bb_bytes(f, type, 4);
    bb_bytes(f, data, n);
    bb_be32(f, crc32_update(0, f->buf + start, n + 4));
}

static inline int paeth(int a, int b, int c) {
    int p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c);
    return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
}

/* Write an 8-bit RGB PNG. Per-row adaptive filter (min sum of |signed residual|). */
static inline void write_png_rgb(const char *path, const uint8_t *rgb, int w, int h) {
    size_t stride = (size_t)w * 3;
    uint8_t *raw = xmalloc((stride + 1) * (size_t)h), *cand = xmalloc(stride);
    for (int y = 0; y < h; y++) {
        const uint8_t *row = rgb + (size_t)y * stride, *up = y ? row - stride : NULL;
        long best = -1;
        uint8_t *dst = raw + (size_t)y * (stride + 1);
        for (int ft = 0; ft < 5; ft++) {
            long cost = 0;
            for (size_t i = 0; i < stride; i++) {
                int a = i >= 3 ? row[i - 3] : 0, b = up ? up[i] : 0, c = (up && i >= 3) ? up[i - 3] : 0;
                int pred = ft == 0 ? 0 : ft == 1 ? a : ft == 2 ? b : ft == 3 ? (a + b) / 2 : paeth(a, b, c);
                cand[i] = (uint8_t)(row[i] - pred);
                cost += (signed char)cand[i] < 0 ? -(signed char)cand[i] : (signed char)cand[i];
            }
            if (best < 0 || cost < best) { best = cost; dst[0] = (uint8_t)ft; memcpy(dst + 1, cand, stride); }
        }
    }
    bytebuf_t z = { 0 }, f = { 0 };
    zlib_compress(&z, raw, (stride + 1) * (size_t)h);
    static const uint8_t sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    bb_bytes(&f, sig, 8);
    uint8_t ihdr[13] = { 0 };
    ihdr[0] = (uint8_t)(w >> 24); ihdr[1] = (uint8_t)(w >> 16); ihdr[2] = (uint8_t)(w >> 8); ihdr[3] = (uint8_t)w;
    ihdr[4] = (uint8_t)(h >> 24); ihdr[5] = (uint8_t)(h >> 16); ihdr[6] = (uint8_t)(h >> 8); ihdr[7] = (uint8_t)h;
    ihdr[8] = 8;   /* bit depth */
    ihdr[9] = 2;   /* colour type RGB */
    png_chunk(&f, "IHDR", ihdr, 13);
    png_chunk(&f, "IDAT", z.buf, z.len);
    png_chunk(&f, "IEND", NULL, 0);
    write_file(path, f.buf, f.len);
    free(z.buf); free(f.buf); free(raw); free(cand);
}

/* Write w*h RGB565BE pixels (row stride `stride` px) as an RGB PNG, nearest-neighbour upscaled. */
static inline void write_png_565(const char *path, const uint16_t *px, int w, int h, int stride, int scale) {
    if (scale < 1) scale = 1;
    int W = w * scale, H = h * scale;
    uint8_t *rgb = xmalloc((size_t)W * H * 3);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) be565_to_rgb888(px[(size_t)(y / scale) * stride + x / scale], rgb + ((size_t)y * W + x) * 3);
    write_png_rgb(path, rgb, W, H);
    free(rgb);
}

#endif /* TOOLUTIL_H */
