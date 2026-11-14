/* reader_store.c — texts + streaming word index, reader fonts, reading progress (PROTOCOL §5c). */
#include "reader_store.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_check.h"
#include "mbedtls/sha256.h"
#include "cJSON.h"

static const char *TAG = "reader";

#define TEXT_DIR       STORAGE_ROOT "/texts"
#define FONT_DIR       STORAGE_ROOT "/fonts"
#define PROGRESS_FILE  "reader-progress.json"
#define TMP_PREFIX     ".tmp-"
#define SPACE_MARGIN   (16 * 1024)
#define IDX_BUF        256           /* word entries buffered before a write (1 KB) */
#define HEAD_BYTES     256           /* start of the text kept for the title */

static SemaphoreHandle_t s_mutex;    /* progress cache + font/text directory changes */

static void lock(void)   { if (s_mutex) xSemaphoreTake(s_mutex, portMAX_DELAY); }
static void unlock(void) { if (s_mutex) xSemaphoreGive(s_mutex); }

static void wr32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

void reader_text_path(const char *id, char *buf, size_t len) { snprintf(buf, len, TEXT_DIR "/%s.txt", id); }
void reader_idx_path(const char *id, char *buf, size_t len) { snprintf(buf, len, TEXT_DIR "/%s.idx", id); }
static void font_path(const char *id, char *buf, size_t len) { snprintf(buf, len, FONT_DIR "/%s.json", id); }

static size_t free_bytes(void)
{
    size_t t = 0, u = 0;
    storage_usage(&t, &u);
    return t > u ? t - u : 0;
}

static void drop_tmp_files(const char *dir)
{
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    char path[64 + sizeof e->d_name];
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, TMP_PREFIX, strlen(TMP_PREFIX)) == 0) {
            snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
            unlink(path);
        }
    }
    closedir(d);
}

esp_err_t reader_store_init(void)
{
    if (!s_mutex) s_mutex = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_mutex, ESP_ERR_NO_MEM, TAG, "no mem");
    struct stat st;
    if (stat(TEXT_DIR, &st) != 0 && mkdir(TEXT_DIR, 0775) != 0) return ESP_FAIL;
    if (stat(FONT_DIR, &st) != 0 && mkdir(FONT_DIR, 0775) != 0) return ESP_FAIL;
    drop_tmp_files(TEXT_DIR);
    drop_tmp_files(FONT_DIR);
    ESP_LOGI(TAG, "%u text(s), %u font(s)", (unsigned)reader_text_foreach(NULL, NULL), (unsigned)reader_font_foreach(NULL, NULL));
    return ESP_OK;
}

/* ------------------------------------------------------------------ texts */

static bool parse_header(const uint8_t *h, const char *id, long idx_size, long txt_size, reader_text_info_t *out)
{
    if (memcmp(h, "RSX1", 4) != 0 || rd32(h + 4) != 1) return false;
    reader_text_info_t i = { 0 };
    strlcpy(i.id, id, sizeof i.id);
    i.words = rd32(h + 8);
    i.bytes = rd32(h + 12);
    i.paragraphs = rd32(h + 16);
    i.sentences = rd32(h + 20);
    i.factor_x10 = (uint64_t)rd32(h + 24) | ((uint64_t)rd32(h + 28) << 32);
    memcpy(i.sha256, h + 32, 32);
    memcpy(i.title, h + 64, sizeof i.title);
    i.title[sizeof i.title - 1] = '\0';
    if (i.words == 0 || (long)i.bytes != txt_size || idx_size != (long)(READER_IDX_HEADER + 4u * (uint64_t)i.words)) return false;
    if (out) *out = i;
    return true;
}

