/* reader_store.h — Reader mode storage (PROTOCOL §5c): texts with their word index, reader fonts,
 * reading progress.
 *
 * Layout (under STORAGE_ROOT):
 *   /texts/<id>.txt          the UTF-8 text as uploaded (<= READER_TEXT_MAX_BYTES)
 *   /texts/<id>.idx          word index, built in the same streaming pass as the upload (below)
 *   /fonts/<id>.json         reader font document (validated with core rsvp_font_parse + atlas checks)
 *   /reader-progress.json    {"version":1,"progress":{"<text id>":<word>,...}} most recent first,
 *                            at most READER_PROGRESS_MAX entries (oldest dropped)
 *
 * .idx format (little-endian):
 *   0   4  magic "RSX1"
 *   4   4  version (1)
 *   8   4  word count N
 *   12  4  text bytes
 *   16  4  paragraphs (words with RSVP_F_PARA)
 *   20  4  sentences
 *   24  8  sum of rsvp_word_factor_x10() (whole-text duration via rsvp_total_ms)
 *   32  32 SHA-256 of the text
 *   64  64 title (first line, rsvp_title(), NUL-padded)
 *   128 4*N word entries: bits 0..28 byte offset of the word, bits 29..31 its RSVP_F_* flags
 * A word's bytes are re-read with rsvp_word_at() from its offset. All functions are thread-safe.
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"
#include "storage.h"
#include "rsvp.h"

#ifdef __cplusplus
extern "C" {
#endif

#define READER_TEXT_MAX_BYTES (1024u * 1024u)
#define READER_MAX_TEXTS      64
#define READER_MAX_FONTS      32
#define READER_FONT_MAX_BYTES RSVP_FONT_JSON_MAX
#define READER_PROGRESS_MAX   64
#define READER_IDX_HEADER     128u
#define READER_IDX_OFF_MASK   0x1FFFFFFFu
#define READER_IDX_FLAG_SHIFT 29

typedef struct {
    char id[STORAGE_ID_MAX + 1];
    uint32_t bytes, words, paragraphs, sentences;
    uint64_t factor_x10;
    uint8_t sha256[32];
    char title[RSVP_TITLE_MAX];
} reader_text_info_t;

/* Create the directories, drop interrupted uploads. Call after storage_init(). */
esp_err_t reader_store_init(void);

/* ---- texts ------------------------------------------------------------------------------------ */

void reader_text_path(const char *id, char *buf, size_t len);
void reader_idx_path(const char *id, char *buf, size_t len);

/* Header of a stored text (false if missing or its index is inconsistent). */
bool reader_text_info(const char *id, reader_text_info_t *out);
bool reader_text_exists(const char *id);

/* Call cb for every stored text (directory order); stops when cb returns false. Returns the count. */
typedef bool (*reader_text_cb_t)(const reader_text_info_t *info, void *ctx);
size_t reader_text_foreach(reader_text_cb_t cb, void *ctx);

/* Streaming upload: begin (id, size <= READER_TEXT_MAX_BYTES, free space, text count), feed chunks
 * (written to a temp file, hashed and tokenised on the fly, word index written alongside), finish
 * (SHA-256 must match; the text must be valid UTF-8 without NUL bytes and contain at least one word,
 * else STORAGE_ERR_MALFORMED; files renamed into place). */
typedef struct reader_writer reader_writer_t;
storage_status_t reader_text_write_begin(const char *id, size_t total, reader_writer_t **out);
storage_status_t reader_text_write(reader_writer_t *w, const void *data, size_t len);
storage_status_t reader_text_write_finish(reader_writer_t *w, const uint8_t expected_sha[32], reader_text_info_t *out);
void reader_text_write_abort(reader_writer_t *w);

storage_status_t reader_text_delete(const char *id);   /* also forgets its progress */

/* ---- fonts ------------------------------------------------------------------------------------ */

/* Validate a font document: ESP_ERR_INVALID_ARG = malformed (rsvp_font_parse failed, or an atlas does
 * not match the document's cell size / glyph count), ESP_ERR_NOT_FOUND = an atlas is not an uploaded
 * glyph atlas. `msg` receives a reason. */
esp_err_t reader_font_validate(const char *json, size_t len, char *msg, size_t msg_len);
esp_err_t reader_font_store(const char *id, const char *json, size_t len);   /* ESP_ERR_NO_MEM: too many fonts */
bool reader_font_exists(const char *id);
/* malloc'd, NUL-terminated (caller frees) */
esp_err_t reader_font_read(const char *id, char **json, size_t *len);
storage_status_t reader_font_delete(const char *id);
typedef bool (*reader_font_cb_t)(const char *id, void *ctx);
size_t reader_font_foreach(reader_font_cb_t cb, void *ctx);

/* ---- progress --------------------------------------------------------------------------------- */

/* Word to resume `id` at (0 if unknown). */
uint32_t reader_progress_get(const char *id);
/* Remember `word` for `id` (moves it to the front; persisted immediately). */
esp_err_t reader_progress_set(const char *id, uint32_t word);
void reader_progress_remove(const char *id);

/* ---- erase ------------------------------------------------------------------------------------ */

/* POST /erase: remove every file of the text and font directories (texts with their indexes, font documents,
 * leftovers of interrupted writes) and all reading progress. *texts / *fonts = the texts (indexes) and font
 * documents removed. `tick` (may be NULL) runs after every file (see storage_asset_erase_all). ESP_FAIL when a file
 * could not be removed (what was removed stays removed; a repeated call removes the rest). */
esp_err_t reader_erase_all(size_t *texts, size_t *fonts, void (*tick)(void));

#ifdef __cplusplus
}
#endif
