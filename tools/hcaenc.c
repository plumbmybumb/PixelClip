/* hcaenc — convert PNG frame(s) into a .hca asset (docs/PROTOCOL.md §2).
 *
 *   hcaenc OUT.hca [options] IN.png [IN2.png ...]
 *
 *   --fps N             every frame lasts round(1000/N) ms
 *   --durations a,b,..  per-frame durations in ms (one value = all frames)
 *   --loop N            loop_count header field (default 0 = forever)
 *   --atlas             set the glyph-atlas flag; any frame size (all frames equal)
 *   --size WxH          required input size (default 536x240, or the first frame's size with --atlas)
 *   --crop X,Y          take the --size region at (X,Y) from larger inputs (e.g. a qlmanage render)
 *   --raw               store frames uncompressed (default RLE16)
 *   --no-dither         round to nearest RGB565 everywhere
 *   --dither-all        classic 4x4 ordered (Bayer) dithering on every pixel
 *   (default)           4x4 Bayer dithering except in flat areas: a pixel identical (RGB888) to its
 *                       4 neighbours is rounded. Dithering a flat colour that is not exactly
 *                       representable in RGB565 creates a fixed pattern that defeats RLE (5-20x
 *                       larger frames on UI art) without any visible benefit.
 *   -q                  quiet
 *
 * Inputs are not resized: a frame of the wrong size is an error. Alpha is composited over black.
 */
#include "hca.h"
#include "common/toolutil.h"
#include "third_party/stb_image.h"

static const uint8_t BAYER4[4][4] = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } };

/* Quantise an 8-bit channel to `maxv` (31 or 63) levels with ordered-dither threshold t in 0..15.
 * t = 7.5 (passed as 2t+1 = 16) is plain rounding. Black stays black, white stays white. */
static inline unsigned quant(unsigned v, unsigned maxv, unsigned t2p1) {
    return (v * maxv * 32u + t2p1 * 255u) / (255u * 32u);
}

static void usage(void) {
    fprintf(stderr,
            "usage: hcaenc OUT.hca [--fps N | --durations a,b,...] [--loop N] [--atlas] [--size WxH]\n"
            "              [--crop X,Y] [--raw] [--no-dither | --dither-all] [-q] IN.png [IN2.png ...]\n");
    exit(2);
}

