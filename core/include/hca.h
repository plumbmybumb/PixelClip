/* hca.h — Hair Clip Animation (.hca) parsing and frame decoding.
 * Part of the protocol contract (docs/PROTOCOL.md §2, §6). C11, no allocation, no I/O.
 */
#ifndef HCA_H
#define HCA_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HCA_MAGIC "HCA1"
#define HCA_HEADER_SIZE 32u
#define HCA_FRAME_ENTRY_SIZE 12u

enum { HCA_PIXFMT_RGB565BE = 0 };
enum { HCA_COMP_RAW = 0, HCA_COMP_RLE16 = 1 };
enum { HCA_FLAG_GLYPH_ATLAS = 1u << 0 };

typedef enum {
    HCA_OK = 0,
    HCA_ERR_TRUNCATED,      /* buffer shorter than the structures claim */
    HCA_ERR_BAD_MAGIC,
    HCA_ERR_UNSUPPORTED,    /* unknown pixel format / compression / version */
    HCA_ERR_BAD_FRAME,      /* frame index out of range or frame table inconsistent */
    HCA_ERR_CORRUPT,        /* RLE stream overruns or underruns the frame */
    HCA_ERR_ARG,
} hca_status_t;

typedef struct {
    uint16_t width, height, frame_count;
    uint8_t  pixel_format, compression;
    uint16_t loop_count, flags;
    uint32_t frame_table_off, data_size;
} hca_header_t;

typedef struct {
    uint32_t offset, length;
    uint16_t duration_ms, flags;
} hca_frame_info_t;

/* A parsed asset. `data` must stay valid while the asset is used. Header + frame table only need
 * the first HCA_HEADER_SIZE + frame_count*12 bytes; frame decoding reads the frame's own byte range,
 * so callers streaming from flash can supply each frame through hca_decode_frame_from(). */
typedef struct {
    const uint8_t *data;
    size_t size;
    hca_header_t hdr;
} hca_asset_t;

/* Parse header and validate the frame table against the header's data_size (every frame range must
 * lie after the table and inside data_size, with a plausible length). `size` must cover at least the
 * header + frame table. If size < data_size the asset is a partial view (e.g. only the table was read
 * from flash): frames not fully inside [0,size) return HCA_ERR_TRUNCATED from hca_decode_frame /
 * hca_blit_frame and must be decoded with hca_decode_frame_from(). Upload validation should also
 * require size == data_size. */
hca_status_t hca_open(hca_asset_t *a, const uint8_t *data, size_t size);

/* Frame metadata. */
hca_status_t hca_frame_info(const hca_asset_t *a, uint16_t index, hca_frame_info_t *out);

/* Effective duration: entry's duration_ms, or `default_ms` when it is 0. */
uint16_t hca_frame_duration(const hca_asset_t *a, uint16_t index, uint16_t default_ms);

/* Decode frame `index` into `dst`, a width*height RGB565BE buffer (dst_stride_px pixels per row,
 * >= width). Constant memory. */
hca_status_t hca_decode_frame(const hca_asset_t *a, uint16_t index,
                              uint16_t *dst, uint16_t dst_stride_px);

/* Decode a frame whose compressed bytes are already in memory (`src`,`src_len`), using header
 * geometry from `hdr`. Lets the firmware read one frame from flash into a scratch buffer. */
hca_status_t hca_decode_frame_from(const hca_header_t *hdr, const uint8_t *src, size_t src_len,
                                   uint16_t *dst, uint16_t dst_stride_px);

/* Decode a frame and blit it at (x,y) into a larger RGB565BE framebuffer of fb_w × fb_h pixels,
 * clipping at the edges. Used for glyphs. */
hca_status_t hca_blit_frame(const hca_asset_t *a, uint16_t index,
                            uint16_t *fb, uint16_t fb_w, uint16_t fb_h, int x, int y);

/* Byte-size needed for the header + frame table of an asset with `frame_count` frames. */
static inline size_t hca_table_bytes(uint16_t frame_count) {
    return HCA_HEADER_SIZE + (size_t)frame_count * HCA_FRAME_ENTRY_SIZE;
}

/* ---- Encoder (used by tools/tests and available to firmware if ever needed) ---- */

/* RLE16-encode one frame of `n_px` RGB565BE pixels into `dst` (capacity dst_cap bytes).
 * Returns bytes written, or 0 if dst_cap is too small. Worst case is n_px*2 + 2*ceil(n_px/32768). */
size_t hca_rle16_encode(const uint16_t *src, size_t n_px, uint8_t *dst, size_t dst_cap);

const char *hca_status_str(hca_status_t s);

#ifdef __cplusplus
}
#endif
#endif /* HCA_H */