bool reader_text_info(const char *id, reader_text_info_t *out)
{
    if (!storage_id_valid(id)) return false;
    char path[96];
    struct stat st_txt, st_idx;
    reader_text_path(id, path, sizeof path);
    if (stat(path, &st_txt) != 0) return false;
    reader_idx_path(id, path, sizeof path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    uint8_t h[READER_IDX_HEADER];
    bool ok = fstat(fd, &st_idx) == 0 && read(fd, h, sizeof h) == (ssize_t)sizeof h &&
              parse_header(h, id, (long)st_idx.st_size, (long)st_txt.st_size, out);
    close(fd);
    return ok;
}

bool reader_text_exists(const char *id) { return reader_text_info(id, NULL); }

/* Ids of `ext` files in `dir`. cb(id) per file; returns the count. */
static size_t list_ids(const char *dir, const char *ext, bool (*cb)(const char *id, void *ctx), void *ctx)
{
    DIR *d = opendir(dir);
    if (!d) return 0;
    size_t n = 0, el = strlen(ext);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        size_t l = strlen(e->d_name);
        if (l <= el || strcmp(e->d_name + l - el, ext) != 0 || l - el > STORAGE_ID_MAX) continue;
        char id[STORAGE_ID_MAX + 1];
        memcpy(id, e->d_name, l - el);
        id[l - el] = '\0';
        if (!storage_id_valid(id)) continue;
        n++;
        if (cb && !cb(id, ctx)) break;
    }
    closedir(d);
    return n;
}

typedef struct { reader_text_cb_t cb; void *ctx; size_t n; } text_iter_t;

static bool text_iter(const char *id, void *ctx)
{
    text_iter_t *it = ctx;
    reader_text_info_t info;
    if (!reader_text_info(id, &info)) return true;   /* incomplete pair: skipped */
    it->n++;
    return it->cb ? it->cb(&info, it->ctx) : true;
}

size_t reader_text_foreach(reader_text_cb_t cb, void *ctx)
{
    text_iter_t it = { cb, ctx, 0 };
    list_ids(TEXT_DIR, ".idx", text_iter, &it);
    return it.n;
}

struct reader_writer {
    char id[STORAGE_ID_MAX + 1];
    char tmp_txt[96], tmp_idx[96];
    int fd_txt, fd_idx;
    size_t total, written;
    mbedtls_sha256_context sha;
    rsvp_tok_t tok;
    uint32_t idx[IDX_BUF];
    size_t idx_n;
    bool io_err, no_space;
    char head[HEAD_BYTES];
    size_t head_n;
};

static bool write_all(int fd, const void *data, size_t len)
{
    const uint8_t *p = data;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) return false;
        p += n;
        len -= (size_t)n;
    }
    return true;
}

static void idx_flush(reader_writer_t *w)
{
    if (!w->idx_n || w->io_err) {
        w->idx_n = 0;
        return;
    }
    uint8_t buf[IDX_BUF * 4];
    for (size_t i = 0; i < w->idx_n; i++) wr32(buf + 4 * i, w->idx[i]);
    if (!write_all(w->fd_idx, buf, w->idx_n * 4)) {
        w->io_err = true;
        w->no_space = free_bytes() < SPACE_MARGIN;
    }
    w->idx_n = 0;
}

static void idx_add(reader_writer_t *w, const rsvp_word_t *words, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        w->idx[w->idx_n++] = (words[i].off & READER_IDX_OFF_MASK) | ((uint32_t)words[i].flags << READER_IDX_FLAG_SHIFT);
        if (w->idx_n == IDX_BUF) idx_flush(w);
    }
}

static void tokenise(reader_writer_t *w, const char *data, size_t len)
{
    rsvp_word_t words[32];
    size_t pos = 0;
    while (pos < len) {
        size_t used = 0;
        size_t n = rsvp_tok_feed(&w->tok, data + pos, len - pos, &used, words, 32);
        idx_add(w, words, n);
        pos += used;
    }
}

