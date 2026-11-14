/* test_hca.c — .hca header parsing, RLE16 codec, clipping. */
#include "tharness.h"
#include "hca_internal.h"
#include <limits.h>

#define W 536
#define H 240
#define NPX (W * H)

static uint16_t g_src[NPX * 3];
static uint16_t g_dst[(W + 16) * H];
static uint8_t g_file[NPX * 2 * 3 + 4096];

/* ---- header parsing --------------------------------------------------------------------- */

static size_t small_file(uint8_t *out, size_t cap, int comp) {
    uint16_t px[2 * 8 * 4];
    for (int i = 0; i < 64; i++) px[i] = th_be((uint16_t)(i < 40 ? 0x1234 : i * 77));
    uint16_t dur[2] = { 0, 250 };
    return th_build_hca(px, 8, 4, 2, comp, HCA_FLAG_GLYPH_ATLAS, dur, out, cap);
}

static void test_header_ok(void) {
    uint8_t f[1024];
    size_t n = small_file(f, sizeof f, HCA_COMP_RLE16);
    CHECK(n > 0);
    hca_asset_t a;
    CHECK_EQ(hca_open(&a, f, n), HCA_OK);
    CHECK_EQ(a.hdr.width, 8);
    CHECK_EQ(a.hdr.height, 4);
    CHECK_EQ(a.hdr.frame_count, 2);
    CHECK_EQ(a.hdr.compression, HCA_COMP_RLE16);
    CHECK_EQ(a.hdr.flags, HCA_FLAG_GLYPH_ATLAS);
    CHECK_EQ(a.hdr.frame_table_off, 32);
    CHECK_EQ(a.hdr.data_size, n);
    CHECK_EQ(hca_table_bytes(2), 56);
    hca_frame_info_t fi;
    CHECK_EQ(hca_frame_info(&a, 1, &fi), HCA_OK);
    CHECK_EQ(fi.duration_ms, 250);
    CHECK(fi.offset >= 56 && fi.offset + fi.length <= n);
    CHECK_EQ(hca_frame_info(&a, 2, &fi), HCA_ERR_BAD_FRAME);
    CHECK_EQ(hca_frame_duration(&a, 0, 100), 100);
    CHECK_EQ(hca_frame_duration(&a, 1, 100), 250);
    CHECK_EQ(hca_frame_duration(&a, 9, 77), 77);
    /* trailing bytes after data_size are tolerated (e.g. flash slack) */
    CHECK_EQ(hca_open(&a, f, n + 10), HCA_OK);
    CHECK(strcmp(hca_status_str(HCA_ERR_CORRUPT), "corrupt") == 0);
}

static void test_header_truncated(void) {
    uint8_t f[1024];
    size_t n = small_file(f, sizeof f, HCA_COMP_RLE16);
    hca_asset_t a;
    for (size_t s = 0; s < hca_table_bytes(2); s++) CHECK_EQ(hca_open(&a, f, s), HCA_ERR_TRUNCATED);
    /* header+table only: a partial view; decode needs hca_decode_frame_from */
    CHECK_EQ(hca_open(&a, f, hca_table_bytes(2)), HCA_OK);
    uint16_t out[32];
    CHECK_EQ(hca_decode_frame(&a, 0, out, 8), HCA_ERR_TRUNCATED);
    CHECK_EQ(hca_blit_frame(&a, 0, out, 8, 4, 0, 0), HCA_ERR_TRUNCATED);
    hca_frame_info_t fi;
    CHECK_EQ(hca_frame_info(&a, 1, &fi), HCA_OK);
    CHECK_EQ(hca_decode_frame_from(&a.hdr, f + fi.offset, fi.length, out, 8), HCA_OK);
    CHECK_EQ(out[0], th_be(0x1234));
    CHECK_EQ(out[31], th_be((uint16_t)(63 * 77)));
    CHECK_EQ(hca_open(&a, f, n), HCA_OK);
}

