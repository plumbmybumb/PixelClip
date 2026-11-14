/* storage.c — LittleFS asset store with an in-RAM index and verified streaming writes. */
#include "storage.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "esp_littlefs.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_check.h"
#include "mbedtls/sha256.h"
#include "hca.h"

static const char *TAG = "storage";

#define PARTITION_LABEL "assets"
#define ASSET_DIR       STORAGE_ROOT "/assets"
#define TMP_PREFIX      ".tmp-"
#define SPACE_MARGIN    (16 * 1024)   /* keep a few LittleFS blocks free for metadata */
#define PANEL_W 536
#define PANEL_H 240

struct storage_writer {
    char id[STORAGE_ID_MAX + 1];
    char tmp_path[96];
    int fd;
    size_t total, written;
    mbedtls_sha256_context sha;
};

static SemaphoreHandle_t s_mutex;
static asset_info_t *s_index;   /* PSRAM, STORAGE_MAX_ASSETS entries */
static size_t s_count;

static void lock(void)   { xSemaphoreTake(s_mutex, portMAX_DELAY); }
static void unlock(void) { xSemaphoreGive(s_mutex); }

const char *storage_status_str(storage_status_t s)
{
    switch (s) {
    case STORAGE_OK: return "ok";
    case STORAGE_ERR_ARG: return "bad_request";
    case STORAGE_ERR_NOT_FOUND: return "not_found";
    case STORAGE_ERR_NO_SPACE: return "no_space";
    case STORAGE_ERR_HASH: return "sha256_mismatch";
    case STORAGE_ERR_MALFORMED: return "malformed";
    case STORAGE_ERR_TOO_MANY: return "too_many_assets";
    default: return "io_error";
    }
}

bool storage_id_valid(const char *id)
{
    if (!id) return false;
    size_t n = strlen(id);
    if (n < 1 || n > STORAGE_ID_MAX) return false;
    for (size_t i = 0; i < n; i++) {
        char c = id[i];
        bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (i > 0 && c == '-');
        if (!ok) return false;
    }
    return true;
}

