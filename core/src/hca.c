/* hca.c — .hca parsing, RLE16 decoding/encoding (docs/PROTOCOL.md §2).
 *
 * Buffers of type uint16_t hold RGB565 pixels in *file byte order* (big-endian bytes in memory),
 * so decoding is a plain byte copy and the panel can DMA the framebuffer as-is. Pixel values are
 * never interpreted here except to compare them for equality (encoder) or replicate them (fills).
 *
 * Robustness: every read from the input is bounds-checked against the supplied length before it
 * happens; every write is checked against the frame geometry. Sizes are computed in 64-bit so
 * 65535 x 65535 geometry cannot overflow a 32-bit size_t on the ESP32.
 */
#include "hca.h"
#include "hca_internal.h"
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
typedef uint32_t __attribute__((__may_alias__)) hca_u32_alias;
#define HCA_LIKELY(x) __builtin_expect(!!(x), 1)
#define HCA_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
typedef uint32_t hca_u32_alias;
#define HCA_LIKELY(x) (x)
#define HCA_UNLIKELY(x) (x)
#endif

#define RLE_MAX_RUN 32768u

static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | ((unsigned)p[1] << 8)); }
static inline uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

const char *hca_status_str(hca_status_t s) {
    switch (s) {
    case HCA_OK: return "ok";
    case HCA_ERR_TRUNCATED: return "truncated";
    case HCA_ERR_BAD_MAGIC: return "bad magic";
    case HCA_ERR_UNSUPPORTED: return "unsupported";
    case HCA_ERR_BAD_FRAME: return "bad frame";
    case HCA_ERR_CORRUPT: return "corrupt";
    case HCA_ERR_ARG: return "bad argument";
    }
    return "unknown";
}

/* ------------------------------------------------------------------------------------------ */
/* Header / frame table                                                                       */

static hca_status_t check_geometry(const hca_header_t *h) {
    if (h->pixel_format != HCA_PIXFMT_RGB565BE) return HCA_ERR_UNSUPPORTED;
    if (h->compression != HCA_COMP_RAW && h->compression != HCA_COMP_RLE16) return HCA_ERR_UNSUPPORTED;
    if (h->width == 0 || h->height == 0) return HCA_ERR_UNSUPPORTED;
    return HCA_OK;
}

/* Plausible compressed length bounds for one frame of n_px pixels. */
static void frame_len_bounds(const hca_header_t *h, uint64_t *lo, uint64_t *hi) {
    uint64_t npx = (uint64_t)h->width * h->height;
    if (h->compression == HCA_COMP_RAW) {
        *lo = *hi = npx * 2u;
    } else {
        uint64_t runs = (npx + RLE_MAX_RUN - 1u) / RLE_MAX_RUN;
        *lo = runs * 4u;              /* all repeat runs of maximum length */
        *hi = npx * 4u;               /* every pixel its own run: never produced by a sane encoder */
    }
}

hca_status_t hca_open(hca_asset_t *a, const uint8_t *data, size_t size) {
    if (!a || !data) return HCA_ERR_ARG;
    memset(a, 0, sizeof *a);
    if (size < HCA_HEADER_SIZE) return HCA_ERR_TRUNCATED;
    if (memcmp(data, HCA_MAGIC, 4) != 0) return HCA_ERR_BAD_MAGIC;

    hca_header_t h;
    h.width = rd16(data + 4);
    h.height = rd16(data + 6);
    h.frame_count = rd16(data + 8);
    h.pixel_format = data[10];
    h.compression = data[11];
    h.loop_count = rd16(data + 12);
    h.flags = rd16(data + 14);
    h.frame_table_off = rd32(data + 16);
    h.data_size = rd32(data + 20);

    hca_status_t st = check_geometry(&h);
    if (st != HCA_OK) return st;
    if (h.frame_table_off != HCA_HEADER_SIZE) return HCA_ERR_UNSUPPORTED;
    if (h.frame_count == 0) return HCA_ERR_BAD_FRAME;

    size_t table_end = hca_table_bytes(h.frame_count);
    if (h.data_size < table_end) return HCA_ERR_BAD_FRAME;
    if (size < table_end) return HCA_ERR_TRUNCATED;

    uint64_t lo, hi;
    frame_len_bounds(&h, &lo, &hi);
    for (uint16_t i = 0; i < h.frame_count; i++) {
        const uint8_t *e = data + HCA_HEADER_SIZE + (size_t)i * HCA_FRAME_ENTRY_SIZE;
        uint32_t off = rd32(e), len = rd32(e + 4);
        if (off < table_end) return HCA_ERR_BAD_FRAME;
        if ((uint64_t)off + len > h.data_size) return HCA_ERR_BAD_FRAME;
        if (len < lo || len > hi || (len & 1u)) return HCA_ERR_BAD_FRAME;
    }
    a->data = data;
    a->size = size;
    a->hdr = h;
    return HCA_OK;
}