static void test_header_bad(void) {
    uint8_t f[1024], g[1024];
    size_t n = small_file(f, sizeof f, HCA_COMP_RLE16);
    hca_asset_t a;
#define MUT(stmt, expect) do { memcpy(g, f, n); stmt; CHECK_EQ(hca_open(&a, g, n), expect); } while (0)
    MUT(g[0] = 'X', HCA_ERR_BAD_MAGIC);
    MUT(g[3] = '2', HCA_ERR_BAD_MAGIC);
    MUT(g[10] = 1, HCA_ERR_UNSUPPORTED);                    /* pixel format */
    MUT(g[11] = 2, HCA_ERR_UNSUPPORTED);                    /* compression */
    MUT(th_put32(g + 16, 40), HCA_ERR_UNSUPPORTED);         /* frame_table_off != 32 */
    MUT(th_put16(g + 4, 0), HCA_ERR_UNSUPPORTED);           /* width 0 */
    MUT(th_put16(g + 6, 0), HCA_ERR_UNSUPPORTED);           /* height 0 */
    MUT(th_put16(g + 8, 0), HCA_ERR_BAD_FRAME);             /* frame_count 0 */
    MUT(th_put32(g + 20, 40), HCA_ERR_BAD_FRAME);           /* data_size < table */
    MUT(th_put32(g + 20, (uint32_t)n - 1), HCA_ERR_BAD_FRAME); /* last frame past data_size */
    MUT(th_put32(g + 32, 20), HCA_ERR_BAD_FRAME);           /* frame 0 offset inside header */
    MUT(th_put32(g + 32, 50), HCA_ERR_BAD_FRAME);           /* frame 0 offset inside table */
    MUT(th_put32(g + 36, 0), HCA_ERR_BAD_FRAME);            /* zero length */
    MUT(th_put32(g + 36, 2), HCA_ERR_BAD_FRAME);            /* shorter than one run */
    MUT(th_put32(g + 48, 0xFFFFFFF0u), HCA_ERR_BAD_FRAME);  /* huge length (overflow) */
    MUT(th_put32(g + 44, 0xFFFFFFF0u), HCA_ERR_BAD_FRAME);  /* huge offset (overflow) */
    MUT(th_put16(g + 8, 200), HCA_ERR_BAD_FRAME);           /* count > table: data_size < table */
    {   /* odd RLE length */
        memcpy(g, f, n);
        uint32_t len = g[36] | (uint32_t)g[37] << 8;
        th_put32(g + 36, len - 1);
        CHECK_EQ(hca_open(&a, g, n), HCA_ERR_BAD_FRAME);
    }
    /* raw: length must be exactly w*h*2 */
    n = small_file(f, sizeof f, HCA_COMP_RAW);
    CHECK_EQ(hca_open(&a, f, n), HCA_OK);
    MUT(th_put32(g + 36, 62), HCA_ERR_BAD_FRAME);
    /* NULL args */
    CHECK_EQ(hca_open(NULL, f, n), HCA_ERR_ARG);
    CHECK_EQ(hca_open(&a, NULL, n), HCA_ERR_ARG);
    CHECK_EQ(hca_open(&a, f, n), HCA_OK);
    uint16_t out[64];
    CHECK_EQ(hca_decode_frame(&a, 0, NULL, 8), HCA_ERR_ARG);
    CHECK_EQ(hca_decode_frame(&a, 0, out, 7), HCA_ERR_ARG);      /* stride < width */
    CHECK_EQ(hca_decode_frame(&a, 2, out, 8), HCA_ERR_BAD_FRAME);
    CHECK_EQ(hca_decode_frame(NULL, 0, out, 8), HCA_ERR_ARG);
    CHECK_EQ(hca_blit_frame(&a, 0, out, 0, 4, 0, 0), HCA_ERR_ARG);
#undef MUT
}

/* ---- RLE round trips -------------------------------------------------------------------- */

