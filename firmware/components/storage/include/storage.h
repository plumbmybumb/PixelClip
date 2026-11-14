/* storage.h — LittleFS on the `assets` partition, mounted at STORAGE_ROOT.
 *
 * Layout:  /assets/<id>.hca   asset files (PROTOCOL §2)
 *          /assets/<id>.sha   64-char hex SHA-256 sidecar (so boot need not re-hash every asset)
 *          /playlist.json /config.json /batlog*.csv
 *
 * An in-RAM index (id, size, sha256, geometry) is built at mount and updated on every write and
 * delete. All functions are thread-safe.
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define STORAGE_ROOT       "/lfs"
#define STORAGE_ID_MAX     32
#define STORAGE_MAX_ASSETS 256
#define STORAGE_MAX_FRAMES 8192

/* Scrolling strips (PROTOCOL §2 flags bit1 `is_strip`, §4 "Scrolling strips"): exactly one frame,
 * height 240, width STORAGE_STRIP_MIN_W..STORAGE_STRIP_MAX_W, raw or RLE16, never also an atlas. */
#define STORAGE_HCA_FLAG_STRIP (1u << 1)
#define STORAGE_STRIP_MIN_W    537
#define STORAGE_STRIP_MAX_W    8192
#define STORAGE_STRIP_H        240

typedef struct {
    char     id[STORAGE_ID_MAX + 1];
    uint32_t size;
    uint8_t  sha256[32];
    uint16_t width, height, frames;
    bool     atlas;
    bool     strip;      /* is_strip: one wide frame the player scrolls */
} asset_info_t;

typedef enum {
    STORAGE_OK = 0,
    STORAGE_ERR_ARG,        /* bad id / arguments */
    STORAGE_ERR_NOT_FOUND,
    STORAGE_ERR_NO_SPACE,   /* -> HTTP 413 */
    STORAGE_ERR_HASH,       /* SHA-256 mismatch */
    STORAGE_ERR_MALFORMED,  /* not a valid .hca (or wrong geometry) -> HTTP 422 */
    STORAGE_ERR_TOO_MANY,   /* asset index full */
    STORAGE_ERR_IO,
} storage_status_t;

esp_err_t storage_init(void);

/* `[a-z0-9][a-z0-9-]{0,31}` */
bool storage_id_valid(const char *id);

size_t storage_asset_count(void);
bool storage_asset_at(size_t idx, asset_info_t *out);
bool storage_asset_find(const char *id, asset_info_t *out);
/* Absolute VFS path of an asset file. */
void storage_asset_path(const char *id, char *buf, size_t len);

/* Streaming upload: begin (checks id + free space for `total` bytes), feed chunks, then finish
 * (verifies SHA-256 and the .hca header, renames the temp file into place, updates the index). */
typedef struct storage_writer storage_writer_t;
storage_status_t storage_asset_write_begin(const char *id, size_t total, storage_writer_t **out);
storage_status_t storage_asset_write(storage_writer_t *w, const void *data, size_t len);
storage_status_t storage_asset_write_finish(storage_writer_t *w, const uint8_t expected_sha[32],
                                            asset_info_t *out);
void storage_asset_write_abort(storage_writer_t *w);

storage_status_t storage_asset_delete(const char *id);

/* Decode one frame (compression 0 = raw, 1 = RLE16, PROTOCOL §2 exactness rules) straight from an
 * open asset file, without holding the compressed bytes in RAM (4 KB read buffer). The frame is
 * `len` bytes at file offset `off`, w×h pixels. Of every row only columns [x0, x0+cw) are written,
 * to dst + row*dst_stride + (col - x0); dst == NULL only validates. Used for strips (up to
 * 8192×240, too big to read whole next to their decoded copy). STORAGE_ERR_MALFORMED if the stream
 * under/overruns or leaves trailing bytes, STORAGE_ERR_IO on read errors. */
storage_status_t storage_frame_stream(int fd, uint32_t off, uint32_t len, uint16_t w, uint16_t h, uint8_t compression,
                                      uint16_t *dst, size_t dst_stride, uint16_t x0, uint16_t cw);

void storage_usage(size_t *total, size_t *used);

/* Small whole-file helpers; `name` is relative to STORAGE_ROOT (e.g. "playlist.json").
 * storage_read_file allocates (*out, NUL-terminated) and fails if the file exceeds max_len. */
esp_err_t storage_read_file(const char *name, char **out, size_t *len, size_t max_len);
esp_err_t storage_write_file(const char *name, const void *data, size_t len); /* atomic (tmp+rename) */
esp_err_t storage_append_file(const char *name, const void *data, size_t len);
long storage_file_size(const char *name); /* -1 if missing */
esp_err_t storage_remove_file(const char *name);
esp_err_t storage_rename_file(const char *from, const char *to);

/* Hex helpers. */
void storage_sha_to_hex(const uint8_t sha[32], char hex[65]);
bool storage_hex_to_sha(const char *hex, uint8_t sha[32]);

const char *storage_status_str(storage_status_t s);

#ifdef __cplusplus
}
#endif