int main(int argc, char **argv) {
    const char *out = NULL;
    const char **inputs = xmalloc(sizeof(char *) * (size_t)argc);
    int ninputs = 0, atlas = 0, raw = 0, dither = 1, quiet = 0, loop = 0, req_w = 0, req_h = 0;
    int crop = 0, crop_x = 0, crop_y = 0;
    double fps = 0;
    const char *durations = NULL;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--fps") && i + 1 < argc) fps = atof(argv[++i]);
        else if (!strcmp(a, "--durations") && i + 1 < argc) durations = argv[++i];
        else if (!strcmp(a, "--loop") && i + 1 < argc) loop = atoi(argv[++i]);
        else if (!strcmp(a, "--atlas")) atlas = 1;
        else if (!strcmp(a, "--raw")) raw = 1;
        else if (!strcmp(a, "--no-dither")) dither = 0;
        else if (!strcmp(a, "--dither-all")) dither = 2;
        else if (!strcmp(a, "-q")) quiet = 1;
        else if (!strcmp(a, "--size") && i + 1 < argc) {
            if (sscanf(argv[++i], "%dx%d", &req_w, &req_h) != 2 || req_w < 1 || req_h < 1) die("bad --size");
        } else if (!strcmp(a, "--crop") && i + 1 < argc) {
            if (sscanf(argv[++i], "%d,%d", &crop_x, &crop_y) != 2 || crop_x < 0 || crop_y < 0) die("bad --crop");
            crop = 1;
        } else if (a[0] == '-' && a[1]) usage();
        else if (!out) out = a;
        else inputs[ninputs++] = a;
    }
    if (!out || ninputs == 0) usage();
    size_t ol = strlen(out);
    if (ol >= 4 && !strcmp(out + ol - 4, ".png")) die("output %s looks like an input PNG; put OUT.hca first", out);
    if (ninputs > 65535) die("too many frames");
    if (fps < 0 || (fps > 0 && 1000.0 / fps > 65535)) die("bad --fps");
    if (loop < 0 || loop > 65535) die("bad --loop");
    if (!atlas && !req_w) { req_w = 536; req_h = 240; }
    if (crop && !req_w) die("--crop needs --size with --atlas");

    /* per-frame durations */
    uint16_t *dur = xmalloc(sizeof(uint16_t) * (size_t)ninputs);
    for (int i = 0; i < ninputs; i++) dur[i] = fps > 0 ? (uint16_t)(1000.0 / fps + 0.5) : 0;
    if (durations) {
        if (fps > 0) die("use either --fps or --durations");
        int n = 0;
        const char *p = durations;
        long *vals = xmalloc(sizeof(long) * 65536);
        while (*p && n < 65536) {
            char *end;
            long v = strtol(p, &end, 10);
            if (end == p || v < 0 || v > 65535) die("bad --durations near '%s'", p);
            vals[n++] = v;
            p = *end == ',' ? end + 1 : end;
            if (*end && *end != ',') die("bad --durations near '%s'", end);
        }
        if (n != 1 && n != ninputs) die("--durations has %d values for %d frames", n, ninputs);
        for (int i = 0; i < ninputs; i++) dur[i] = (uint16_t)vals[n == 1 ? 0 : i];
        free(vals);
    }

    int w = req_w, h = req_h;
    uint16_t *frames = NULL;
    size_t npx = 0;
    for (int f = 0; f < ninputs; f++) {
        int iw, ih, comp;
        /* the header first: a small PNG can claim a huge image (stb would allocate and inflate all of it) */
        if (!stbi_info(inputs[f], &iw, &ih, &comp)) die("%s: %s", inputs[f], stbi_failure_reason());
        check_pixels(inputs[f], (uint64_t)iw, (uint64_t)ih);
        uint8_t *img = stbi_load(inputs[f], &iw, &ih, &comp, 4);
        if (!img) die("%s: %s", inputs[f], stbi_failure_reason());
        if (crop) {
            if (crop_x + w > iw || crop_y + h > ih)
                die("%s is %dx%d, too small for a %dx%d crop at %d,%d", inputs[f], iw, ih, w, h, crop_x, crop_y);
            for (int y = 0; y < h; y++)   /* compact the region to the top-left (dest never passes unread source) */
                memmove(img + (size_t)y * w * 4, img + ((size_t)(y + crop_y) * iw + crop_x) * 4, (size_t)w * 4);
            iw = w;
            ih = h;
        }
        if (!w) { w = iw; h = ih; }
        if (iw != w || ih != h) die("%s is %dx%d, expected %dx%d (hcaenc does not resize)", inputs[f], iw, ih, w, h);
        if (w > 65535 || h > 65535) die("%s too large", inputs[f]);
        if (!frames) {
            npx = (size_t)w * h;
            frames = xmalloc(npx * 2 * (size_t)ninputs);
        }
        uint16_t *dst = frames + npx * (size_t)f;
        /* composite over black in place */
        for (size_t i = 0; i < npx; i++) {
            uint8_t *p = img + i * 4;
            unsigned a = p[3];
            p[0] = (uint8_t)(p[0] * a / 255u); p[1] = (uint8_t)(p[1] * a / 255u); p[2] = (uint8_t)(p[2] * a / 255u);
            p[3] = 255;
        }
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                const uint8_t *p = img + ((size_t)y * w + x) * 4;
                unsigned r = p[0], g = p[1], b = p[2];
                int dith = dither == 2;
                if (dither == 1) {
                    uint32_t c;
                    memcpy(&c, p, 4);
                    const int nx[4] = { x - 1, x + 1, x, x }, ny[4] = { y, y, y - 1, y + 1 };
                    for (int k = 0; k < 4 && !dith; k++) {
                        if (nx[k] < 0 || ny[k] < 0 || nx[k] >= w || ny[k] >= h) continue;
                        uint32_t o;
                        memcpy(&o, img + ((size_t)ny[k] * w + nx[k]) * 4, 4);
                        if (o != c) dith = 1;
                    }
                }
                unsigned t = dith ? 2u * BAYER4[y & 3][x & 3] + 1u : 16u;
                uint16_t v = (uint16_t)((quant(r, 31, t) << 11) | (quant(g, 63, t) << 5) | quant(b, 31, t));
                dst[(size_t)y * w + x] = be565_from_rgb565(v);
            }
        }
        stbi_image_free(img);
    }

    /* assemble */
    size_t table = hca_table_bytes((uint16_t)ninputs);
    size_t worst_frame = npx * 2 + 2 * ((npx + 32767) / 32768);
    size_t cap = table + worst_frame * (size_t)ninputs;
    if (cap > 0xFFFFFFFFu) die("output would exceed 4 GiB");
    uint8_t *file = xmalloc(cap);
    memset(file, 0, table);
    size_t off = table;
    for (int f = 0; f < ninputs; f++) {
        const uint16_t *src = frames + npx * (size_t)f;
        size_t len;
        if (raw) {
            memcpy(file + off, src, npx * 2);
            len = npx * 2;
        } else {
            len = hca_rle16_encode(src, npx, file + off, cap - off);
            if (!len) die("internal: RLE buffer too small");
        }
        uint8_t *e = file + HCA_HEADER_SIZE + (size_t)f * HCA_FRAME_ENTRY_SIZE;
        put32le(e, (uint32_t)off);
        put32le(e + 4, (uint32_t)len);
        put16le(e + 8, dur[f]);
        off += len;
    }
    memcpy(file, HCA_MAGIC, 4);
    put16le(file + 4, (uint32_t)w);
    put16le(file + 6, (uint32_t)h);
    put16le(file + 8, (uint32_t)ninputs);
    file[10] = HCA_PIXFMT_RGB565BE;
    file[11] = raw ? HCA_COMP_RAW : HCA_COMP_RLE16;
    put16le(file + 12, (uint32_t)loop);
    put16le(file + 14, atlas ? HCA_FLAG_GLYPH_ATLAS : 0);
    put32le(file + 16, HCA_HEADER_SIZE);
    put32le(file + 20, (uint32_t)off);

    /* self-check: the file must open and every frame decode back to the source pixels */
    hca_asset_t asset;
    hca_status_t st = hca_open(&asset, file, off);
    if (st != HCA_OK) die("internal: produced file fails hca_open: %s", hca_status_str(st));
    uint16_t *check = xmalloc(npx * 2);
    for (int f = 0; f < ninputs; f++) {
        st = hca_decode_frame(&asset, (uint16_t)f, check, (uint16_t)w);
        if (st != HCA_OK || memcmp(check, frames + npx * (size_t)f, npx * 2))
            die("internal: frame %d does not round-trip (%s)", f, hca_status_str(st));
    }
    write_file(out, file, off);
    if (!quiet) {
        double rawsz = (double)npx * 2 * ninputs;
        printf("%s: %dx%d, %d frame%s, %s%s, %zu bytes (%.2f%% of raw %.0f), %s\n", out, w, h, ninputs,
               ninputs == 1 ? "" : "s", raw ? "raw" : "RLE16", atlas ? ", glyph atlas" : "", off,
               100.0 * (double)off / rawsz, rawsz, dither == 2 ? "dithered (all)" : dither ? "dithered (flat-aware)" : "no dither");
    }
    free(check); free(file); free(frames); free(dur); free(inputs);
    return 0;
}