static void roundtrip(const uint16_t *src, uint16_t w, uint16_t h, const char *what) {
    size_t npx = (size_t)w * h;
    size_t worst = npx * 2 + 2 * ((npx + 32767) / 32768);
    static uint8_t enc[NPX * 2 + 64];
    size_t n = hca_rle16_encode(src, npx, enc, sizeof enc);
    CHECK(n > 0 && n <= worst);
    CHECK(hca_rle16_encode(src, npx, enc, worst) == n);  /* the documented worst case suffices */
    hca_header_t hdr = { w, h, 1, HCA_PIXFMT_RGB565BE, HCA_COMP_RLE16, 0, 0, 32, 0 };

    memset(g_dst, 0xA5, sizeof g_dst);
    CHECK_EQ(hca_decode_frame_from(&hdr, enc, n, g_dst, w), HCA_OK);
    int same = memcmp(g_dst, src, npx * 2) == 0;
    CHECK(same);
    CHECK_EQ(g_dst[npx], 0xA5A5);                      /* nothing written past the frame */

    /* strided destination: padding columns untouched */
    uint16_t stride = (uint16_t)(w + 13);
    if ((size_t)stride * h <= sizeof g_dst / 2) {
        memset(g_dst, 0x5A, sizeof g_dst);
        CHECK_EQ(hca_decode_frame_from(&hdr, enc, n, g_dst, stride), HCA_OK);
        int ok = 1;
        for (size_t y = 0; y < h && ok; y++) {
            if (memcmp(g_dst + y * stride, src + y * w, (size_t)w * 2)) ok = 0;
            for (size_t x = w; x < stride; x++) if (g_dst[y * stride + x] != 0x5A5A) ok = 0;
        }
        CHECK(ok);
    }
    if (!same) fprintf(stderr, "  roundtrip mismatch: %s\n", what);
}

static void test_rle_roundtrip(void) {
    /* all black */
    memset(g_src, 0, NPX * 2);
    roundtrip(g_src, W, H, "black");
    CHECK_EQ(hca_rle16_encode(g_src, NPX, g_file, sizeof g_file), 4 * ((NPX + 32767) / 32768));

    /* all noise */
    for (int i = 0; i < NPX; i++) g_src[i] = (uint16_t)th_rand();
    roundtrip(g_src, W, H, "noise");

    /* random runs of length 1..300 (incl. 2-pixel runs that must stay literal) */
    for (int rep = 0; rep < 8; rep++) {
        int i = 0;
        while (i < NPX) {
            int len = 1 + (int)(th_rand() % (rep & 1 ? 4 : 300));
            uint16_t v = (uint16_t)(th_rand() % 6);   /* few colours: runs often merge */
            for (int k = 0; k < len && i < NPX; k++) g_src[i++] = v;
        }
        roundtrip(g_src, W, H, "random runs");
    }

    /* run-boundary crossing: odd widths so runs straddle rows */
    for (uint16_t w = 1; w <= 37; w += 3) {
        uint16_t h = 23;
        for (int i = 0; i < w * h; i++) g_src[i] = (uint16_t)((i / 10) & 1 ? 0xFFFF : 0x0841 * (i / 20 % 3));
        roundtrip(g_src, w, h, "crossing");
    }

    /* gradient-like content */
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) g_src[y * W + x] = th_be((uint16_t)(((x >> 4) << 11) | ((y >> 2) << 5)));
    roundtrip(g_src, W, H, "gradient");

    /* single pixel frame and tiny frames */
    g_src[0] = 0xBEEF;
    roundtrip(g_src, 1, 1, "1x1");
    for (int i = 0; i < 3; i++) g_src[i] = 7;
    roundtrip(g_src, 3, 1, "3x1");
}

static void test_encoder_format(void) {
    /* [A,A,B,C,C,C,D] -> literal(3) A A B, repeat(3) C, literal(1) D */
    uint16_t A = th_be(0x1111), B = th_be(0x2222), C = th_be(0x3333), D = th_be(0x4444);
    uint16_t px[7] = { A, A, B, C, C, C, D };
    uint8_t out[64];
    size_t n = hca_rle16_encode(px, 7, out, sizeof out);
    const uint8_t want[] = { 0x02, 0x00, 0x11, 0x11, 0x11, 0x11, 0x22, 0x22,
                             0x02, 0x80, 0x33, 0x33,
                             0x00, 0x00, 0x44, 0x44 };
    CHECK_EQ(n, sizeof want);
    CHECK(memcmp(out, want, sizeof want) == 0);
    /* byte order on the wire: pixel 0xF800 (red) is stored F8 00 */
    uint16_t red = th_be(0xF800);
    n = hca_rle16_encode(&red, 1, out, sizeof out);
    CHECK_EQ(n, 4);
    CHECK(out[0] == 0 && out[1] == 0 && out[2] == 0xF8 && out[3] == 0x00);
    /* capacity too small -> 0 */
    CHECK_EQ(hca_rle16_encode(px, 7, out, 15), 0);
    CHECK_EQ(hca_rle16_encode(px, 7, out, 0), 0);
    CHECK_EQ(hca_rle16_encode(px, 0, out, sizeof out), 0);
    /* decoded buffer keeps file byte order */
    hca_header_t hdr = { 1, 1, 1, 0, HCA_COMP_RLE16, 0, 0, 32, 0 };
    const uint8_t s[] = { 0x00, 0x80, 0xF8, 0x1F };
    uint16_t d = 0;
    CHECK_EQ(hca_decode_frame_from(&hdr, s, 4, &d, 1), HCA_OK);
    CHECK(((uint8_t *)&d)[0] == 0xF8 && ((uint8_t *)&d)[1] == 0x1F);
}