hca_status_t hca_frame_info(const hca_asset_t *a, uint16_t index, hca_frame_info_t *out) {
    if (!a || !a->data || !out) return HCA_ERR_ARG;
    if (index >= a->hdr.frame_count) return HCA_ERR_BAD_FRAME;
    const uint8_t *e = a->data + HCA_HEADER_SIZE + (size_t)index * HCA_FRAME_ENTRY_SIZE;
    out->offset = rd32(e);
    out->length = rd32(e + 4);
    out->duration_ms = rd16(e + 8);
    out->flags = rd16(e + 10);
    return HCA_OK;
}

uint16_t hca_frame_duration(const hca_asset_t *a, uint16_t index, uint16_t default_ms) {
    hca_frame_info_t fi;
    if (hca_frame_info(a, index, &fi) != HCA_OK || fi.duration_ms == 0) return default_ms;
    return fi.duration_ms;
}

/* Resolve the in-memory byte range of a frame. */
static hca_status_t frame_bytes(const hca_asset_t *a, uint16_t index, const uint8_t **src, size_t *len) {
    hca_frame_info_t fi;
    hca_status_t st = hca_frame_info(a, index, &fi);
    if (st != HCA_OK) return st;
    if ((uint64_t)fi.offset + fi.length > a->size) return HCA_ERR_TRUNCATED; /* partial view */
    *src = a->data + fi.offset;
    *len = fi.length;
    return HCA_OK;
}

/* ------------------------------------------------------------------------------------------ */
/* Pixel primitives                                                                           */

void hca__fill16(uint16_t *d, uint16_t px, size_t n) {
    if (n < 4) {
        while (n--) *d++ = px;
        return;
    }
    if ((uintptr_t)d & 2u) { *d++ = px; n--; }
    /* d is now 4-byte aligned: store two pixels per 32-bit word. Both halves are the same value,
     * so the pattern is independent of CPU endianness. */
    const uint32_t pat = (uint32_t)px * 0x00010001u;
    hca_u32_alias *w = (hca_u32_alias *)(void *)d;
    size_t words = n >> 1;
    while (words >= 8) {
        w[0] = pat; w[1] = pat; w[2] = pat; w[3] = pat;
        w[4] = pat; w[5] = pat; w[6] = pat; w[7] = pat;
        w += 8; words -= 8;
    }
    while (words--) *w++ = pat;
    if (n & 1u) *(uint16_t *)(void *)w = px;
}

static inline uint16_t load_px(const uint8_t *s) {
    uint16_t v;
    memcpy(&v, s, 2);
    return v;
}

/* ------------------------------------------------------------------------------------------ */
/* Full-frame decode                                                                          */

/* Contiguous destination (stride == width): the whole frame is one linear run of pixels. */
static hca_status_t rle_decode_linear(const uint8_t *s, size_t len, uint16_t *d, size_t npx) {
    const uint8_t *const end = s + len;
    size_t left = npx;
    while (left) {
        if (HCA_UNLIKELY((size_t)(end - s) < 2)) return HCA_ERR_CORRUPT;   /* underrun */
        unsigned c = rd16(s);
        size_t n = (size_t)(c & 0x7FFFu) + 1u;
        s += 2;
        if (HCA_UNLIKELY(n > left)) return HCA_ERR_CORRUPT;                /* overrun */
        if (c & 0x8000u) {
            if (HCA_UNLIKELY((size_t)(end - s) < 2)) return HCA_ERR_CORRUPT;
            hca__fill16(d, load_px(s), n);
            s += 2;
        } else {
            size_t nb = n * 2u;
            if (HCA_UNLIKELY((size_t)(end - s) < nb)) return HCA_ERR_CORRUPT;
            memcpy(d, s, nb);
            s += nb;
        }
        d += n;
        left -= n;
    }
    return s == end ? HCA_OK : HCA_ERR_CORRUPT;                            /* trailing bytes */
}

/* Strided destination: runs are split at row ends. Offsets are tracked as indices so no pointer
 * is ever formed beyond the caller's buffer. */