storage_status_t reader_text_write_begin(const char *id, size_t total, reader_writer_t **out)
{
    *out = NULL;
    if (!storage_id_valid(id) || total == 0) return STORAGE_ERR_ARG;
    if (total > READER_TEXT_MAX_BYTES) return STORAGE_ERR_NO_SPACE;
    /* text + typical index (~0.7x the text; worst case 2x is reported as no_space while writing) */
    if (free_bytes() < total + total / 2 + SPACE_MARGIN) return STORAGE_ERR_NO_SPACE;
    if (!reader_text_exists(id) && list_ids(TEXT_DIR, ".idx", NULL, NULL) >= READER_MAX_TEXTS) return STORAGE_ERR_TOO_MANY;
    /* internal RAM (~1.7 KB): holds the hardware SHA context, like the asset writer */
    reader_writer_t *w = calloc(1, sizeof *w);
    if (!w) return STORAGE_ERR_IO;
    strlcpy(w->id, id, sizeof w->id);
    snprintf(w->tmp_txt, sizeof w->tmp_txt, TEXT_DIR "/" TMP_PREFIX "%s.txt", id);
    snprintf(w->tmp_idx, sizeof w->tmp_idx, TEXT_DIR "/" TMP_PREFIX "%s.idx", id);
    w->fd_txt = open(w->tmp_txt, O_WRONLY | O_CREAT | O_TRUNC, 0664);
    w->fd_idx = open(w->tmp_idx, O_RDWR | O_CREAT | O_TRUNC, 0664);
    uint8_t hdr[READER_IDX_HEADER] = { 0 };
    if (w->fd_txt < 0 || w->fd_idx < 0 || !write_all(w->fd_idx, hdr, sizeof hdr)) {
        ESP_LOGE(TAG, "cannot create temp files for %s", id);
        reader_text_write_abort(w);
        return STORAGE_ERR_IO;
    }
    w->total = total;
    mbedtls_sha256_init(&w->sha);
    mbedtls_sha256_starts(&w->sha, 0);
    rsvp_tok_init(&w->tok, 0, RSVP_TOK_TITLE_BREAK);
    *out = w;
    return STORAGE_OK;
}

storage_status_t reader_text_write(reader_writer_t *w, const void *data, size_t len)
{
    if (w->written + len > w->total) return STORAGE_ERR_ARG;
    if (!write_all(w->fd_txt, data, len)) {
        ESP_LOGE(TAG, "text write failed after %u bytes", (unsigned)w->written);
        return free_bytes() < SPACE_MARGIN ? STORAGE_ERR_NO_SPACE : STORAGE_ERR_IO;
    }
    mbedtls_sha256_update(&w->sha, data, len);
    if (w->head_n < HEAD_BYTES) {
        size_t k = HEAD_BYTES - w->head_n < len ? HEAD_BYTES - w->head_n : len;
        memcpy(w->head + w->head_n, data, k);
        w->head_n += k;
    }
    tokenise(w, data, len);
    w->written += len;
    if (w->io_err) return w->no_space ? STORAGE_ERR_NO_SPACE : STORAGE_ERR_IO;
    return STORAGE_OK;
}

void reader_text_write_abort(reader_writer_t *w)
{
    if (!w) return;
    if (w->fd_txt >= 0) close(w->fd_txt);
    if (w->fd_idx >= 0) close(w->fd_idx);
    unlink(w->tmp_txt);
    unlink(w->tmp_idx);
    mbedtls_sha256_free(&w->sha);
    free(w);
}