static void test_max_runs(void) {
    hca_header_t hdr = { 32768, 1, 1, 0, HCA_COMP_RLE16, 0, 0, 32, 0 };
    static uint16_t out[65536 + 8];
    static uint8_t s[65536 * 2 + 64];
    /* a single repeat run of the maximum length 32768 (control 0xFFFF) */
    s[0] = 0xFF; s[1] = 0xFF; s[2] = 0x12; s[3] = 0x34;
    CHECK_EQ(hca_decode_frame_from(&hdr, s, 4, out, 32768), HCA_OK);
    CHECK(out[0] == th_be(0x1234) && out[32767] == th_be(0x1234));
    /* a single literal run of 32768 (control 0x7FFF) */
    s[0] = 0xFF; s[1] = 0x7F;
    for (int i = 0; i < 32768; i++) { s[2 + 2 * i] = (uint8_t)(i >> 8); s[3 + 2 * i] = (uint8_t)i; }
    CHECK_EQ(hca_decode_frame_from(&hdr, s, 2 + 65536, out, 32768), HCA_OK);
    CHECK(out[300] == th_be(300) && out[32767] == th_be(32767));
    /* 32768-run into a 32767-pixel frame: overrun */
    hdr.width = 32767;
    s[0] = 0xFF; s[1] = 0xFF;
    CHECK_EQ(hca_decode_frame_from(&hdr, s, 4, out, 32767), HCA_ERR_CORRUPT);

    /* encoder splits long runs at 32768 */
    for (int i = 0; i < 65541; i++) g_src[i] = 0x4242;
    size_t n = hca_rle16_encode(g_src, 65541, g_file, sizeof g_file);
    CHECK_EQ(n, 12);                                  /* 32768 + 32768 + 5 */
    CHECK(g_file[0] == 0xFF && g_file[1] == 0xFF && g_file[4] == 0xFF && g_file[5] == 0xFF);
    CHECK(g_file[8] == 0x04 && g_file[9] == 0x80);
    n = hca_rle16_encode(g_src, 32769, g_file, sizeof g_file);
    CHECK_EQ(n, 8);                                   /* 32768 repeat + 1 literal */
    hca_header_t h2 = { 32769, 1, 1, 0, HCA_COMP_RLE16, 0, 0, 32, 0 };
    CHECK_EQ(hca_decode_frame_from(&h2, g_file, n, out, 32769), HCA_OK);
    CHECK(out[32768] == 0x4242);
    /* long literal split at 32768 */
    for (int i = 0; i < 40000; i++) g_src[i] = (uint16_t)i;
    n = hca_rle16_encode(g_src, 40000, g_file, sizeof g_file);
    CHECK_EQ(n, 4 + 80000);
    hca_header_t h3 = { 40000, 1, 1, 0, HCA_COMP_RLE16, 0, 0, 32, 0 };
    CHECK_EQ(hca_decode_frame_from(&h3, g_file, n, out, 40000), HCA_OK);
    CHECK(memcmp(out, g_src, 80000) == 0);
}