static hca_status_t rle_decode_strided(const uint8_t *s, size_t len, uint16_t *dst, size_t stride,
                                       size_t w, size_t npx) {
    const uint8_t *const end = s + len;
    size_t left = npx, row = 0, x = 0;
    while (left) {
        if ((size_t)(end - s) < 2) return HCA_ERR_CORRUPT;
        unsigned c = rd16(s);
        size_t n = (size_t)(c & 0x7FFFu) + 1u;
        s += 2;
        if (n > left) return HCA_ERR_CORRUPT;
        left -= n;
        if (c & 0x8000u) {
            if ((size_t)(end - s) < 2) return HCA_ERR_CORRUPT;
            uint16_t px = load_px(s);
            s += 2;
            while (n) {
                size_t k = w - x < n ? w - x : n;
                hca__fill16(dst + row + x, px, k);
                n -= k; x += k;
                if (x == w) { x = 0; row += stride; }
            }
        } else {
            if ((size_t)(end - s) < n * 2u) return HCA_ERR_CORRUPT;
            while (n) {
                size_t k = w - x < n ? w - x : n;
                memcpy(dst + row + x, s, k * 2u);
                s += k * 2u; n -= k; x += k;
                if (x == w) { x = 0; row += stride; }
            }
        }
    }
    return s == end ? HCA_OK : HCA_ERR_CORRUPT;
}

hca_status_t hca_decode_frame_from(const hca_header_t *hdr, const uint8_t *src, size_t src_len,
                                   uint16_t *dst, uint16_t dst_stride_px) {
    if (!hdr || !src || !dst) return HCA_ERR_ARG;
    hca_status_t st = check_geometry(hdr);
    if (st != HCA_OK) return st;
    if (dst_stride_px < hdr->width) return HCA_ERR_ARG;

    const size_t w = hdr->width, h = hdr->height, stride = dst_stride_px;
    const uint64_t npx64 = (uint64_t)w * h;
    if (npx64 * 2u > (uint64_t)SIZE_MAX) return HCA_ERR_UNSUPPORTED;
    const size_t npx = (size_t)npx64;

    if (hdr->compression == HCA_COMP_RAW) {
        if (src_len < npx * 2u) return HCA_ERR_TRUNCATED;
        if (src_len > npx * 2u) return HCA_ERR_CORRUPT;
        if (stride == w) {
            memcpy(dst, src, npx * 2u);
        } else {
            for (size_t y = 0; y < h; y++) memcpy(dst + y * stride, src + y * w * 2u, w * 2u);
        }
        return HCA_OK;
    }
    if (stride == w) return rle_decode_linear(src, src_len, dst, npx);
    return rle_decode_strided(src, src_len, dst, stride, w, npx);
}

hca_status_t hca_decode_frame(const hca_asset_t *a, uint16_t index, uint16_t *dst, uint16_t dst_stride_px) {
    const uint8_t *src;
    size_t len;
    if (!a || !a->data || !dst) return HCA_ERR_ARG;
    hca_status_t st = frame_bytes(a, index, &src, &len);
    if (st != HCA_OK) return st;
    return hca_decode_frame_from(&a->hdr, src, len, dst, dst_stride_px);
}

/* ------------------------------------------------------------------------------------------ */
/* Clipped blit                                                                               */