storage_status_t reader_text_write_finish(reader_writer_t *w, const uint8_t expected_sha[32], reader_text_info_t *out)
{
    storage_status_t st = STORAGE_OK;
    reader_text_info_t info = { 0 };
    strlcpy(info.id, w->id, sizeof info.id);
    if (w->written != w->total) st = STORAGE_ERR_ARG;
    if (st == STORAGE_OK) {
        mbedtls_sha256_finish(&w->sha, info.sha256);
        if (memcmp(info.sha256, expected_sha, 32) != 0) st = STORAGE_ERR_HASH;
    }
    if (st == STORAGE_OK) {
        rsvp_word_t words[2];
        idx_add(w, words, rsvp_tok_finish(&w->tok, words, 2));
        idx_flush(w);
        const rsvp_stats_t *ts = rsvp_tok_stats(&w->tok);
        if (w->io_err) {
            st = w->no_space ? STORAGE_ERR_NO_SPACE : STORAGE_ERR_IO;
        } else if (ts->invalid || ts->nul || ts->words == 0) {
            ESP_LOGW(TAG, "text %s rejected: %u invalid UTF-8 sequences, %u NUL bytes, %u words", w->id,
                     (unsigned)ts->invalid, (unsigned)ts->nul, (unsigned)ts->words);
            st = STORAGE_ERR_MALFORMED;
        } else {
            info.bytes = (uint32_t)w->total;
            info.words = ts->words;
            info.paragraphs = ts->paragraphs;
            info.sentences = ts->sentences;
            info.factor_x10 = ts->factor_x10;
            rsvp_title(w->head, w->head_n, info.title, sizeof info.title);
            uint8_t h[READER_IDX_HEADER] = { 0 };
            memcpy(h, "RSX1", 4);
            wr32(h + 4, 1);
            wr32(h + 8, info.words);
            wr32(h + 12, info.bytes);
            wr32(h + 16, info.paragraphs);
            wr32(h + 20, info.sentences);
            wr32(h + 24, (uint32_t)info.factor_x10);
            wr32(h + 28, (uint32_t)(info.factor_x10 >> 32));
            memcpy(h + 32, info.sha256, 32);
            memcpy(h + 64, info.title, strlen(info.title));
            if (lseek(w->fd_idx, 0, SEEK_SET) != 0 || !write_all(w->fd_idx, h, sizeof h)) st = STORAGE_ERR_IO;
        }
    }
    if (st == STORAGE_OK && (fsync(w->fd_txt) != 0 || fsync(w->fd_idx) != 0)) st = STORAGE_ERR_IO;
    if (st == STORAGE_OK) {
        close(w->fd_txt);
        close(w->fd_idx);
        w->fd_txt = w->fd_idx = -1;
        char txt[96], idx[96];
        reader_text_path(w->id, txt, sizeof txt);
        reader_idx_path(w->id, idx, sizeof idx);
        lock();
        /* text first, index last: an index only exists next to its complete text */
        unlink(idx);
        if (rename(w->tmp_txt, txt) != 0 || rename(w->tmp_idx, idx) != 0) {
            unlink(txt);
            unlink(idx);
            st = STORAGE_ERR_IO;
        }
        unlock();
    }
    if (st != STORAGE_OK) {
        ESP_LOGW(TAG, "text upload %s rejected: %s", w->id, storage_status_str(st));
        reader_text_write_abort(w);
        return st;
    }
    ESP_LOGI(TAG, "stored text %s: %u B, %u words, %u paragraphs, \"%s\"", info.id, (unsigned)info.bytes,
             (unsigned)info.words, (unsigned)info.paragraphs, info.title);
    mbedtls_sha256_free(&w->sha);
    free(w);
    if (out) *out = info;
    return STORAGE_OK;
}

storage_status_t reader_text_delete(const char *id)
{
    if (!storage_id_valid(id)) return STORAGE_ERR_ARG;
    char path[96];
    bool found = false;
    lock();
    reader_idx_path(id, path, sizeof path);
    found |= unlink(path) == 0;
    reader_text_path(id, path, sizeof path);
    found |= unlink(path) == 0;
    unlock();
    reader_progress_remove(id);
    return found ? STORAGE_OK : STORAGE_ERR_NOT_FOUND;
}

/* ------------------------------------------------------------------ fonts */

static esp_err_t check_atlas(const char *id, const rsvp_face_t *f, const char *what, char *msg, size_t msg_len)
{
    asset_info_t a;
    if (!storage_asset_find(id, &a) || !a.atlas) {
        snprintf(msg, msg_len, "%s \"%s\" is not an uploaded glyph atlas", what, id);
        return ESP_ERR_NOT_FOUND;
    }
    if (a.width != f->cell_w || a.height != f->cell_h || a.frames < f->count) {
        snprintf(msg, msg_len, "%s \"%s\" is %ux%u with %u glyphs, the font needs %ux%u and %u", what, id, a.width, a.height,
                 a.frames, f->cell_w, f->cell_h, f->count);
        return ESP_ERR_INVALID_ARG;
    }
    return ESP_OK;
}