static void test_corrupt_streams(void) {
    hca_header_t hdr = { 4, 2, 1, 0, HCA_COMP_RLE16, 0, 0, 32, 0 };
    uint16_t out[16];
    struct { const uint8_t *s; size_t n; hca_status_t want; const char *what; } cases[] = {
        { (const uint8_t *)"\x07\x80\x01\x02", 4, HCA_OK, "repeat 8 exact" },
        { (const uint8_t *)"\x08\x80\x01\x02", 4, HCA_ERR_CORRUPT, "repeat 9 overruns" },
        { (const uint8_t *)"\x06\x80\x01\x02", 4, HCA_ERR_CORRUPT, "repeat 7 underruns" },
        { (const uint8_t *)"\x07\x80\x01\x02\x00\x00", 6, HCA_ERR_CORRUPT, "trailing bytes" },
        { (const uint8_t *)"\x07\x80\x01", 3, HCA_ERR_CORRUPT, "repeat pixel cut" },
        { (const uint8_t *)"\x07\x80", 2, HCA_ERR_CORRUPT, "repeat pixel missing" },
        { (const uint8_t *)"\x07", 1, HCA_ERR_CORRUPT, "half control word" },
        { (const uint8_t *)"", 0, HCA_ERR_CORRUPT, "empty" },
        { (const uint8_t *)"\x07\x00\x01\x02\x03\x04", 6, HCA_ERR_CORRUPT, "literal short" },
        { (const uint8_t *)"\xff\x7f\x01\x02", 4, HCA_ERR_CORRUPT, "literal 32768 overrun" },
        { (const uint8_t *)"\x03\x80\x01\x02\x03\x80\x05\x06", 8, HCA_OK, "two repeats" },
        { (const uint8_t *)"\x03\x80\x01\x02\x03\x80\x05", 7, HCA_ERR_CORRUPT, "second cut" },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        hca_status_t st = hca_decode_frame_from(&hdr, cases[i].s, cases[i].n, out, 4);
        if (st != cases[i].want) fprintf(stderr, "  case '%s'\n", cases[i].what);
        CHECK_EQ(st, cases[i].want);
        st = hca_decode_frame_from(&hdr, cases[i].s, cases[i].n, out, 5);   /* strided path */
        CHECK_EQ(st, cases[i].want);
    }
    /* raw sizes */
    hdr.compression = HCA_COMP_RAW;
    uint8_t raw[18] = { 0 };
    CHECK_EQ(hca_decode_frame_from(&hdr, raw, 16, out, 4), HCA_OK);
    CHECK_EQ(hca_decode_frame_from(&hdr, raw, 15, out, 4), HCA_ERR_TRUNCATED);
    CHECK_EQ(hca_decode_frame_from(&hdr, raw, 18, out, 4), HCA_ERR_CORRUPT);
    /* bad header passed to decode_frame_from */
    hdr.compression = 9;
    CHECK_EQ(hca_decode_frame_from(&hdr, raw, 16, out, 4), HCA_ERR_UNSUPPORTED);
    CHECK_EQ(hca_decode_frame_from(NULL, raw, 16, out, 4), HCA_ERR_ARG);
}

static void test_raw_and_strided(void) {
    for (int i = 0; i < 8 * 4 * 2; i++) g_src[i] = (uint16_t)(i * 1031);
    size_t n = th_build_hca(g_src, 8, 4, 2, HCA_COMP_RAW, 0, NULL, g_file, sizeof g_file);
    hca_asset_t a;
    CHECK_EQ(hca_open(&a, g_file, n), HCA_OK);
    uint16_t out[11 * 4];
    memset(out, 0xEE, sizeof out);
    CHECK_EQ(hca_decode_frame(&a, 1, out, 11), HCA_OK);
    int ok = 1;
    for (int y = 0; y < 4; y++)
        for (int x = 0; x < 11; x++)
            if (out[y * 11 + x] != (x < 8 ? g_src[32 + y * 8 + x] : 0xEEEE)) ok = 0;
    CHECK(ok);
}

/* ---- blit clipping ---------------------------------------------------------------------- */

#define FBW 20
#define FBH 10
#define GW 5
#define GH 4