void storage_sha_to_hex(const uint8_t sha[32], char hex[65])
{
    static const char digits[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        hex[2 * i] = digits[sha[i] >> 4];
        hex[2 * i + 1] = digits[sha[i] & 0xF];
    }
    hex[64] = '\0';
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    c = (char)tolower((unsigned char)c);
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

bool storage_hex_to_sha(const char *hex, uint8_t sha[32])
{
    if (!hex || strlen(hex) != 64) return false;
    for (int i = 0; i < 32; i++) {
        int hi = hexval(hex[2 * i]), lo = hexval(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        sha[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}

void storage_asset_path(const char *id, char *buf, size_t len)
{
    snprintf(buf, len, ASSET_DIR "/%s.hca", id);
}

static void sha_path(const char *id, char *buf, size_t len)
{
    snprintf(buf, len, ASSET_DIR "/%s.sha", id);
}

static void abs_path(const char *name, char *buf, size_t len)
{
    snprintf(buf, len, STORAGE_ROOT "/%s", name);
}

void storage_usage(size_t *total, size_t *used)
{
    size_t t = 0, u = 0;
    esp_err_t err = esp_littlefs_info(PARTITION_LABEL, &t, &u);
    if (err != ESP_OK) ESP_LOGE(TAG, "littlefs_info: %s", esp_err_to_name(err));
    if (total) *total = t;
    if (used) *used = u;
}

static size_t free_bytes(void)
{
    size_t t, u;
    storage_usage(&t, &u);
    return t > u ? t - u : 0;
}

/* ---------- .hca validation ---------- */

/* Read and validate header + frame table of an open file of `size` bytes. */
static storage_status_t validate_hca_fd(int fd, size_t size, asset_info_t *info)
{
    uint8_t hdr[HCA_HEADER_SIZE];
    if (size < HCA_HEADER_SIZE) return STORAGE_ERR_MALFORMED;
    if (lseek(fd, 0, SEEK_SET) != 0 || read(fd, hdr, sizeof hdr) != (ssize_t)sizeof hdr) return STORAGE_ERR_IO;
    if (memcmp(hdr, HCA_MAGIC, 4) != 0) return STORAGE_ERR_MALFORMED;
    uint16_t frames = (uint16_t)(hdr[8] | (hdr[9] << 8));
    if (frames == 0 || frames > STORAGE_MAX_FRAMES) return STORAGE_ERR_MALFORMED;
    size_t tbytes = hca_table_bytes(frames);
    if (tbytes > size) return STORAGE_ERR_MALFORMED;

    uint8_t *table = heap_caps_malloc(tbytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!table) return STORAGE_ERR_IO;
    storage_status_t st = STORAGE_OK;
    hca_asset_t a;
    if (lseek(fd, 0, SEEK_SET) != 0 || read(fd, table, tbytes) != (ssize_t)tbytes) {
        st = STORAGE_ERR_IO;
    } else {
        hca_status_t hs = hca_open(&a, table, tbytes);
        if (hs != HCA_OK) {
            ESP_LOGW(TAG, "hca_open: %s", hca_status_str(hs));
            st = STORAGE_ERR_MALFORMED;
        } else if (a.hdr.data_size != size) {
            ESP_LOGW(TAG, "data_size %lu != file size %u", (unsigned long)a.hdr.data_size, (unsigned)size);
            st = STORAGE_ERR_MALFORMED;
        } else if (a.hdr.flags & STORAGE_HCA_FLAG_STRIP) {
            /* Strip: one wide frame (PROTOCOL §4 "Scrolling strips"). */
            if ((a.hdr.flags & HCA_FLAG_GLYPH_ATLAS) || a.hdr.frame_count != 1 || a.hdr.height != STORAGE_STRIP_H ||
                a.hdr.width < STORAGE_STRIP_MIN_W || a.hdr.width > STORAGE_STRIP_MAX_W) {
                ESP_LOGW(TAG, "strip must be 1 frame, %d..%d x %d, not an atlas (got %ux%u, %u frames, flags 0x%x)",
                         STORAGE_STRIP_MIN_W, STORAGE_STRIP_MAX_W, STORAGE_STRIP_H, a.hdr.width, a.hdr.height,
                         a.hdr.frame_count, a.hdr.flags);
                st = STORAGE_ERR_MALFORMED;
            } else if (info) {
                info->size = (uint32_t)size;
                info->width = a.hdr.width;
                info->height = a.hdr.height;
                info->frames = 1;
                info->atlas = false;
                info->strip = true;
            }
        } else if (a.hdr.width == 0 || a.hdr.height == 0 || a.hdr.width > PANEL_W || a.hdr.height > PANEL_H) {
            st = STORAGE_ERR_MALFORMED;
        } else if (!(a.hdr.flags & HCA_FLAG_GLYPH_ATLAS) &&
                   (a.hdr.width != PANEL_W || a.hdr.height != PANEL_H)) {
            ESP_LOGW(TAG, "non-atlas asset must be %dx%d (got %ux%u)", PANEL_W, PANEL_H, a.hdr.width, a.hdr.height);
            st = STORAGE_ERR_MALFORMED;
        } else if (info) {
            info->size = (uint32_t)size;
            info->width = a.hdr.width;
            info->height = a.hdr.height;
            info->frames = a.hdr.frame_count;
            info->atlas = (a.hdr.flags & HCA_FLAG_GLYPH_ATLAS) != 0;
            info->strip = false;
        }
    }
    free(table);
    return st;
}

/* ---------- streaming frame decoder (strips) ---------- */

#define STREAM_BUF 4096

typedef struct {
    int fd;
    uint8_t *buf;
    size_t pos, fill;
    uint32_t left;           /* frame bytes not yet read from the file */
    unsigned refills;
    /* output */
    uint16_t *dst;
    size_t stride;
    uint32_t w, x0, cw;
    uint32_t col;            /* column of the next pixel */
    size_t row_off;          /* dst offset of the current row */
} stream_t;

/* Make at least `need` (<= 2) unread bytes available. False at the end of the frame data / error. */
static bool stream_ensure(stream_t *r, size_t need, bool *io_err)
{
    if (r->fill - r->pos >= need) return true;
    size_t keep = r->fill - r->pos;
    memmove(r->buf, r->buf + r->pos, keep);
    r->pos = 0;
    r->fill = keep;
    while (r->fill < need && r->left) {
        size_t want = STREAM_BUF - r->fill;
        if (want > r->left) want = r->left;
        ssize_t n = read(r->fd, r->buf + r->fill, want);
        if (n <= 0) {
            *io_err = true;
            return false;
        }
        r->fill += (size_t)n;
        r->left -= (uint32_t)n;
        if ((++r->refills & 63) == 0) vTaskDelay(1);   /* multi-MB strips: let IDLE run (TWDT) */
    }
    return r->fill >= need;
}

/* Emit n pixels: `lit` points at n big-endian pixels (literal), or NULL = n copies of `px`. */
static void stream_emit(stream_t *r, const uint8_t *lit, uint16_t px, size_t n)
{
    while (n) {
        size_t k = r->w - r->col;
        if (k > n) k = n;
        if (r->dst) {
            uint32_t lo = r->col > r->x0 ? r->col : r->x0;
            uint32_t hi = r->col + k < r->x0 + r->cw ? r->col + (uint32_t)k : r->x0 + r->cw;
            if (lo < hi) {
                uint16_t *d = r->dst + r->row_off + (lo - r->x0);
                if (lit) {
                    memcpy(d, lit + (size_t)(lo - r->col) * 2u, (size_t)(hi - lo) * 2u);
                } else {
                    for (uint32_t i = lo; i < hi; i++) *d++ = px;
                }
            }
        }
        if (lit) lit += k * 2u;
        n -= k;
        r->col += (uint32_t)k;
        if (r->col == r->w) {
            r->col = 0;
            r->row_off += r->stride;
        }
    }
}

storage_status_t storage_frame_stream(int fd, uint32_t off, uint32_t len, uint16_t w, uint16_t h, uint8_t compression,
                                      uint16_t *dst, size_t dst_stride, uint16_t x0, uint16_t cw)
{
    if (w == 0 || h == 0 || (dst && ((uint32_t)x0 + cw > w || dst_stride < cw))) return STORAGE_ERR_ARG;
    const uint64_t npx = (uint64_t)w * h;
    if (lseek(fd, (off_t)off, SEEK_SET) != (off_t)off) return STORAGE_ERR_IO;
    if (compression == HCA_COMP_RAW) {
        if ((uint64_t)len != npx * 2u) return STORAGE_ERR_MALFORMED;
        if (!dst) return STORAGE_OK;   /* length is all there is to check */
        for (uint32_t y = 0; y < h; y++) {
            off_t o = (off_t)off + ((off_t)y * w + x0) * 2;
            if (lseek(fd, o, SEEK_SET) != o) return STORAGE_ERR_IO;
            uint8_t *d = (uint8_t *)(dst + (size_t)y * dst_stride);
            size_t want = (size_t)cw * 2u;
            while (want) {
                ssize_t n = read(fd, d, want);
                if (n <= 0) return STORAGE_ERR_IO;
                d += n;
                want -= (size_t)n;
            }
            if ((y & 31) == 31) vTaskDelay(1);
        }
        return STORAGE_OK;
    }
    if (compression != HCA_COMP_RLE16) return STORAGE_ERR_MALFORMED;
    stream_t r = { .fd = fd, .left = len, .dst = dst, .stride = dst_stride, .w = w, .x0 = x0, .cw = cw };
    r.buf = malloc(STREAM_BUF);
    if (!r.buf) return STORAGE_ERR_IO;
    storage_status_t st = STORAGE_OK;
    bool io_err = false;
    uint64_t left_px = npx;
    while (left_px && st == STORAGE_OK) {
        if (!stream_ensure(&r, 2, &io_err)) { st = io_err ? STORAGE_ERR_IO : STORAGE_ERR_MALFORMED; break; }   /* underrun */
        unsigned c = (unsigned)r.buf[r.pos] | ((unsigned)r.buf[r.pos + 1] << 8);
        r.pos += 2;
        size_t n = (size_t)(c & 0x7FFFu) + 1u;
        if (n > left_px) { st = STORAGE_ERR_MALFORMED; break; }                                            /* overrun */
        left_px -= n;
        if (c & 0x8000u) {
            if (!stream_ensure(&r, 2, &io_err)) { st = io_err ? STORAGE_ERR_IO : STORAGE_ERR_MALFORMED; break; }
            uint16_t px;
            memcpy(&px, r.buf + r.pos, 2);
            r.pos += 2;
            stream_emit(&r, NULL, px, n);
        } else {
            while (n) {
                if (!stream_ensure(&r, 2, &io_err)) { st = io_err ? STORAGE_ERR_IO : STORAGE_ERR_MALFORMED; break; }
                size_t k = (r.fill - r.pos) / 2u;
                if (k > n) k = n;
                stream_emit(&r, r.buf + r.pos, 0, k);
                r.pos += k * 2u;
                n -= k;
            }
        }
    }
    if (st == STORAGE_OK && (r.left || r.fill != r.pos)) st = STORAGE_ERR_MALFORMED;   /* trailing bytes */
    free(r.buf);
    return st;
}

/* Strip upload: walk the single frame without decoding it anywhere (an 8192-px strip decodes to
 * 3.9 MB, which may not be free while the player holds another strip). */
static storage_status_t validate_strip_fd(int fd, size_t size)
{
    uint8_t t[HCA_HEADER_SIZE + HCA_FRAME_ENTRY_SIZE];
    hca_asset_t a;
    hca_frame_info_t fi;
    if (lseek(fd, 0, SEEK_SET) != 0 || read(fd, t, sizeof t) != (ssize_t)sizeof t) return STORAGE_ERR_IO;
    if (hca_open(&a, t, sizeof t) != HCA_OK || hca_frame_info(&a, 0, &fi) != HCA_OK ||
        (size_t)fi.offset + fi.length > size) {
        return STORAGE_ERR_MALFORMED;
    }
    storage_status_t st = storage_frame_stream(fd, fi.offset, fi.length, a.hdr.width, a.hdr.height, a.hdr.compression,
                                               NULL, 0, 0, 0);
    if (st == STORAGE_ERR_MALFORMED) ESP_LOGW(TAG, "strip frame does not decode exactly");
    return st;
}

/* Decode every frame of an uploaded file once (PROTOCOL §2 exactness: RLE16 frames must produce
 * exactly w*h pixels from exactly `length` bytes). Header checks alone let a corrupt RLE stream
 * through to the player; this rejects it with 422 instead. Constant memory per frame, PSRAM. */
static storage_status_t validate_frames_fd(int fd, size_t size)
{
    uint8_t hdr[HCA_HEADER_SIZE];
    if (lseek(fd, 0, SEEK_SET) != 0 || read(fd, hdr, sizeof hdr) != (ssize_t)sizeof hdr) return STORAGE_ERR_IO;
    uint16_t frames = (uint16_t)(hdr[8] | (hdr[9] << 8));
    size_t tbytes = hca_table_bytes(frames);
    uint8_t *table = heap_caps_malloc(tbytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!table) return STORAGE_ERR_IO;
    storage_status_t st = STORAGE_OK;
    hca_asset_t a = {0};
    uint16_t *dst = NULL;
    uint8_t *src = NULL;
    size_t src_cap = 0;
    if (lseek(fd, 0, SEEK_SET) != 0 || read(fd, table, tbytes) != (ssize_t)tbytes) {
        st = STORAGE_ERR_IO;
    } else if (hca_open(&a, table, tbytes) != HCA_OK) {
        st = STORAGE_ERR_MALFORMED;
    } else {
        dst = heap_caps_malloc((size_t)a.hdr.width * a.hdr.height * 2, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!dst) st = STORAGE_ERR_IO;
    }
    for (uint16_t i = 0; st == STORAGE_OK && i < a.hdr.frame_count; i++) {
        hca_frame_info_t fi;
        if (hca_frame_info(&a, i, &fi) != HCA_OK || (size_t)fi.offset + fi.length > size) {
            st = STORAGE_ERR_MALFORMED;
            break;
        }
        if (fi.length > src_cap) {
            uint8_t *p = heap_caps_realloc(src, fi.length, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (!p) { st = STORAGE_ERR_IO; break; }
            src = p;
            src_cap = fi.length;
        }
        if (lseek(fd, (off_t)fi.offset, SEEK_SET) != (off_t)fi.offset ||
            read(fd, src, fi.length) != (ssize_t)fi.length) {
            st = STORAGE_ERR_IO;
            break;
        }
        hca_status_t hs = hca_decode_frame_from(&a.hdr, src, fi.length, dst, a.hdr.width);
        if (hs != HCA_OK) {
            ESP_LOGW(TAG, "frame %u does not decode: %s", i, hca_status_str(hs));
            st = STORAGE_ERR_MALFORMED;
        }
        if ((i & 7) == 7) vTaskDelay(1); /* long assets: let IDLE run (task watchdog) */
    }
    free(src);
    free(dst);
    free(table);
    return st;
}

static bool hash_fd(int fd, uint8_t out[32])
{
    const size_t chunk = 4096;
    uint8_t *buf = malloc(chunk);
    if (!buf) return false;
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    bool ok = lseek(fd, 0, SEEK_SET) == 0;
    ssize_t n;
    unsigned blocks = 0;
    while (ok && (n = read(fd, buf, chunk)) > 0) {
        mbedtls_sha256_update(&ctx, buf, (size_t)n);
        if ((++blocks & 31) == 0) vTaskDelay(1); /* multi-MB rehash at boot: feed IDLE / TWDT */
    }
    if (ok) mbedtls_sha256_finish(&ctx, out);
    mbedtls_sha256_free(&ctx);
    free(buf);
    return ok;
}

/* ---------- index ---------- */

static int index_find_locked(const char *id)
{
    for (size_t i = 0; i < s_count; i++) {
        if (strcmp(s_index[i].id, id) == 0) return (int)i;
    }
    return -1;
}

static storage_status_t index_put_locked(const asset_info_t *info)
{
    int i = index_find_locked(info->id);
    if (i >= 0) {
        s_index[i] = *info;
        return STORAGE_OK;
    }
    if (s_count >= STORAGE_MAX_ASSETS) return STORAGE_ERR_TOO_MANY;
    s_index[s_count++] = *info;
    return STORAGE_OK;
}

static void index_remove_locked(const char *id)
{
    int i = index_find_locked(id);
    if (i < 0) return;
    memmove(&s_index[i], &s_index[i + 1], (s_count - (size_t)i - 1) * sizeof(asset_info_t));
    s_count--;
}

static bool write_sidecar(const char *id, const uint8_t sha[32])
{
    char path[96], hex[65];
    sha_path(id, path, sizeof path);
    storage_sha_to_hex(sha, hex);
    FILE *f = fopen(path, "w");
    if (!f) return false;
    bool ok = fwrite(hex, 1, 64, f) == 64;
    ok = (fclose(f) == 0) && ok;
    return ok;
}

static bool read_sidecar(const char *id, uint8_t sha[32])
{
    char path[96], hex[65] = {0};
    sha_path(id, path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) return false;
    size_t n = fread(hex, 1, 64, f);
    fclose(f);
    return n == 64 && storage_hex_to_sha(hex, sha);
}

static void index_one(const char *id)
{
    char path[96];
    storage_asset_path(id, path, sizeof path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return;
    struct stat stt;
    asset_info_t info = {0};
    strlcpy(info.id, id, sizeof info.id);
    storage_status_t vst = fstat(fd, &stt) != 0 ? STORAGE_ERR_IO
                         : validate_hca_fd(fd, (size_t)stt.st_size, &info);
    if (vst == STORAGE_ERR_IO) {
        /* Transient (read error / out of memory): skip it this boot, never delete user data. */
        ESP_LOGE(TAG, "cannot read asset %s, not indexed this boot", id);
        close(fd);
        return;
    }
    if (vst != STORAGE_OK) {
        ESP_LOGW(TAG, "dropping invalid asset %s (%s)", id, storage_status_str(vst));
        close(fd);
        unlink(path);
        sha_path(id, path, sizeof path);
        unlink(path);
        return;
    }
    if (!read_sidecar(id, info.sha256)) {
        ESP_LOGI(TAG, "rehashing %s", id);
        if (!hash_fd(fd, info.sha256) || !write_sidecar(id, info.sha256)) {
            ESP_LOGE(TAG, "hash/sidecar failed for %s", id);
        }
    }
    close(fd);
    if (index_put_locked(&info) != STORAGE_OK) ESP_LOGW(TAG, "index full, ignoring %s", id);
}

static void build_index(void)
{
    DIR *d = opendir(ASSET_DIR);
    if (!d) {
        ESP_LOGE(TAG, "opendir %s failed", ASSET_DIR);
        return;
    }
    struct dirent *e;
    char path[128];
    while ((e = readdir(d)) != NULL) {
        const char *name = e->d_name;
        size_t n = strlen(name);
        if (strncmp(name, TMP_PREFIX, strlen(TMP_PREFIX)) == 0) {
            snprintf(path, sizeof path, ASSET_DIR "/%s", name);
            unlink(path); /* interrupted upload */
            continue;
        }
        if (n > 4 && strcmp(name + n - 4, ".hca") == 0) {
            char id[STORAGE_ID_MAX + 1];
            if (n - 4 > STORAGE_ID_MAX) continue;
            memcpy(id, name, n - 4);
            id[n - 4] = '\0';
            if (storage_id_valid(id)) index_one(id);
        }
    }
    closedir(d);
}

esp_err_t storage_init(void)
{
    s_mutex = xSemaphoreCreateMutex();
    s_index = heap_caps_calloc(STORAGE_MAX_ASSETS, sizeof(asset_info_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    ESP_RETURN_ON_FALSE(s_mutex && s_index, ESP_ERR_NO_MEM, TAG, "no mem");

    esp_vfs_littlefs_conf_t conf = {
        .base_path = STORAGE_ROOT,
        .partition_label = PARTITION_LABEL,
        .format_if_mount_failed = true,
        .dont_mount = false,
    };
    ESP_RETURN_ON_ERROR(esp_vfs_littlefs_register(&conf), TAG, "littlefs mount");
    struct stat st;
    if (stat(ASSET_DIR, &st) != 0 && mkdir(ASSET_DIR, 0775) != 0) {
        ESP_LOGE(TAG, "mkdir %s failed", ASSET_DIR);
        return ESP_FAIL;
    }
    lock();
    build_index();
    unlock();
    size_t total, used;
    storage_usage(&total, &used);
    ESP_LOGI(TAG, "LittleFS mounted: %u assets, %u/%u KB used", (unsigned)s_count,
             (unsigned)(used / 1024), (unsigned)(total / 1024));
    return ESP_OK;
}

size_t storage_asset_count(void)
{
    lock();
    size_t n = s_count;
    unlock();
    return n;
}

bool storage_asset_at(size_t idx, asset_info_t *out)
{
    lock();
    bool ok = idx < s_count;
    if (ok && out) *out = s_index[idx];
    unlock();
    return ok;
}

bool storage_asset_find(const char *id, asset_info_t *out)
{
    if (!storage_id_valid(id)) return false;
    lock();
    int i = index_find_locked(id);
    if (i >= 0 && out) *out = s_index[i];
    unlock();
    return i >= 0;
}

/* ---------- streaming writes ---------- */

storage_status_t storage_asset_write_begin(const char *id, size_t total, storage_writer_t **out)
{
    *out = NULL;
    if (!storage_id_valid(id) || total < HCA_HEADER_SIZE) return STORAGE_ERR_ARG;
    const size_t free_b = free_bytes();   /* (total + SPACE_MARGIN wraps on a 32-bit size_t for a 4 GB Content-Length) */
    if (total > free_b || free_b - total < SPACE_MARGIN) return STORAGE_ERR_NO_SPACE;
    lock();
    bool full = index_find_locked(id) < 0 && s_count >= STORAGE_MAX_ASSETS;
    unlock();
    if (full) return STORAGE_ERR_TOO_MANY;

    storage_writer_t *w = calloc(1, sizeof *w);
    if (!w) return STORAGE_ERR_IO;
    strlcpy(w->id, id, sizeof w->id);
    snprintf(w->tmp_path, sizeof w->tmp_path, ASSET_DIR "/" TMP_PREFIX "%s", id);
    w->fd = open(w->tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0664);
    if (w->fd < 0) {
        ESP_LOGE(TAG, "open %s failed", w->tmp_path);
        free(w);
        return STORAGE_ERR_IO;
    }
    w->total = total;
    mbedtls_sha256_init(&w->sha);
    mbedtls_sha256_starts(&w->sha, 0);
    *out = w;
    return STORAGE_OK;
}

storage_status_t storage_asset_write(storage_writer_t *w, const void *data, size_t len)
{
    if (w->written + len > w->total) return STORAGE_ERR_ARG;
    const uint8_t *p = data;
    size_t left = len;
    while (left) {
        ssize_t n = write(w->fd, p, left);
        if (n <= 0) {
            ESP_LOGE(TAG, "write failed after %u bytes", (unsigned)w->written);
            return free_bytes() < SPACE_MARGIN ? STORAGE_ERR_NO_SPACE : STORAGE_ERR_IO;
        }
        p += n;
        left -= (size_t)n;
    }
    mbedtls_sha256_update(&w->sha, data, len);
    w->written += len;
    return STORAGE_OK;
}

void storage_asset_write_abort(storage_writer_t *w)
{
    if (!w) return;
    if (w->fd >= 0) close(w->fd);
    unlink(w->tmp_path);
    mbedtls_sha256_free(&w->sha);
    free(w);
}

storage_status_t storage_asset_write_finish(storage_writer_t *w, const uint8_t expected_sha[32],
                                            asset_info_t *out)
{
    storage_status_t st = STORAGE_OK;
    asset_info_t info = {0};
    strlcpy(info.id, w->id, sizeof info.id);

    if (w->written != w->total) st = STORAGE_ERR_ARG;
    if (st == STORAGE_OK) {
        mbedtls_sha256_finish(&w->sha, info.sha256);
        if (memcmp(info.sha256, expected_sha, 32) != 0) st = STORAGE_ERR_HASH;
    }
    if (st == STORAGE_OK && fsync(w->fd) != 0) st = STORAGE_ERR_IO;
    close(w->fd);
    w->fd = -1;
    if (st == STORAGE_OK) {
        int fd = open(w->tmp_path, O_RDONLY);
        if (fd < 0) {
            st = STORAGE_ERR_IO;
        } else {
            st = validate_hca_fd(fd, w->total, &info);
            if (st == STORAGE_OK) st = info.strip ? validate_strip_fd(fd, w->total) : validate_frames_fd(fd, w->total);
            close(fd);
        }
    }
    if (st == STORAGE_OK) {
        char path[96];
        storage_asset_path(w->id, path, sizeof path);
        lock();
        /* lfs_rename() atomically replaces an existing destination. */
        if (rename(w->tmp_path, path) != 0 || !write_sidecar(w->id, info.sha256)) {
            st = STORAGE_ERR_IO;
            index_remove_locked(w->id);
        } else {
            st = index_put_locked(&info);
        }
        unlock();
    }
    if (st == STORAGE_OK) {
        if (out) *out = info;
        ESP_LOGI(TAG, "stored %s: %u B, %ux%u, %u frame(s)%s", info.id, (unsigned)info.size,
                 info.width, info.height, info.frames, info.atlas ? " [atlas]" : info.strip ? " [strip]" : "");
        mbedtls_sha256_free(&w->sha);
        free(w);
        return STORAGE_OK;
    }
    ESP_LOGW(TAG, "upload %s rejected: %s", w->id, storage_status_str(st));
    storage_asset_write_abort(w);
    return st;
}

storage_status_t storage_asset_delete(const char *id)
{
    if (!storage_id_valid(id)) return STORAGE_ERR_ARG;
    char path[96];
    lock();
    int i = index_find_locked(id);
    if (i >= 0) {
        storage_asset_path(id, path, sizeof path);
        unlink(path);
        sha_path(id, path, sizeof path);
        unlink(path);
        index_remove_locked(id);
    }
    unlock();
    return i >= 0 ? STORAGE_OK : STORAGE_ERR_NOT_FOUND;
}

/* ---------- small files ---------- */

esp_err_t storage_read_file(const char *name, char **out, size_t *len, size_t max_len)
{
    char path[96];
    abs_path(name, path, sizeof path);
    *out = NULL;
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0 || (size_t)sz > max_len) {
        fclose(f);
        return ESP_ERR_INVALID_SIZE;
    }
    char *buf = malloc((size_t)sz + 1);
    if (!buf) {
        fclose(f);
        return ESP_ERR_NO_MEM;
    }
    size_t n = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (n != (size_t)sz) {
        free(buf);
        return ESP_FAIL;
    }
    buf[n] = '\0';
    *out = buf;
    if (len) *len = n;
    return ESP_OK;
}

esp_err_t storage_write_file(const char *name, const void *data, size_t len)
{
    char path[96], tmp[104];
    abs_path(name, path, sizeof path);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return ESP_FAIL;
    bool ok = fwrite(data, 1, len, f) == len;
    ok = (fclose(f) == 0) && ok;
    if (ok) ok = rename(tmp, path) == 0; /* atomic replace on LittleFS */
    if (!ok) {
        unlink(tmp);
        ESP_LOGE(TAG, "write %s failed", name);
        return ESP_FAIL;
    }
    return ESP_OK;
}

esp_err_t storage_append_file(const char *name, const void *data, size_t len)
{
    char path[96];
    abs_path(name, path, sizeof path);
    FILE *f = fopen(path, "ab");
    if (!f) return ESP_FAIL;
    bool ok = fwrite(data, 1, len, f) == len;
    ok = (fclose(f) == 0) && ok;
    return ok ? ESP_OK : ESP_FAIL;
}

long storage_file_size(const char *name)
{
    char path[96];
    struct stat st;
    abs_path(name, path, sizeof path);
    return stat(path, &st) == 0 ? (long)st.st_size : -1;
}

esp_err_t storage_remove_file(const char *name)
{
    char path[96];
    abs_path(name, path, sizeof path);
    return unlink(path) == 0 ? ESP_OK : ESP_ERR_NOT_FOUND;
}

esp_err_t storage_rename_file(const char *from, const char *to)
{
    char a[96], b[96];
    abs_path(from, a, sizeof a);
    abs_path(to, b, sizeof b);
    return rename(a, b) == 0 ? ESP_OK : ESP_FAIL;
}