esp_err_t reader_font_validate(const char *json, size_t len, char *msg, size_t msg_len)
{
    rsvp_font_t *f = heap_caps_malloc(sizeof *f, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!f) f = malloc(sizeof *f);
    if (!f) return ESP_ERR_NO_MEM;
    char err[64];
    esp_err_t r = ESP_OK;
    if (rsvp_font_parse(json, len, f, err, sizeof err) != RSVP_OK) {
        snprintf(msg, msg_len, "malformed font document: %s", err);
        r = ESP_ERR_INVALID_ARG;
    }
    if (r == ESP_OK) r = check_atlas(f->normal.atlas_white, &f->normal, "atlas_white", msg, msg_len);
    if (r == ESP_OK) r = check_atlas(f->normal.atlas_accent, &f->normal, "atlas_accent", msg, msg_len);
    if (r == ESP_OK && f->has_compact) r = check_atlas(f->compact.atlas_white, &f->compact, "compact.atlas_white", msg, msg_len);
    if (r == ESP_OK && f->has_compact) r = check_atlas(f->compact.atlas_accent, &f->compact, "compact.atlas_accent", msg, msg_len);
    /* §5f.11 the optional "large" face (the Oracle's text screens) */
    if (r == ESP_OK && f->has_large) r = check_atlas(f->large.atlas_white, &f->large, "large.atlas_white", msg, msg_len);
    if (r == ESP_OK && f->has_large) r = check_atlas(f->large.atlas_accent, &f->large, "large.atlas_accent", msg, msg_len);
    free(f);
    return r;
}

esp_err_t reader_font_store(const char *id, const char *json, size_t len)
{
    if (!storage_id_valid(id)) return ESP_ERR_INVALID_ARG;
    if (!reader_font_exists(id) && reader_font_foreach(NULL, NULL) >= READER_MAX_FONTS) return ESP_ERR_NO_MEM;
    char name[64];
    snprintf(name, sizeof name, "fonts/%s.json", id);
    lock();
    esp_err_t err = storage_write_file(name, json, len);
    unlock();
    return err;
}

bool reader_font_exists(const char *id)
{
    if (!storage_id_valid(id)) return false;
    char path[96];
    struct stat st;
    font_path(id, path, sizeof path);
    return stat(path, &st) == 0 && st.st_size > 0;
}

esp_err_t reader_font_read(const char *id, char **json, size_t *len)
{
    *json = NULL;
    if (!storage_id_valid(id)) return ESP_ERR_INVALID_ARG;
    char name[64];
    snprintf(name, sizeof name, "fonts/%s.json", id);
    return storage_read_file(name, json, len, READER_FONT_MAX_BYTES);
}

storage_status_t reader_font_delete(const char *id)
{
    if (!storage_id_valid(id)) return STORAGE_ERR_ARG;
    char path[96];
    font_path(id, path, sizeof path);
    lock();
    bool ok = unlink(path) == 0;
    unlock();
    return ok ? STORAGE_OK : STORAGE_ERR_NOT_FOUND;
}

size_t reader_font_foreach(reader_font_cb_t cb, void *ctx) { return list_ids(FONT_DIR, ".json", cb, ctx); }

/* ------------------------------------------------------------------ progress */

typedef struct { char id[STORAGE_ID_MAX + 1]; uint32_t word; } prog_t;
static prog_t *s_prog;        /* READER_PROGRESS_MAX entries, most recent first */
static size_t s_prog_n;
static bool s_prog_loaded;