hca_status_t hca__blit_clip(const hca_asset_t *a, uint16_t index, uint16_t *fb, uint16_t fb_stride,
                            int x, int y, int cx0, int cy0, int cx1, int cy1) {
    const uint8_t *s;
    size_t len;
    if (!a || !a->data || !fb) return HCA_ERR_ARG;
    hca_status_t st = frame_bytes(a, index, &s, &len);
    if (st != HCA_OK) return st;
    const hca_header_t *hdr = &a->hdr;
    st = check_geometry(hdr);
    if (st != HCA_OK) return st;

    const int64_t w = hdr->width, h = hdr->height;
    if ((uint64_t)(w * h) * 2u > (uint64_t)SIZE_MAX) return HCA_ERR_UNSUPPORTED;   /* 32-bit size_t */
    /* Visible window in frame coordinates. 64-bit so extreme x/y cannot overflow. */
    int64_t vx0 = (int64_t)cx0 - x, vx1 = (int64_t)cx1 - x;
    int64_t vy0 = (int64_t)cy0 - y, vy1 = (int64_t)cy1 - y;
    if (vx0 < 0) vx0 = 0;
    if (vy0 < 0) vy0 = 0;
    if (vx1 > w) vx1 = w;
    if (vy1 > h) vy1 = h;
    if (vx0 >= vx1 || vy0 >= vy1) return HCA_OK;   /* fully clipped */

    /* From here every destination index (y+fy)*stride + (x+fx) with fx in [vx0,vx1), fy in
     * [vy0,vy1) lies inside the clip rectangle, which the caller guarantees is inside fb. */
    const size_t stride = fb_stride;
    const size_t ox = (size_t)((int64_t)x + vx0);     /* fb column of frame column vx0 */
    const size_t vw = (size_t)(vx1 - vx0);
    const size_t npx = (size_t)(w * h);

    if (hdr->compression == HCA_COMP_RAW) {
        if (len != npx * 2u) return len < npx * 2u ? HCA_ERR_TRUNCATED : HCA_ERR_CORRUPT;
        for (int64_t fy = vy0; fy < vy1; fy++) {
            uint16_t *d = fb + (size_t)(y + fy) * stride + ox;
            memcpy(d, s + ((size_t)fy * (size_t)w + (size_t)vx0) * 2u, vw * 2u);
        }
        return HCA_OK;
    }

    const uint8_t *const end = s + len;
    size_t left = npx;
    size_t fx = 0, fy = 0;
    const size_t uw = (size_t)w, uvx0 = (size_t)vx0, uvx1 = (size_t)vx1;
    const size_t uvy0 = (size_t)vy0, uvy1 = (size_t)vy1;
    while (left) {
        if (fy >= uvy1) return HCA_OK;              /* past the clip: rest is invisible */
        if ((size_t)(end - s) < 2) return HCA_ERR_CORRUPT;
        unsigned c = rd16(s);
        size_t n = (size_t)(c & 0x7FFFu) + 1u;
        s += 2;
        if (n > left) return HCA_ERR_CORRUPT;
        left -= n;
        const int rep = (c & 0x8000u) != 0;
        const uint8_t *lit = s;
        uint16_t px = 0;
        if (rep) {
            if ((size_t)(end - s) < 2) return HCA_ERR_CORRUPT;
            px = load_px(s);
            s += 2;
        } else {
            if ((size_t)(end - s) < n * 2u) return HCA_ERR_CORRUPT;
            s += n * 2u;
        }
        while (n) {
            size_t k = uw - fx < n ? uw - fx : n;
            if (fy >= uvy0 && fy < uvy1) {
                size_t a0 = fx > uvx0 ? fx : uvx0;
                size_t a1 = fx + k < uvx1 ? fx + k : uvx1;
                if (a0 < a1) {
                    uint16_t *d = fb + (size_t)((int64_t)y + (int64_t)fy) * stride + ox + (a0 - uvx0);
                    if (rep) hca__fill16(d, px, a1 - a0);
                    else memcpy(d, lit + (a0 - fx) * 2u, (a1 - a0) * 2u);
                }
            }
            if (!rep) lit += k * 2u;
            n -= k; fx += k;
            if (fx == uw) { fx = 0; fy++; }
        }
    }
    return s == end ? HCA_OK : HCA_ERR_CORRUPT;
}

hca_status_t hca_blit_frame(const hca_asset_t *a, uint16_t index,
                            uint16_t *fb, uint16_t fb_w, uint16_t fb_h, int x, int y) {
    if (!a || !fb || fb_w == 0 || fb_h == 0) return HCA_ERR_ARG;
    return hca__blit_clip(a, index, fb, fb_w, x, y, 0, 0, fb_w, fb_h);
}

/* ------------------------------------------------------------------------------------------ */
/* Encoder                                                                                    */

static int emit_literal(const uint16_t *src, size_t start, size_t end, uint8_t **pp, uint8_t *dend) {
    while (start < end) {
        size_t n = end - start;
        if (n > RLE_MAX_RUN) n = RLE_MAX_RUN;
        if ((size_t)(dend - *pp) < 2u + n * 2u) return 0;
        unsigned c = (unsigned)(n - 1u);
        (*pp)[0] = (uint8_t)(c & 0xFFu);
        (*pp)[1] = (uint8_t)(c >> 8);
        memcpy(*pp + 2, src + start, n * 2u);
        *pp += 2u + n * 2u;
        start += n;
    }
    return 1;
}

size_t hca_rle16_encode(const uint16_t *src, size_t n_px, uint8_t *dst, size_t dst_cap) {
    if (!src || !dst || n_px == 0) return 0;
    uint8_t *p = dst, *const dend = dst + dst_cap;
    size_t i = 0, lit = 0;
    while (i < n_px) {
        const uint16_t v = src[i];
        size_t r = 1;
        while (i + r < n_px && r < RLE_MAX_RUN && src[i + r] == v) r++;
        if (r >= 3) {
            if (!emit_literal(src, lit, i, &p, dend)) return 0;
            if ((size_t)(dend - p) < 4) return 0;
            unsigned c = 0x8000u | (unsigned)(r - 1u);
            p[0] = (uint8_t)(c & 0xFFu);
            p[1] = (uint8_t)(c >> 8);
            memcpy(p + 2, &v, 2);
            p += 4;
            i += r;
            lit = i;
        } else {
            i += r;
        }
    }
    if (!emit_literal(src, lit, n_px, &p, dend)) return 0;
    return (size_t)(p - dst);
}