static void ref_blit(uint16_t *fb, const uint16_t *g, int x, int y, int cx0, int cy0, int cx1, int cy1) {
    for (int gy = 0; gy < GH; gy++)
        for (int gx = 0; gx < GW; gx++) {
            long long fx = (long long)x + gx, fy = (long long)y + gy;
            if (fx >= cx0 && fx < cx1 && fy >= cy0 && fy < cy1) fb[fy * FBW + fx] = g[gy * GW + gx];
        }
}

static void test_blit_clipping(void) {
    uint16_t glyph[GW * GH * 2];
    for (int i = 0; i < GW * GH; i++) glyph[i] = (uint16_t)(0x100 + i);       /* frame 0: unique */
    for (int i = 0; i < GW * GH; i++) glyph[GW * GH + i] = (uint16_t)(i < 12 ? 0x7777 : 0x100 + i);
    const int pos[][2] = {
        { 3, 3 }, { -2, 3 }, { 17, 3 }, { 3, -2 }, { 3, 8 },               /* inside, 4 edges */
        { -2, -2 }, { 17, -2 }, { -2, 8 }, { 17, 8 },                        /* 4 corners */
        { -5, 3 }, { 20, 3 }, { 3, -4 }, { 3, 10 }, { -4, -3 }, { 19, 9 },   /* outside / 1px */
        { 0, 0 }, { 15, 6 }, { INT_MIN, 0 }, { INT_MAX, 0 }, { 0, INT_MIN }, { 0, INT_MAX },
        { INT_MIN, INT_MIN }, { INT_MAX, INT_MAX },
    };
    for (int comp = 0; comp <= 1; comp++) {
        size_t n = th_build_hca(glyph, GW, GH, 2, comp, HCA_FLAG_GLYPH_ATLAS, NULL, g_file, sizeof g_file);
        hca_asset_t a;
        CHECK_EQ(hca_open(&a, g_file, n), HCA_OK);
        for (int frame = 0; frame < 2; frame++) {
            for (size_t p = 0; p < sizeof pos / sizeof pos[0]; p++) {
                uint16_t fb[FBW * FBH], ref[FBW * FBH];
                for (int i = 0; i < FBW * FBH; i++) fb[i] = ref[i] = 0xCCCC;
                CHECK_EQ(hca_blit_frame(&a, (uint16_t)frame, fb, FBW, FBH, pos[p][0], pos[p][1]), HCA_OK);
                ref_blit(ref, glyph + frame * GW * GH, pos[p][0], pos[p][1], 0, 0, FBW, FBH);
                int same = memcmp(fb, ref, sizeof fb) == 0;
                if (!same) fprintf(stderr, "  blit comp=%d frame=%d at (%d,%d)\n", comp, frame, pos[p][0], pos[p][1]);
                CHECK(same);
                /* clip to an inner rectangle too */
                for (int i = 0; i < FBW * FBH; i++) fb[i] = ref[i] = 0xCCCC;
                CHECK_EQ(hca__blit_clip(&a, (uint16_t)frame, fb, FBW, pos[p][0], pos[p][1], 4, 2, 7, 9), HCA_OK);
                ref_blit(ref, glyph + frame * GW * GH, pos[p][0], pos[p][1], 4, 2, 7, 9);
                CHECK(memcmp(fb, ref, sizeof fb) == 0);
            }
        }
    }
}

static void test_fill16(void) {
    uint16_t buf[64];
    for (size_t off = 0; off < 3; off++) {
        for (size_t n = 0; n <= 40; n++) {
            for (int i = 0; i < 64; i++) buf[i] = 0xDDDD;
            hca__fill16(buf + 1 + off, 0x1234, n);
            int ok = buf[off] == 0xDDDD;
            for (size_t i = 0; i < n; i++) if (buf[1 + off + i] != 0x1234) ok = 0;
            for (size_t i = 1 + off + n; i < 64; i++) if (buf[i] != 0xDDDD) ok = 0;
            CHECK(ok);
        }
    }
}

int main(void) {
    RUN(test_header_ok);
    RUN(test_header_truncated);
    RUN(test_header_bad);
    RUN(test_rle_roundtrip);
    RUN(test_encoder_format);
    RUN(test_max_runs);
    RUN(test_corrupt_streams);
    RUN(test_raw_and_strided);
    RUN(test_blit_clipping);
    RUN(test_fill16);
    return TH_DONE("test_hca");
}