static void prog_load_locked(void)
{
    if (s_prog_loaded) return;
    if (!s_prog) s_prog = heap_caps_calloc(READER_PROGRESS_MAX, sizeof *s_prog, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_prog) s_prog = calloc(READER_PROGRESS_MAX, sizeof *s_prog);
    if (!s_prog) return;
    s_prog_loaded = true;
    s_prog_n = 0;
    char *buf = NULL;
    size_t len = 0;
    if (storage_read_file(PROGRESS_FILE, &buf, &len, 8192) != ESP_OK) return;
    cJSON *root = cJSON_ParseWithLength(buf, len);
    free(buf);
    const cJSON *p = cJSON_GetObjectItemCaseSensitive(root, "progress"), *e;
    if (!cJSON_IsObject(p)) p = NULL;
    cJSON_ArrayForEach(e, p) {
        if (s_prog_n >= READER_PROGRESS_MAX) break;
        if (!e->string || !storage_id_valid(e->string) || !cJSON_IsNumber(e) || e->valuedouble < 0 || e->valuedouble > 4294967295.0) continue;
        strlcpy(s_prog[s_prog_n].id, e->string, sizeof s_prog[s_prog_n].id);
        s_prog[s_prog_n].word = (uint32_t)e->valuedouble;
        s_prog_n++;
    }
    cJSON_Delete(root);
}

static esp_err_t prog_save_locked(void)
{
    /* {"version":1,"progress":{"<32 chars>":4294967295,...}}: <= 64 * 47 + 40 bytes */
    size_t cap = 40 + READER_PROGRESS_MAX * 48;
    char *s = malloc(cap);
    if (!s) return ESP_ERR_NO_MEM;
    size_t o = (size_t)snprintf(s, cap, "{\"version\":1,\"progress\":{");
    for (size_t i = 0; i < s_prog_n; i++) {
        o += (size_t)snprintf(s + o, cap - o, "%s\"%s\":%lu", i ? "," : "", s_prog[i].id, (unsigned long)s_prog[i].word);
    }
    o += (size_t)snprintf(s + o, cap - o, "}}");
    esp_err_t err = storage_write_file(PROGRESS_FILE, s, o);
    free(s);
    return err;
}

static int prog_find_locked(const char *id)
{
    for (size_t i = 0; i < s_prog_n; i++) if (strcmp(s_prog[i].id, id) == 0) return (int)i;
    return -1;
}

uint32_t reader_progress_get(const char *id)
{
    lock();
    prog_load_locked();
    int i = s_prog ? prog_find_locked(id) : -1;
    uint32_t w = i >= 0 ? s_prog[i].word : 0;
    unlock();
    return w;
}

esp_err_t reader_progress_set(const char *id, uint32_t word)
{
    if (!storage_id_valid(id)) return ESP_ERR_INVALID_ARG;
    lock();
    prog_load_locked();
    if (!s_prog) {
        unlock();
        return ESP_ERR_NO_MEM;
    }
    int i = prog_find_locked(id);
    if (i == 0 && s_prog[0].word == word) {   /* unchanged: no flash write */
        unlock();
        return ESP_OK;
    }
    size_t from = i >= 0 ? (size_t)i : (s_prog_n < READER_PROGRESS_MAX ? s_prog_n : READER_PROGRESS_MAX - 1);
    if (i < 0 && s_prog_n < READER_PROGRESS_MAX) s_prog_n++;
    memmove(&s_prog[1], &s_prog[0], from * sizeof *s_prog);   /* oldest falls off the end when full */
    strlcpy(s_prog[0].id, id, sizeof s_prog[0].id);
    s_prog[0].word = word;
    esp_err_t err = prog_save_locked();
    unlock();
    if (err != ESP_OK) ESP_LOGW(TAG, "progress not saved: %s", esp_err_to_name(err));
    return err;
}

void reader_progress_remove(const char *id)
{
    lock();
    prog_load_locked();
    int i = s_prog ? prog_find_locked(id) : -1;
    if (i >= 0) {
        memmove(&s_prog[i], &s_prog[i + 1], (s_prog_n - (size_t)i - 1) * sizeof *s_prog);
        s_prog_n--;
        prog_save_locked();
    }
    unlock();
}
