/* player.c — playlist state machine, frame streaming, transitions, live scenes and the
 * "tonight" scheduler (time windows + queue[] interrupts, decisions in components/sched). */
#include "player.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_check.h"
#include "esp_random.h"

#include "hca.h"
#include "display.h"
#include "ui.h"
#include "storage.h"
#include "playlist.h"
#include "appcfg.h"
#include "timekeeping.h"
#include "power.h"
#include "health.h"
#include "sched.h"
#include "rsvp.h"
#include "reader_store.h"
#include "textlay.h"
#include "oracle.h"
#include "oracle_reader.h"
#include "oracle_text.h"
#include "board.h"
#include "esp_mac.h"
#include "nvs.h"
#include "imu.h"
#include "orient.h"
#include "orient_priv.h"

static const char *TAG = "player";

#define PLAYER_TASK_STACK 8192   /* cJSON playlist parse (items + queue entries) + file I/O + decode */
#define PLAYER_TASK_PRIO  4
#define STILL_DEFAULT_MS  5000
#define FRAME_DEFAULT_MS  100
#define SCRATCH_MAX       (DISPLAY_FB_BYTES * 2)   /* PROTOCOL §2: an RLE16 frame is at most 4 bytes per pixel */
#define SCHED_TICK_US     1000000
#define SCENE_FRAME_US    33333  /* 30 fps target (>= 25 fps required) */
#define SCENE_MIN_GAP_US  2000   /* always block a little between frames (idle task / TWDT) */
#define SCENE_FRAME_UPLOAD_US 66667   /* 15 fps while an upload body is received (player_upload_active) */
#define SCENE_STATS_US    5000000
#define SCENE_WARMUP      40     /* offscreen render: simulate ~1.3 s so /screenshot shows something */
#define STRIP_FRAME_US    33333  /* scrolling strips: 30 fps target */
#define STRIP_STATS_US    5000000
#define STRIP_PSRAM_RESERVE (512 * 1024)   /* left free after a strip buffer (uploads, screenshot, JSON) */
#define STRIP_MAX_SEGS    8
#define READER_TXT_READ   (RSVP_WORD_MAX_BYTES + 8)   /* bytes read at a word's offset */
#define READER_SAVE_EVERY 50                          /* PROTOCOL §5c: progress every 50 words */
#define READER_IDX_CACHE  128                         /* index entries read per block */
#define READER_STATS_US   10000000
#define BADGE_SIZE        6                             /* upload-session connection dot */
#define BADGE_X           (DISPLAY_W - 8 - BADGE_SIZE)  /* top-right corner, 8 px from both edges */
#define BADGE_Y           8
#define BADGE_STEP_US     100000                        /* pulse: 16 steps of 100 ms = 1.6 s period */
#define BADGE_STEPS       16
#define FREEZE_MAX_US     30000000                      /* player_release_files() safety net */
#define DEFER_MAX         4
#define OR_POLL_US        50000                         /* oracle: shake metric polled at 20 Hz while the IMU runs */
#define OR_DECK_PSRAM_RESERVE (512 * 1024)              /* left free after the deck cache (uploads, screenshot, JSON) */
#define ORR_BUNDLE_MAX    PL_OR_BUNDLE_MAX              /* a bundle larger than this is not loaded (§5f.2: ~80 KB) */

_Static_assert(PLAYER_ORACLE_READING_MAX == ORR_TEXT_MAX, "player.h reading size = the reader's paragraph budget");

typedef enum {
    CMD_NEXT, CMD_PREV, CMD_SHOW_ASSET, CMD_RELOAD, CMD_BRIGHTNESS,
    CMD_OUTPUT, CMD_REFRESH, CMD_QUEUE_TEST, CMD_TIME, CMD_READER, CMD_BADGE, CMD_RELEASE,
    CMD_ORIENT, CMD_SHOW_ITEM, CMD_ORACLE, CMD_FORGET,
} cmd_type_t;

typedef struct {
    cmd_type_t type;
    char id[SCHED_ID_MAX + 1];
    uint32_t value;
    uint32_t arg;
    pl_scroll_t scroll;      /* CMD_SHOW_ASSET: "scroll" of POST /show (scroll.on = given) */
    SemaphoreHandle_t ack;
} cmd_t;

typedef enum { CUR_NONE, CUR_IDLE, CUR_ASSET, CUR_SCENE, CUR_READER, CUR_ORACLE, CUR_BOARD } cur_kind_t;

/* CMD_ORACLE actions (value; arg = card + 1 for a draw) */
enum { OR_CMD_PRESS, OR_CMD_TURN, OR_CMD_DRAW, OR_CMD_BACK };

typedef struct {
    cur_kind_t kind;
    pl_item_t item;
    bool override;           /* "show now" or queue entry: not part of the rotation */
    bool queue_entry;        /* the override is a queue[] entry (wins over /show) */
    char queue_id[SCHED_ID_MAX + 1];
    bool single;             /* the only active rotation item: plays until something changes */
    /* asset streaming */
    int fd;
    uint8_t *table;          /* header + frame table (PSRAM) */
    hca_asset_t asset;       /* geometry + table only; frames come through s_scratch */
    uint16_t frame;
    uint32_t loops_done;
    bool loop_bounded;       /* ends after item.loops loops */
    /* scrolling strip (asset with is_strip, PROTOCOL §4 "Scrolling strips") */
    bool strip;              /* the current asset is a strip */
    bool scrolling;          /* ... and scrolls: strip_px holds the decoded strip */
    uint16_t *strip_px;      /* strip_w x DISPLAY_H pixels (PSRAM), freed when the item ends */
    uint16_t strip_w;
    int64_t scroll_t0_us;    /* esp_timer time of travel 0 */
    uint64_t scroll_end_px;  /* travel at which the item ends, 0 = endless tape */
    uint64_t scroll_last_px; /* travel of the frame on screen */
    /* timing (esp_timer microseconds, 0 = none) */
    int64_t next_frame_us;
    int64_t end_us;
    int64_t next_tick_us;    /* board: once a second */
} cur_t;

static QueueHandle_t s_q;
static playlist_t *s_pl;
static int s_index = -1;
static bool s_output = true;
static uint8_t s_brightness;
static cur_t s_cur = { .fd = -1 };
static uint8_t *s_scratch;
static size_t s_scratch_cap;
static SemaphoreHandle_t s_status_mutex;
static player_status_t s_status;
static bool s_has_windows;           /* some rotation item has from/until */
static int s_idle_active = -1;       /* active_count() when the idle screen went up */
static int64_t s_next_sched_us;      /* 1 Hz scheduler tick (0 = not needed) */
static bool s_pending_show;          /* a /show that arrived during a queue entry */
static pl_item_t s_pending_item;
static player_badge_t s_badge;       /* upload-session connection dot */
static uint32_t s_badge_phase;
static int64_t s_badge_next_us;      /* next pulse step (0 = steady / off) */
static bool s_frozen;                /* player_release_files(): current item's files closed, timers stopped */
static int64_t s_frozen_until_us;
static cmd_t s_deferred[DEFER_MAX];  /* asynchronous commands that arrived while frozen */
static int s_deferred_n;
static volatile int s_uploads_rx;     /* player_upload_active(): scenes throttled while > 0 */
static bool s_reload_frozen;          /* CMD_RELOAD arrived while frozen (the item's file was released) */
static struct {
    bool perf;               /* CPU perf lock held while a strip scrolls on the panel */
    int64_t stat_t0;
    uint32_t frames;
    uint64_t compose_us, flush_us;
} s_st;

/* A reader font (PROTOCOL §5c) in PSRAM: the document, its 2-4 atlases and a glyph-decode scratch. Used
 * by Reader mode and by the Oracle's text screens. */
typedef struct {
    char id[STORAGE_ID_MAX + 1];
    rsvp_font_t *font;
    uint8_t *atlas_data[6];
    hca_asset_t atlas[6];
    bool want_large;          /* §5f.11: also the "large" face (the Oracle's fonts only; Reader ignores it) */
    uint16_t *scratch;
    size_t scratch_px;
} fontc_t;

/* Reader mode (PROTOCOL §5c): font cache + the reading in progress. */
typedef enum { RD_WORD, RD_BLANK, RD_END } rd_phase_t;
static struct {
    /* font cache (PSRAM), kept while the same font id is used */
    fontc_t fc;
    /* the reading */
    bool active;
    reader_text_info_t info;
    int fd_txt, fd_idx;
    uint8_t idx_raw[READER_IDX_CACHE * 4];
    uint32_t idx_base, idx_n;
    rsvp_painter_t painter;
    bool fb_dirty;           /* someone else painted the framebuffer: next paint is a full one */
    uint32_t word;           /* index of the word on screen */
    rsvp_word_t cur;
    rd_phase_t phase;
    uint32_t since_save;
    bool paused;
    int64_t remaining_us;    /* duration_ms cap left while paused (0 = none) */
    char paused_text[STORAGE_ID_MAX + 1];   /* stays paused when the same text restarts ... */
    char held_text[STORAGE_ID_MAX + 1];     /* lone reader item: its end card is held (restarts show it again) */
    bool keep_pause;                        /* ... for a reload / session end, not for next/prev */
    /* stats */
    int64_t stat_t0;
    uint32_t words_shown;
    uint64_t paint_us, flush_us;
} s_rd = { .fd_txt = -1, .fd_idx = -1 };
static player_reader_status_t s_rstat;
static SemaphoreHandle_t s_rd_lock, s_rd_ack;
static volatile esp_err_t s_rd_result;

/* Oracle (PROTOCOL §5f), see "Oracle" below. */
typedef struct {
    uint8_t *table;          /* header + frame table (PSRAM) */
    hca_asset_t a;           /* geometry + table only; frames are streamed from the file */
    int fd;                  /* open while painting / shuffling, else -1 */
} or_file_t;
static struct {
    or_t o;
    pl_oracle_t cfg;
    char ids[OR_ASSETS][33]; /* text, deck, keys, notes ("" = unused) */
    or_file_t f[OR_ASSETS];
    or_draw_t shown;         /* what the framebuffer holds */
    bool shown_ok;
    bool perf, imu;          /* holds: perf while a shuffle runs, IMU while visible */
    int64_t last_us;         /* esp_timer time the state machine was stepped to */
    int64_t shuf_t0;         /* stats of the running shuffle */
    uint32_t frames;
    uint64_t paint_us, flush_us;
    uint32_t paint_max_us;
    /* the deck's compressed frames in PSRAM while the item shows (shuffle frames: decode + flush only) */
    uint8_t *deck_mem;
    hca_asset_t deck_full;   /* hca_open over deck_mem (whole file) */
    bool deck_tried;         /* the cache was attempted for this item (once) */
    bool hint;               /* §5f.11 the corner arrow was painted last, and its corner (left = the panel flipped) */
    bool hint_left;
} s_or = { .f = { { .fd = -1 }, { .fd = -1 }, { .fd = -1 }, { .fd = -1 } } };
/* The sentence reader (PROTOCOL §5f.1): the item's phrase bundle and font (loaded at the first paragraph, kept until the
 * item ends) and the paragraph of the row on screen; the text screens are laid out with core textlay.h. */
static struct {
    char text_id[STORAGE_ID_MAX + 1];   /* the loaded bundle ("" = none) */
    char *text;                         /* bundle bytes (PSRAM) */
    size_t text_len;
    void *arena;                        /* orr_parse arena (PSRAM, orr_arena_bytes: ~16 KB for a 35 KB bundle) */
    orr_bundle_t *b;
    fontc_t fc;                         /* the item's "font" (body: text screens and the paragraph) */
    fontc_t fcb;                        /* its "font_big" (the face's numeral; unloaded = the body font) */
    textlay_layout_t *tlay;             /* text screens' layout work area (PSRAM) */
    uint16_t *tscratch;                 /* glyph scratch for both fonts */
    size_t tscratch_px;
    uint32_t text_paints;               /* text screens drawn, their cost (stats) */
    uint64_t text_us;
    uint32_t text_max_us;
    bool active;                        /* para holds the paragraph of this draw (para_draw) */
    uint32_t para_draw;                 /* or_t.draws it was composed for */
    char para[ORR_OUT_MIN];
    char lean[OR_LEAN_SCREENS][ORR_OUT_MIN];   /* §5f.7 by card, by position, by the numbers, together, and */
    rsvp_font_t *lview, *cview;         /* §5f.11 views of the body font whose normal face is its large / compact face */
    bool lview_ok, cview_ok;
    uint32_t faces[4];                  /* text screens drawn per face: large, normal, compact, cut (stats) */
} s_orr;
static bool fontc_load(fontc_t *c, const char *font_id, const char *what);
static void fontc_unload(fontc_t *c);

static player_oracle_status_t s_orstat = { .drawn = { -1, -1, -1 }, .card = -1, .page = -1 };

static pl_item_t s_show_req;          /* CMD_SHOW_ITEM payload (too big for the command queue), under s_status_mutex */

/* §5g the board on screen: the core composition and its sheet decoded in PSRAM. */
static struct {
    board_t b;
    uint16_t *px;            /* the sheet's frames (N*w*h*2 B, PSRAM) */
    size_t bytes;
    int64_t last_us;         /* the scroll was stepped to */
    bool invalidate;         /* someone else painted the framebuffer */
    uint32_t frames;         /* stats */
    uint64_t render_us, flush_us;
    int64_t stat_t0;
} s_bd;

#if PL_SCENES
static scene_t s_scene;
static uint8_t *s_arena;
static size_t s_arena_cap;
static struct {
    bool perf, imu;          /* resources held while a scene runs on the panel */
    int64_t last_step_us;
    int64_t stat_t0;
    uint32_t frames;
    uint64_t step_us, render_us, flush_us;
    bool invalidate;         /* someone else painted the framebuffer: next render repaints all */
    uint16_t *sprites;       /* §5b.1 words: the sheet's frames decoded (PSRAM), read by the scene while it runs */
    size_t sprites_bytes;
} s_sc;
#endif

/* The framebuffer was painted (or the panel faded) by something other than the running scene: its
 * next render must not rely on the previous frame (scene_invalidate, core/README "Live scenes"). */
static void fb_touched(void)
{
    s_rd.fb_dirty = true;
    s_bd.invalidate = true;
#if PL_SCENES
    s_sc.invalidate = true;
#endif
}

/* Upload-session connection dot (display overlay, see player_set_badge). Steady = full accent colour;
 * pulse = a triangle wave between 25 % and 100 % of it, one step per BADGE_STEP_US. */
static void badge_paint(void)
{
    if (s_badge == PLAYER_BADGE_OFF || !s_output) {
        display_overlay_clear();
        s_badge_next_us = 0;
        return;
    }
    uint16_t c = UI_ACCENT;   /* = DISPLAY_RGB565BE(198, 162, 255) */
    if (s_badge == PLAYER_BADGE_PULSE) {
        const int ph = (int)(s_badge_phase++ % BADGE_STEPS);
        const int tri = ph < BADGE_STEPS / 2 ? ph : BADGE_STEPS - ph;   /* 0..8..0 */
        const int pct = 25 + tri * 75 / (BADGE_STEPS / 2);
        c = DISPLAY_RGB565BE(198 * pct / 100, 162 * pct / 100, 255 * pct / 100);
        const int64_t now = esp_timer_get_time();
        s_badge_next_us = (s_badge_next_us && s_badge_next_us + BADGE_STEP_US > now) ? s_badge_next_us + BADGE_STEP_US
                                                                                      : now + BADGE_STEP_US;
    } else {
        s_badge_next_us = 0;
    }
    uint16_t px[BADGE_SIZE * BADGE_SIZE];
    uint8_t mask[BADGE_SIZE * BADGE_SIZE];
    for (int y = 0; y < BADGE_SIZE; y++) {
        for (int x = 0; x < BADGE_SIZE; x++) {
            const bool corner = (x == 0 || x == BADGE_SIZE - 1) && (y == 0 || y == BADGE_SIZE - 1);
            px[y * BADGE_SIZE + x] = c;
            mask[y * BADGE_SIZE + x] = !corner;   /* a dot with clipped corners */
        }
    }
    esp_err_t err = display_overlay_set(BADGE_X, BADGE_Y, BADGE_SIZE, BADGE_SIZE, px, mask);
    if (err != ESP_OK) ESP_LOGW(TAG, "badge: %s", esp_err_to_name(err));
}

/* ------------------------------------------------------------------ helpers */

static void publish_status(void)
{
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    s_status.count = s_pl->count;
    s_status.index = s_pl->count ? s_index : -1;
    s_status.override = s_cur.override;
    switch (s_cur.kind) {
    case CUR_ASSET: strlcpy(s_status.current, s_cur.item.id, sizeof s_status.current); break;
    case CUR_SCENE:
        strlcpy(s_status.current, "scene:", sizeof s_status.current);
        strlcat(s_status.current, s_cur.item.id, sizeof s_status.current);
        break;
    case CUR_READER:
        strlcpy(s_status.current, "reader:", sizeof s_status.current);
        strlcat(s_status.current, s_cur.item.id, sizeof s_status.current);
        break;
    case CUR_ORACLE:
        strlcpy(s_status.current, "oracle:", sizeof s_status.current);
        strlcat(s_status.current, s_cur.item.id, sizeof s_status.current);
        break;
    case CUR_BOARD:
        strlcpy(s_status.current, "board:", sizeof s_status.current);
        strlcat(s_status.current, s_cur.item.id, sizeof s_status.current);
        break;
    default: s_status.current[0] = '\0'; break;
    }
    xSemaphoreGive(s_status_mutex);
}

static void publish_reader(void)
{
    player_reader_status_t r = { 0 };
    if (s_cur.kind == CUR_READER && s_rd.active) {
        r.active = true;
        strlcpy(r.text, s_rd.info.id, sizeof r.text);
        strlcpy(r.font, s_cur.item.font, sizeof r.font);
        strlcpy(r.title, s_rd.info.title, sizeof r.title);
        r.word = s_rd.word;
        r.words = s_rd.info.words;
        r.paused = s_rd.paused;
        r.end_card = s_rd.phase == RD_END;
        r.wpm = s_cur.item.wpm;
    }
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    s_rstat = r;
    xSemaphoreGive(s_status_mutex);
}

static void scene_release(void);
static void scene_close(void);
static void board_close(void);
static void or_close(void);
static void publish_oracle(void);
static void advance(int dir);
static void end_override(bool allow_pending);
static void reader_close(void);
static void reader_font_unload(void);

static void strip_hold(bool on)
{
    if (on && !s_st.perf) power_perf_acquire(POWER_PERF_STRIP);
    if (!on && s_st.perf) power_perf_release(POWER_PERF_STRIP);
    s_st.perf = on;
}

/* Drop the decoded strip (item ended, or the panel goes off: a session needs the PSRAM). */
static void strip_release(void)
{
    strip_hold(false);
    free(s_cur.strip_px);
    s_cur.strip_px = NULL;
    s_cur.scrolling = false;
}

static void close_current(void)
{
    if (s_cur.kind == CUR_SCENE) scene_close();
    if (s_cur.kind == CUR_BOARD) board_close();
    if (s_cur.kind == CUR_READER) reader_close();
    const bool was_or = s_cur.kind == CUR_ORACLE;
    if (was_or) or_close();
    strip_release();
    s_cur.strip = false;
    if (s_cur.fd >= 0) close(s_cur.fd);
    free(s_cur.table);
    s_cur.fd = -1;
    s_cur.table = NULL;
    memset(&s_cur.asset, 0, sizeof s_cur.asset);   /* its data pointed into `table` */
    s_cur.kind = CUR_NONE;
    s_cur.next_frame_us = s_cur.end_us = s_cur.next_tick_us = 0;
    if (was_or) publish_oracle();
}

static bool ensure_scratch(size_t n)
{
    if (n <= s_scratch_cap) return true;
    if (n > SCRATCH_MAX) return false;
    uint8_t *p = heap_caps_realloc(s_scratch, n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!p) return false;
    s_scratch = p;
    s_scratch_cap = n;
    return true;
}

static bool read_exact(int fd, uint32_t off, void *dst, size_t len)
{
    if (lseek(fd, (off_t)off, SEEK_SET) != (off_t)off) return false;
    uint8_t *p = dst;
    while (len) {
        ssize_t n = read(fd, p, len);
        if (n <= 0) return false;
        p += n;
        len -= (size_t)n;
    }
    return true;
}

/* Load a whole asset into PSRAM. */
static uint8_t *load_whole(const char *id, size_t *size_out)
{
    asset_info_t info;
    if (!storage_asset_find(id, &info)) return NULL;
    char path[96];
    storage_asset_path(id, path, sizeof path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    uint8_t *buf = heap_caps_malloc(info.size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    bool ok = buf && read_exact(fd, 0, buf, info.size);
    close(fd);
    if (!ok) {
        free(buf);
        return NULL;
    }
    *size_out = info.size;
    return buf;
}

/* ------------------------------------------------------------------ board (PROTOCOL §5g) */

static int64_t next_second_boundary_us(void);

static void board_close(void)
{
    free(s_bd.px);
    s_bd.px = NULL;
    s_bd.bytes = 0;
}

#define BOARD_PSRAM_SPARE (512u * 1024u)
/* The sheet decoded into PSRAM (N*w*h*2 B, at most 2 MB), the core board set up and rendered into the framebuffer
 * (caller holds display_lock and flushes). Needs the frames + 512 KB of headroom in the largest PSRAM block. */
static bool board_begin(const pl_item_t *it)
{
    const int64_t t0 = esp_timer_get_time();
    board_close();
    size_t sz = 0;
    uint8_t *file = load_whole(it->id, &sz);
    hca_asset_t a;
    if (!file || hca_open(&a, file, sz) != HCA_OK) {
        ESP_LOGW(TAG, "board: sheet %s missing or unreadable", it->id);
        free(file);
        return false;
    }
    const uint16_t w = a.hdr.width, h = a.hdr.height;
    const uint32_t n = a.hdr.frame_count;
    const size_t bytes = (size_t)n * w * h * 2u, largest = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
    if (n < 1 || n > BOARD_MAX_FRAMES || (uint64_t)n * w * h > BOARD_MAX_PX || largest < bytes + BOARD_PSRAM_SPARE) {
        ESP_LOGW(TAG, "board: sheet %s: %lu frames %ux%u, %u B of frames (+%u B kept free), largest PSRAM block %u B",
                 it->id, (unsigned long)n, w, h, (unsigned)bytes, (unsigned)BOARD_PSRAM_SPARE, (unsigned)largest);
        free(file);
        return false;
    }
    s_bd.px = heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    const uint16_t *frames[BOARD_MAX_FRAMES];
    bool ok = s_bd.px != NULL;
    for (uint32_t f = 0; f < n && ok; f++) {
        uint16_t *dst = s_bd.px + (size_t)f * w * h;
        frames[f] = dst;
        ok = hca_decode_frame(&a, (uint16_t)f, dst, w) == HCA_OK;
    }
    free(file);
    board_row_t rows[BOARD_MAX_ROWS];
    const pl_board_t *pb = &it->board;
    for (int i = 0; i < pb->nrows; i++) {
        rows[i] = (board_row_t){ .frame = pb->frame[i], .has_until = (pb->has_until >> i) & 1u, .until = pb->until[i] };
    }
    ok = ok && board_init(&s_bd.b, frames, (int)n, w, h, rows, pb->nrows, pb->header, pb->empty, pb->speed, DISPLAY_W,
                          DISPLAY_H) == BOARD_OK;
    if (!ok) {
        ESP_LOGW(TAG, "board: sheet %s could not be decoded or set up", it->id);
        board_close();
        return false;
    }
    s_bd.bytes = bytes;
    board_set_clock(&s_bd.b, timekeeping_now(), timekeeping_synced());
    board_render(&s_bd.b, display_fb(), DISPLAY_W, DISPLAY_H, NULL);
    s_bd.invalidate = false;
    s_bd.frames = 0;
    s_bd.render_us = s_bd.flush_us = 0;
    ESP_LOGI(TAG, "board: sheet %s: %lu frames %ux%u, %u B in PSRAM, decoded in %lld ms (largest block now %u B); "
             "%u of %u rows (clock %s), %s at %u px/s", it->id, (unsigned long)n, w, h, (unsigned)bytes,
             (long long)((esp_timer_get_time() - t0) / 1000), (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM),
             s_bd.b.nshown, s_bd.b.nrows, timekeeping_synced() ? "synced" : "unknown: every row",
             s_bd.b.scrolling ? "scrolling" : "static", s_bd.b.speed);
    return true;
}

/* Render what changed and flush it (the rows' column, or the whole screen). */
static void board_paint(void)
{
    const int64_t t0 = esp_timer_get_time();
    board_rect_t d;
    power_perf_begin();
    display_lock();
    if (s_bd.invalidate) {
        board_invalidate(&s_bd.b);
        s_bd.invalidate = false;
    }
    board_render(&s_bd.b, display_fb(), DISPLAY_W, DISPLAY_H, &d);
    const int64_t t1 = esp_timer_get_time();
    if (d.w > 0 && d.h > 0 && s_output) {
        const esp_err_t err = display_flush_rect(d.x, d.y, d.w, d.h);
        if (err != ESP_OK) ESP_LOGE(TAG, "board flush: %s", esp_err_to_name(err));
    }
    display_unlock();
    power_perf_end();
    s_bd.frames++;
    s_bd.render_us += (uint64_t)(t1 - t0);
    s_bd.flush_us += (uint64_t)(esp_timer_get_time() - t1);
}

/* Once a second: the row set from the clock (an expiry while scrolling waits for the loop boundary). */
static void board_tick(void)
{
    const bool was = s_bd.b.scrolling;
    const uint8_t n0 = s_bd.b.nshown;
    if (board_set_clock(&s_bd.b, timekeeping_now(), timekeeping_synced())) board_paint();
    if (s_bd.b.nshown != n0) ESP_LOGI(TAG, "board %s: %u of %u rows now", s_cur.item.id, s_bd.b.nshown, s_bd.b.nrows);
    const int64_t now = esp_timer_get_time();
    if (s_bd.b.scrolling && !was) {
        s_bd.last_us = now;
        s_cur.next_frame_us = now + (int64_t)BOARD_FRAME_MS * 1000;
    }
    s_cur.next_tick_us = next_second_boundary_us();
}

/* A scroll frame (<= 30 fps, only while scrolling). */
static void board_frame(void)
{
    const int64_t now = esp_timer_get_time();
    int64_t el = now - s_bd.last_us;
    if (el < 0) el = 0;
    if (el > 1000000) el = 1000000;
    const uint32_t dt = (uint32_t)(el / 1000);
    s_bd.last_us += (int64_t)dt * 1000;
    const uint8_t n0 = s_bd.b.nshown;
    if (board_step(&s_bd.b, dt) || s_bd.invalidate) board_paint();
    if (s_bd.b.nshown != n0) ESP_LOGI(TAG, "board %s: %u of %u rows at the loop boundary%s", s_cur.item.id, s_bd.b.nshown,
                                       s_bd.b.nrows, s_bd.b.scrolling ? "" : " (static now)");
    if (now - s_bd.stat_t0 >= 30000000 && s_bd.frames) {
        ESP_LOGI(TAG, "board %s: %lu frames in 30 s, render %llu us, flush %llu us (avg)", s_cur.item.id,
                 (unsigned long)s_bd.frames, (unsigned long long)(s_bd.render_us / s_bd.frames),
                 (unsigned long long)(s_bd.flush_us / s_bd.frames));
        s_bd.stat_t0 = now;
        s_bd.frames = 0;
        s_bd.render_us = s_bd.flush_us = 0;
    }
    if (!s_bd.b.scrolling) {
        s_cur.next_frame_us = 0;
        return;
    }
    s_cur.next_frame_us += (int64_t)BOARD_FRAME_MS * 1000;
    if (s_cur.next_frame_us < now + 2000) s_cur.next_frame_us = now + (int64_t)BOARD_FRAME_MS * 1000;   /* late: no burst */
}

/* ------------------------------------------------------------------ clock ticks */

static int64_t next_second_boundary_us(void)
{
    int64_t wall = timekeeping_now_us();
    return esp_timer_get_time() + (1000000 - wall % 1000000) + 2000;
}

/* ------------------------------------------------------------------ asset streaming */

static bool asset_open(const char *id)
{
    asset_info_t info;
    if (!storage_asset_find(id, &info) || info.atlas) return false;
    char path[96];
    storage_asset_path(id, path, sizeof path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    size_t tbytes = hca_table_bytes(info.frames);
    uint8_t *table = heap_caps_malloc(tbytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!table || !read_exact(fd, 0, table, tbytes) || hca_open(&s_cur.asset, table, tbytes) != HCA_OK ||
        s_cur.asset.hdr.width != DISPLAY_W || s_cur.asset.hdr.height != DISPLAY_H) {   /* asset_decode: the framebuffer */
        ESP_LOGW(TAG, "cannot open asset %s", id);
        memset(&s_cur.asset, 0, sizeof s_cur.asset);
        free(table);
        close(fd);
        return false;
    }
    s_cur.fd = fd;
    s_cur.table = table;
    return true;
}

/* Read frame `idx` from flash and decode it into the framebuffer (caller holds display_lock). */
static bool asset_decode(uint16_t idx)
{
    hca_frame_info_t fi;
    if (hca_frame_info(&s_cur.asset, idx, &fi) != HCA_OK || !ensure_scratch(fi.length)) return false;
    if (!read_exact(s_cur.fd, fi.offset, s_scratch, fi.length)) {
        ESP_LOGE(TAG, "read frame %u failed", idx);
        return false;
    }
    hca_status_t st = hca_decode_frame_from(&s_cur.asset.hdr, s_scratch, fi.length, display_fb(), DISPLAY_W);
    if (st != HCA_OK) {
        ESP_LOGE(TAG, "decode frame %u: %s", idx, hca_status_str(st));
        return false;
    }
    return true;
}

static uint32_t frame_ms(uint16_t idx) { return hca_frame_duration(&s_cur.asset, idx, FRAME_DEFAULT_MS); }

/* ------------------------------------------------------------------ scrolling strips */

/* Open strip `it` and put its first frame into the framebuffer (caller holds display_lock). With an
 * active scroll on the panel the whole strip is decoded once into PSRAM (strip_w x 240 x 2 bytes,
 * up to 3.9 MB) and every frame is composed from it; a strip without `scroll` (or the offscreen
 * render during a session) decodes just the 536 visible columns straight into the framebuffer. */
static void strip_compose(uint64_t travel);

static bool strip_begin(const pl_item_t *it)
{
    char path[96];
    storage_asset_path(it->id, path, sizeof path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    uint8_t t[HCA_HEADER_SIZE + HCA_FRAME_ENTRY_SIZE];
    hca_asset_t a;
    hca_frame_info_t fi;
    if (!read_exact(fd, 0, t, sizeof t) || hca_open(&a, t, sizeof t) != HCA_OK || hca_frame_info(&a, 0, &fi) != HCA_OK ||
        a.hdr.width < DISPLAY_W || a.hdr.height != DISPLAY_H) {
        ESP_LOGW(TAG, "strip %s: cannot open", it->id);
        close(fd);
        return false;
    }
    const uint16_t w = a.hdr.width;
    const bool scroll = it->scroll.on && s_output;
    const int64_t t0 = esp_timer_get_time();
    storage_status_t st;
    if (scroll) {
        const size_t need = (size_t)w * DISPLAY_H * 2u;
        size_t largest = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
        if (largest < need + STRIP_PSRAM_RESERVE) {
            /* Fragmented by the cached scene arena / reader font (both rebuilt on demand): drop them. */
            reader_font_unload();
#if PL_SCENES
            free(s_arena);
            s_arena = NULL;
            s_arena_cap = 0;
#endif
            largest = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
        }
        uint16_t *px = largest >= need + STRIP_PSRAM_RESERVE ? heap_caps_malloc(need, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT) : NULL;
        if (!px) {
            ESP_LOGE(TAG, "strip %s: needs %u B of PSRAM (+%u B reserve), largest free block %u B: skipped", it->id,
                     (unsigned)need, (unsigned)STRIP_PSRAM_RESERVE, (unsigned)largest);
            close(fd);
            return false;
        }
        st = storage_frame_stream(fd, fi.offset, fi.length, w, DISPLAY_H, a.hdr.compression, px, w, 0, w);
        if (st == STORAGE_OK) {
            s_cur.strip_px = px;
            s_cur.scrolling = true;
        } else {
            free(px);
        }
    } else {
        /* A still shows the first 536 px; the offscreen preview of a right-scrolling strip its last. */
        const uint16_t x0 = (it->scroll.on && it->scroll.right) ? (uint16_t)(w - DISPLAY_W) : 0;
        st = storage_frame_stream(fd, fi.offset, fi.length, w, DISPLAY_H, a.hdr.compression, display_fb(), DISPLAY_W, x0,
                                  DISPLAY_W);
    }
    close(fd);
    if (st != STORAGE_OK) {
        ESP_LOGE(TAG, "strip %s: decode failed (%s)", it->id, storage_status_str(st));
        return false;
    }
    s_cur.strip = true;
    s_cur.strip_w = w;
    s_cur.scroll_last_px = 0;
    if (s_cur.scrolling) strip_compose(0);   /* travel 0: the strip is still off-screen = black */
    ESP_LOGI(TAG, "strip %s: %ux%u %s, %s in %lld ms", it->id, w, DISPLAY_H,
             a.hdr.compression == HCA_COMP_RLE16 ? "RLE" : "raw", scroll ? "decoded to PSRAM" : "window decoded",
             (long long)((esp_timer_get_time() - t0) / 1000));
    return true;
}

typedef struct { int16_t x, n; int32_t src; } strip_seg_t;   /* src < 0: black */

/* Compose the 536-px window at `travel` px into the framebuffer (caller holds display_lock).
 *
 * The strip runs on a tape: copy k (k < loops, or endless) starts at k*(w+gap), black elsewhere.
 * "left": screen column c shows tape position travel - 536 + c, so at travel 0 the strip's first
 * column waits just off the right edge and the last copy has left on the left at
 * (loops-1)*(w+gap) + w + 536. "right" mirrors the motion (not the image): column c shows
 * r = travel - 1 - c on the mirrored tape and strip column w-1-(r mod (w+gap)). Each frame is at
 * most a handful of column segments, copied row by row with memcpy. */
static void strip_compose(uint64_t travel)
{
    const pl_scroll_t *sc = &s_cur.item.scroll;
    const int64_t w = s_cur.strip_w, period = w + sc->gap_px;
    const int64_t loops = s_cur.scroll_end_px ? sc->loops : INT64_MAX / 2;
    const int64_t d = (int64_t)travel;
    strip_seg_t seg[STRIP_MAX_SEGS];
    int ns = 0;
    int64_t c = 0;
    while (c < DISPLAY_W && ns < STRIP_MAX_SEGS - 1) {
        const int64_t rem = DISPLAY_W - c;
        int64_t run, src = -1;
        if (!sc->right) {
            const int64_t t = d - DISPLAY_W + c;
            if (t < 0) {
                run = -t;
            } else if (t / period >= loops) {
                run = rem;
            } else if (t % period < w) {
                src = t % period;
                run = w - src;
            } else {
                run = period - t % period;
            }
        } else {
            const int64_t r = d - 1 - c;
            if (r < 0) {
                run = rem;
            } else if (r / period >= loops) {
                run = r - loops * period + 1;
            } else if (r % period < w) {
                src = w - 1 - r % period;
                run = r % period + 1;
            } else {
                run = r % period - w + 1;
            }
        }
        if (run > rem) run = rem;
        if (ns > 0 && src < 0 && seg[ns - 1].src < 0) {
            seg[ns - 1].n += (int16_t)run;   /* merge adjacent black */
        } else {
            seg[ns++] = (strip_seg_t){ .x = (int16_t)c, .n = (int16_t)run, .src = (int32_t)src };
        }
        c += run;
    }
    if (c < DISPLAY_W) seg[ns++] = (strip_seg_t){ .x = (int16_t)c, .n = (int16_t)(DISPLAY_W - c), .src = -1 };
    uint16_t *dst = display_fb();
    const uint16_t *row = s_cur.strip_px;
    for (int y = 0; y < DISPLAY_H; y++, dst += DISPLAY_W, row += w) {
        for (int i = 0; i < ns; i++) {
            if (seg[i].src >= 0) {
                memcpy(dst + seg[i].x, row + seg[i].src, (size_t)seg[i].n * 2u);
            } else {
                memset(dst + seg[i].x, 0, (size_t)seg[i].n * 2u);
            }
        }
    }
    s_cur.scroll_last_px = travel;
}

/* esp_timer time at which the travel reaches `px` (exact speed: travel is derived from the elapsed
 * time, never accumulated per frame, so 30 fps jitter cannot drift it). */
static int64_t strip_time_of(uint64_t px)
{
    const uint64_t mpx = s_cur.item.scroll.mpx_per_s;
    return s_cur.scroll_t0_us + (int64_t)((px * 1000000000ULL + mpx - 1) / mpx);
}

static void strip_frame(void)
{
    const int64_t t0 = esp_timer_get_time();
    uint64_t travel = (uint64_t)(t0 - s_cur.scroll_t0_us) * s_cur.item.scroll.mpx_per_s / 1000000000ULL;
    if (s_cur.scroll_end_px && travel > s_cur.scroll_end_px) travel = s_cur.scroll_end_px;
    if (travel != s_cur.scroll_last_px) {
        display_lock();
        strip_compose(travel);
        const int64_t t1 = esp_timer_get_time();
        esp_err_t err = display_flush_full();
        display_unlock();
        if (err != ESP_OK) ESP_LOGE(TAG, "strip flush: %s", esp_err_to_name(err));
        const int64_t t2 = esp_timer_get_time();
        s_st.frames++;
        s_st.compose_us += (uint64_t)(t1 - t0);
        s_st.flush_us += (uint64_t)(t2 - t1);
    }
    const int64_t now = esp_timer_get_time();
    if (now - s_st.stat_t0 >= STRIP_STATS_US) {
        if (s_st.frames) {
            const uint32_t n = s_st.frames;
            ESP_LOGI("strip", "%s: %.1f fps at %.1f px/s, compose %llu us, flush %llu us (avg of %lu)", s_cur.item.id,
                     (double)n * 1e6 / (double)(now - s_st.stat_t0), (double)s_cur.item.scroll.mpx_per_s / 1000.0,
                     (unsigned long long)(s_st.compose_us / n), (unsigned long long)(s_st.flush_us / n), (unsigned long)n);
        }
        s_st.stat_t0 = now;
        s_st.frames = 0;
        s_st.compose_us = s_st.flush_us = 0;
    }
    /* Next frame: 30 fps, but not before the travel advances by a pixel (slow scrolls flush less). */
    int64_t next = s_cur.next_frame_us + STRIP_FRAME_US;
    const int64_t px_due = strip_time_of(s_cur.scroll_last_px + 1);
    if (next < px_due) next = px_due;
    if (next < now + SCENE_MIN_GAP_US) next = now + SCENE_MIN_GAP_US;
    s_cur.next_frame_us = next;
}

/* ------------------------------------------------------------------ live scenes */

/* PROTOCOL §4 "Orientation": the panel follows the decided orientation except while a live scene is showing.
 * Scenes already answer to real gravity (sand falls to the floor whichever way the clip is worn), so turning
 * them over would only make the simulation chase a mirrored vector; they are drawn upright with the true
 * gravity, and the decided orientation returns with the next item. Player task only (holds the display lock
 * inside display_set_flipped; a no-op when nothing changes). */
static void orient_sync(void)
{
#if PL_SCENES
    /* §5b.1: `words` follows the orientation like a picture (text must read upright) */
    const bool exempt = s_cur.kind == CUR_SCENE && !scene_follows_orientation((scene_kind_t)s_scene.kind);
#else
    const bool exempt = s_cur.kind == CUR_SCENE;
#endif
    const bool want = orient_flipped() && !exempt;
    if (want != display_is_flipped()) {
        if (!want && orient_flipped()) ESP_LOGI(TAG, "orientation: scene shown upright (flip resumes after it)");
        orient_apply(want);
    }
}

#if PL_SCENES
/* Display-frame gravity (g): IMU if present, else straight down (upright clip). */
static void scene_gravity(float *gx, float *gy, float *gz)
{
    imu_get_gravity(gx, gy, gz);
    /* PROTOCOL §4 "Orientation": the panel shows the framebuffer turned 180° about z, so the scene gets
     * gravity in the framebuffer's frame: (-gx, -gy, gz). Sand still falls to the floor. Same task as
     * CMD_ORIENT, so this always matches the picture on the panel. §5b.1 `words` follows the decided orientation
     * (the panel flips with it), also for its very first sample, taken before the panel is turned. */
    const bool flipped = scene_follows_orientation((scene_kind_t)s_scene.kind) && s_scene.ready ? orient_flipped()
                                                                                                : display_is_flipped();
    if (flipped) {
        float g[3] = { *gx, *gy, *gz };
        scene_gravity_flipped(g);
        *gx = g[0];
        *gy = g[1];
    }
}

/* Resources held only while a scene is visible: max CPU and the 50 Hz IMU sampling. */
static void scene_hold(bool on)
{
    if (on && !s_sc.perf) power_perf_acquire(POWER_PERF_SCENE);
    if (!on && s_sc.perf) power_perf_release(POWER_PERF_SCENE);
    if (on && !s_sc.imu) imu_acquire();
    if (!on && s_sc.imu) imu_release();
    s_sc.perf = s_sc.imu = on;
}

static void scene_release(void) { scene_hold(false); }

/* The item ends: the words' sprites go back (the arena is kept for the next scene). */
static void scene_close(void)
{
    scene_hold(false);
    free(s_sc.sprites);
    s_sc.sprites = NULL;
    s_sc.sprites_bytes = 0;
}

/* §5b.1 the sheet of a words item: every frame decoded into PSRAM (N*w*h*2 B, at most ~1 MB) and handed to the scene.
 * Needs the sprites plus 512 KB of headroom in the largest free PSRAM block. False: the item does not start. */
#define WORDS_PSRAM_SPARE (512u * 1024u)
static bool words_load(const pl_item_t *it)
{
    const int64_t t0 = esp_timer_get_time();
    free(s_sc.sprites);
    s_sc.sprites = NULL;
    s_sc.sprites_bytes = 0;
    size_t sz = 0;
    uint8_t *file = load_whole(it->sheet, &sz);
    hca_asset_t a;
    if (!file || hca_open(&a, file, sz) != HCA_OK) {
        ESP_LOGW(TAG, "scene words: sheet %s missing or unreadable", it->sheet);
        free(file);
        return false;
    }
    const uint16_t w = a.hdr.width, h = a.hdr.height;
    const uint32_t n = a.hdr.frame_count;
    if (n < 1 || n > SCENE_WORDS_MAX || w > SCENE_WORDS_MAX_W || h > SCENE_WORDS_MAX_H ||
        (uint64_t)n * w * h > SCENE_WORDS_MAX_PX) {
        ESP_LOGW(TAG, "scene words: sheet %s is %ux%u x %lu frames (limits 536x240, 1..12, %u px)", it->sheet, w, h,
                 (unsigned long)n, (unsigned)SCENE_WORDS_MAX_PX);
        free(file);
        return false;
    }
    const size_t bytes = (size_t)n * w * h * 2u, largest = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
    if (largest < bytes + WORDS_PSRAM_SPARE) {
        ESP_LOGW(TAG, "scene words: sheet %s needs %u B of sprites (+%u B kept free), largest PSRAM block %u B",
                 it->sheet, (unsigned)bytes, (unsigned)WORDS_PSRAM_SPARE, (unsigned)largest);
        free(file);
        return false;
    }
    s_sc.sprites = heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_sc.sprites) {
        free(file);
        return false;
    }
    const uint16_t *frames[SCENE_WORDS_MAX];
    bool ok = true;
    for (uint32_t f = 0; f < n && ok; f++) {
        uint16_t *dst = s_sc.sprites + (size_t)f * w * h;
        frames[f] = dst;
        ok = hca_decode_frame(&a, (uint16_t)f, dst, w) == HCA_OK;
    }
    free(file);
    const int words = ok ? scene_words_set_sprites(&s_scene, frames, (int)n, w, h) : -1;
    if (words < 0) {
        ESP_LOGW(TAG, "scene words: sheet %s could not be decoded", it->sheet);
        free(s_sc.sprites);
        s_sc.sprites = NULL;
        return false;
    }
    s_sc.sprites_bytes = bytes;
    ESP_LOGI(TAG, "scene words: sheet %s: %lu frames %ux%u, %d words%s, sprites %u B in PSRAM, decoded in %lld ms "
             "(largest block now %u B)", it->sheet, (unsigned long)n, w, h, words,
             words ? "" : " (every frame is black: a black screen)", (unsigned)bytes,
             (long long)((esp_timer_get_time() - t0) / 1000), (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
    return true;
}

/* Initialise the scene of `it` and render its first frame into the framebuffer (caller holds
 * display_lock and flushes). Offscreen (output disabled) it simulates a short warm-up first. */
static bool scene_begin(const pl_item_t *it)
{
    const scene_info_t *si = scene_find(it->id);
    if (!si) return false;
    const size_t need = scene_arena_bytes(si->kind, DISPLAY_W, DISPLAY_H);
    if (need == 0) return false;
    if (need > s_arena_cap) {
        /* Worst case over all parameters (< 140 KB); kept for the next scene (no fragmentation). */
        free(s_arena);
        s_arena = heap_caps_malloc(need, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        s_arena_cap = s_arena ? need : 0;
        if (!s_arena) {
            ESP_LOGE(TAG, "scene %s: no PSRAM for a %u B arena", it->id, (unsigned)need);
            return false;
        }
    }
    const uint32_t seed = it->has_seed ? it->seed : esp_random();
    scene_status_t st = scene_init(&s_scene, si->kind, &it->params, DISPLAY_W, DISPLAY_H, seed, s_arena, s_arena_cap);
    if (st != SCENE_OK) {
        ESP_LOGE(TAG, "scene %s: init failed (%d)", it->id, (int)st);
        return false;
    }
    if (si->kind == SCENE_WORDS && !words_load(it)) {
        s_scene.ready = 0;
        return false;
    }
    float gx, gy, gz;
    scene_gravity(&gx, &gy, &gz);
    if (!s_output) {
        for (int i = 0; i < SCENE_WARMUP; i++) scene_step(&s_scene, gx, gy, gz, SCENE_FRAME_US / 1e6f);
    } else {
        scene_step(&s_scene, gx, gy, gz, 0.0f);
    }
    scene_render(&s_scene, display_fb(), DISPLAY_W, DISPLAY_H, NULL);
    s_sc.invalidate = false;   /* the first render after init is always full */
    s_sc.last_step_us = esp_timer_get_time();
    s_sc.stat_t0 = s_sc.last_step_us;
    s_sc.frames = 0;
    s_sc.step_us = s_sc.render_us = s_sc.flush_us = 0;
    ESP_LOGI(TAG, "scene %s: arena %u B (exact %u B), seed %08lx%s, imu %s", it->id, (unsigned)need,
             (unsigned)scene_arena_bytes_for(si->kind, &it->params, DISPLAY_W, DISPLAY_H), (unsigned long)seed,
             it->has_seed ? " (fixed)" : "", imu_present() ? "yes" : "no (fixed gravity)");
    return true;
}

static void scene_frame(void)
{
    const int64_t t0 = esp_timer_get_time();
    float dt = (float)(t0 - s_sc.last_step_us) / 1e6f;
    if (dt < 0.0f) dt = 0.0f;
    if (dt > 0.05f) dt = 0.05f;
    s_sc.last_step_us = t0;
    float gx, gy, gz;
    scene_gravity(&gx, &gy, &gz);
    scene_step(&s_scene, gx, gy, gz, dt);
    const int64_t t1 = esp_timer_get_time();
    scene_rect_t d = { 0 };
    display_lock();
    if (s_sc.invalidate) {
        scene_invalidate(&s_scene);
        s_sc.invalidate = false;
    }
    scene_render(&s_scene, display_fb(), DISPLAY_W, DISPLAY_H, &d);
    const int64_t t2 = esp_timer_get_time();
    if (d.w > 0 && d.h > 0) {
        esp_err_t err = display_flush_rect(d.x, d.y, d.w, d.h);
        if (err != ESP_OK) ESP_LOGE(TAG, "scene flush: %s", esp_err_to_name(err));
    }
    display_unlock();
    const int64_t t3 = esp_timer_get_time();
    s_sc.frames++;
    s_sc.step_us += (uint64_t)(t1 - t0);
    s_sc.render_us += (uint64_t)(t2 - t1);
    s_sc.flush_us += (uint64_t)(t3 - t2);
    if (t3 - s_sc.stat_t0 >= SCENE_STATS_US && s_sc.frames) {
        const uint32_t n = s_sc.frames;
        ESP_LOGI("scene", "%s: %.1f fps, step %llu us, render %llu us, flush %llu us (avg of %lu)", s_cur.item.id,
                 (double)n * 1e6 / (double)(t3 - s_sc.stat_t0), (unsigned long long)(s_sc.step_us / n),
                 (unsigned long long)(s_sc.render_us / n), (unsigned long long)(s_sc.flush_us / n), (unsigned long)n);
        {   /* RTC breadcrumb: was the scene still stepping and flushing when the run ended? */
            char note[96];
            snprintf(note, sizeof note, "scene %s %lu frames/5s flush=%lluus out=%d flip=%d imu=%d usb=%d",
                     s_cur.item.id, (unsigned long)n, (unsigned long long)(s_sc.flush_us / n), s_output,
                     display_is_flipped(), s_sc.imu, !power_on_battery());
            health_item_note(note);
        }
        s_sc.stat_t0 = t3;
        s_sc.frames = 0;
        s_sc.step_us = s_sc.render_us = s_sc.flush_us = 0;
    }
    s_cur.next_frame_us += s_uploads_rx > 0 ? SCENE_FRAME_UPLOAD_US : SCENE_FRAME_US;
    if (s_cur.next_frame_us < t3 + SCENE_MIN_GAP_US) s_cur.next_frame_us = t3 + SCENE_MIN_GAP_US;
}
#else
static void scene_release(void) {}
static void scene_close(void) {}
#endif

/* POST /show/{id} without a body: an asset that a playlist (then queue) oracle item uses as its bundle, or a words scene
 * as its sheet (§5b.1), is shown as that item. */
static bool borrows(const pl_item_t *p, const char *id)
{
    if (p->type == PL_ITEM_ORACLE || p->type == PL_ITEM_BOARD) return strcmp(p->id, id) == 0;   /* bundle / §5g sheet */
    return p->type == PL_ITEM_SCENE && p->sheet[0] && strcmp(p->sheet, id) == 0;   /* §5b.1: a words item's sheet */
}

static void show_item_borrow(pl_item_t *it)
{
    const pl_item_t *src = NULL;
    for (size_t i = 0; i < s_pl->count && !src; i++) {
        if (borrows(&s_pl->items[i], it->id)) src = &s_pl->items[i];
    }
    for (size_t i = 0; i < s_pl->queue_count && !src; i++) {
        if (borrows(&s_pl->queue[i].item, it->id)) src = &s_pl->queue[i].item;
    }
    if (!src) return;
    if (src->type == PL_ITEM_BOARD) {   /* §5g the sheet shown as the board that uses it */
        it->type = PL_ITEM_BOARD;
        it->board = src->board;
        ESP_LOGI(TAG, "show %s: as the board of its %s", it->id,
                 src >= s_pl->items && src < s_pl->items + s_pl->count ? "playlist item" : "queue entry");
        return;
    }
    if (src->type == PL_ITEM_SCENE) {   /* the sheet shown as the words scene that uses it */
        it->type = PL_ITEM_SCENE;
        strlcpy(it->sheet, src->sheet, sizeof it->sheet);
        strlcpy(it->id, src->id, sizeof it->id);
#if PL_SCENES
        it->params = src->params;
#endif
        it->has_seed = src->has_seed;
        it->seed = src->seed;
        ESP_LOGI(TAG, "show %s: as the words scene of its %s", it->sheet,
                 src >= s_pl->items && src < s_pl->items + s_pl->count ? "playlist item" : "queue entry");
        return;
    }
    it->type = src->type;
    it->orc = src->orc;
    ESP_LOGI(TAG, "show %s: as the oracle of its %s", it->id,
             src >= s_pl->items && src < s_pl->items + s_pl->count ? "playlist item" : "queue entry");
}

/* ------------------------------------------------------------------ Oracle (PROTOCOL §5f) */

/* Four assets (text T 536x240, deck D 108x206, keys K 160x34, notes N 536x72; the last three are glyph atlases). Their
 * headers + frame tables stay in PSRAM while the item runs; frames are streamed from the files on demand
 * (storage_frame_stream, 4 KB read buffer) straight into the framebuffer at the op's position: nothing is preloaded and
 * no decoded frame is cached besides the framebuffer itself. core/oracle.h describes every screen as paste ops; between
 * two draws with the same ground only the ops that changed are repainted and flushed (a shuffle frame = one or three
 * card slots, 108x206 each); any other change repaints the whole screen (a text frame or black, then the ops) with one
 * full flush. Files are opened for a paint and closed after it, except during a shuffle (12 fps). The state machine is
 * stepped every OR_POLL_US on ARMED while the IMU samples (50 Hz, while visible; §5f.8: a shake deals only there), at
 * the shuffle's 12 fps, and at its timers; without an IMU only presses, POST /oracle/draw|turn and the timers move it. Holds: the ORACLE perf owner during a
 * shuffle only. */
static void or_imu(bool on)
{
    if (on && !s_or.imu) imu_acquire();
    if (!on && s_or.imu) imu_release();
    s_or.imu = on;
}

static void or_perf(bool on)
{
    if (on && !s_or.perf) power_perf_acquire(POWER_PERF_ORACLE);
    if (!on && s_or.perf) power_perf_release(POWER_PERF_ORACLE);
    s_or.perf = on;
}

static void or_release(void)
{
    or_perf(false);
    or_imu(false);
}

static void or_close_files(void)
{
    for (int i = 0; i < OR_ASSETS; i++) {
        if (s_or.f[i].fd >= 0) close(s_or.f[i].fd);
        s_or.f[i].fd = -1;
    }
}

/* ---- the deck cache: the deck file (compressed frames) in PSRAM while the item shows, so that a shuffle frame costs
 * the decode and the slot flush only (no flash reads). Attempted once per item at its first step; skipped (frames
 * streamed from the file as before) when PSRAM is short. Released with the item (or_unload). */
static void or_deck_cache(void)
{
    s_or.deck_tried = true;
    const char *id = s_or.ids[OR_ASSET_DECK];
    asset_info_t info;
    if (!id[0] || !storage_asset_find(id, &info) || !s_or.f[OR_ASSET_DECK].table) return;
    const size_t largest = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if ((size_t)info.size + OR_DECK_PSRAM_RESERVE > largest) {
        ESP_LOGW(TAG, "oracle %s: deck %s not cached (%u B, largest PSRAM block %u B, %u B kept free): frames streamed",
                 s_cur.item.id, id, (unsigned)info.size, (unsigned)largest, (unsigned)OR_DECK_PSRAM_RESERVE);
        return;
    }
    const int64_t t0 = esp_timer_get_time();
    uint8_t *mem = heap_caps_malloc(info.size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    char path[96];
    storage_asset_path(id, path, sizeof path);
    const int fd = mem ? open(path, O_RDONLY) : -1;
    bool ok = fd >= 0;
    for (uint32_t off = 0; ok && off < info.size;) {   /* 64 KB at a time, yielding in between */
        const uint32_t n = info.size - off < 65536u ? info.size - off : 65536u;
        ok = read_exact(fd, off, mem + off, n);
        off += n;
        vTaskDelay(1);
    }
    if (fd >= 0) close(fd);
    /* the same deck as the one or_file_load saw: an upload may have replaced the file since (its reload is still in
     * the queue), and or_paint_op checks an op against the table's geometry */
    const hca_header_t *th = &s_or.f[OR_ASSET_DECK].a.hdr;
    ok = ok && hca_open(&s_or.deck_full, mem, info.size) == HCA_OK && s_or.deck_full.hdr.frame_count == th->frame_count &&
         s_or.deck_full.hdr.width == th->width && s_or.deck_full.hdr.height == th->height;
    if (!ok) {
        ESP_LOGW(TAG, "oracle %s: deck %s could not be cached: frames streamed", s_cur.item.id, id);
        free(mem);
        memset(&s_or.deck_full, 0, sizeof s_or.deck_full);
        return;
    }
    s_or.deck_mem = mem;
    ESP_LOGI(TAG, "oracle %s: deck %s cached in PSRAM: %u B, %u frames, in %lld ms (largest block now %u B)", s_cur.item.id,
             id, (unsigned)info.size, s_or.deck_full.hdr.frame_count, (long long)((esp_timer_get_time() - t0) / 1000),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
}

/* ---- the reader bundle (PROTOCOL §5f.1, §5f.7): parsed with core oracle_reader.h into a PSRAM arena at the item's
 * start, with its font; every text screen is drawn from it (oracle_text.h), and each draw's lean screens and paragraph
 * are composed once, when the draw first reaches its three cards. */
static void orr_unload(void)
{
    free(s_orr.text);
    free(s_orr.arena);
    s_orr.text = NULL;
    s_orr.arena = NULL;
    s_orr.b = NULL;
    s_orr.text_len = 0;
    s_orr.text_id[0] = '\0';
    fontc_unload(&s_orr.fc);
    fontc_unload(&s_orr.fcb);
    free(s_orr.tlay);
    free(s_orr.tscratch);
    s_orr.tlay = NULL;
    s_orr.tscratch = NULL;
    s_orr.tscratch_px = 0;
    s_orr.active = false;
    s_orr.para[0] = '\0';
}

/* The item's bundle + font into PSRAM (kept while the item shows and the ids stay the same). */
static bool orr_load(void)
{
    const pl_oracle_t *c = &s_or.cfg;
    if (!c->reader[0] || !c->font[0]) return false;
    if (!reader_text_exists(c->reader) || !reader_font_exists(c->font)) {
        ESP_LOGW(TAG, "oracle %s: reader bundle %s or font %s missing: no paragraph", s_cur.item.id, c->reader, c->font);
        return false;
    }
    if (!s_orr.b || strcmp(s_orr.text_id, c->reader) != 0) {
        const int64_t t0 = esp_timer_get_time();
        free(s_orr.text);
        free(s_orr.arena);
        s_orr.text = NULL;
        s_orr.arena = NULL;
        s_orr.b = NULL;
        s_orr.text_id[0] = '\0';
        reader_text_info_t info;
        if (!reader_text_info(c->reader, &info) || info.bytes == 0 || info.bytes > ORR_BUNDLE_MAX) {
            ESP_LOGW(TAG, "oracle %s: reader bundle %s unusable (%u B, max %u): no paragraph", s_cur.item.id, c->reader,
                     (unsigned)info.bytes, (unsigned)ORR_BUNDLE_MAX);
            return false;
        }
        char path[96];
        reader_text_path(c->reader, path, sizeof path);
        s_orr.text = heap_caps_malloc(info.bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        const int fd = s_orr.text ? open(path, O_RDONLY) : -1;
        bool ok = fd >= 0 && read_exact(fd, 0, s_orr.text, info.bytes);
        if (fd >= 0) close(fd);
        size_t need = 0;
        if (ok) {
            need = orr_arena_bytes(s_orr.text, info.bytes);
            s_orr.arena = heap_caps_malloc(need, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            s_orr.b = s_orr.arena ? orr_parse(s_orr.text, info.bytes, s_orr.arena, need) : NULL;
            ok = s_orr.b != NULL;
        }
        if (!ok) {
            ESP_LOGW(TAG, "oracle %s: reader bundle %s could not be loaded: no paragraph", s_cur.item.id, c->reader);
            free(s_orr.text);
            free(s_orr.arena);
            s_orr.text = NULL;
            s_orr.arena = NULL;
            s_orr.b = NULL;
            return false;
        }
        s_orr.text_len = info.bytes;
        strlcpy(s_orr.text_id, c->reader, sizeof s_orr.text_id);
        ESP_LOGI(TAG, "oracle %s: reader bundle %s: %u B, %d cards, arena %u B (PSRAM), in %lld ms", s_cur.item.id,
                 c->reader, (unsigned)info.bytes, orr_cards(s_orr.b), (unsigned)need,
                 (long long)((esp_timer_get_time() - t0) / 1000));
    }
    s_orr.fc.want_large = true;   /* §5f.11 */
    if (!fontc_load(&s_orr.fc, c->font, "oracle")) return false;
    /* §5f.11 the large and compact views (plain copies of the font with that face as normal), PSRAM */
    if (!s_orr.lview) s_orr.lview = heap_caps_malloc(sizeof *s_orr.lview, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_orr.cview) s_orr.cview = heap_caps_malloc(sizeof *s_orr.cview, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_orr.lview || !s_orr.cview) return false;
    s_orr.lview_ok = ot_font_large_view(s_orr.fc.font, s_orr.lview);
    s_orr.cview_ok = ot_font_compact_view(s_orr.fc.font, s_orr.cview);
    if (c->font_big[0] && !fontc_load(&s_orr.fcb, c->font_big, "oracle numeral")) {
        ESP_LOGW(TAG, "oracle %s: font_big %s unusable: the numeral uses the body font", s_cur.item.id, c->font_big);
    }
    if (!s_orr.tlay) s_orr.tlay = heap_caps_malloc(sizeof *s_orr.tlay, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    const size_t px = s_orr.fc.scratch_px > s_orr.fcb.scratch_px ? s_orr.fc.scratch_px : s_orr.fcb.scratch_px;
    if (s_orr.tscratch_px < px) {
        free(s_orr.tscratch);
        s_orr.tscratch = heap_caps_malloc(px * 2, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        if (!s_orr.tscratch) s_orr.tscratch = heap_caps_malloc(px * 2, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        s_orr.tscratch_px = s_orr.tscratch ? px : 0;
    }
    return s_orr.tlay && s_orr.tscratch;
}

static ot_fonts_t orr_fonts(void)
{
    return (ot_fonts_t){ .body = s_orr.fc.font, .big = s_orr.fcb.font, .scratch = s_orr.tscratch,
                         .scratch_px = s_orr.tscratch_px, .work = s_orr.tlay };
}

/* A text screen (§5f.2): the TEXT op's frame (or_text_screen) drawn on black from the bundle: the waits or armed prompt
 * (§5f.8), a lean screen or a card's brief (§5f.7). Caller holds display_lock. */
/* §5f.11 the faces from the largest down: large (when the font has one), normal, compact (when it has one). */
static int orr_faces(const rsvp_font_t *out[3])
{
    int n = 0;
    if (s_orr.lview_ok) out[n++] = s_orr.lview;
    out[n++] = s_orr.fc.font;
    if (s_orr.cview_ok) out[n++] = s_orr.cview;
    return n;
}

/* §5f.11 draw text in a box in the largest face that fits it on one page (else the smallest, cut). */
static int orr_draw_fit(const char *text, size_t len, int x0, int x1)
{
    const ot_fonts_t f = orr_fonts();
    const rsvp_font_t *faces[3];
    const int n = orr_faces(faces);
    const bool fl = s_or.o.flipped;
    const int y0 = ot_text_y0(fl), y1 = y0 + OT_BOX_H;
    const int k = ot_box_pick(&f, faces, n, text, len, x0, x1, y0, y1);
    const rsvp_font_t *font = faces[k >= 0 ? k : n - 1];
    s_orr.faces[k < 0 ? 3 : font == s_orr.lview ? 0 : font == s_orr.cview ? 2 : 1]++;
    return ot_draw_box(&f, font, text, len, x0, x1, y0, y1, display_fb(), NULL);
}

/* A text screen: the TEXT op's frame (or_text_screen) drawn on black from the bundle (§5f.2), in the boxes of §5f.11 —
 * the prompts beside the back, the lean screens at full width, a brief beside its card (or at full width when it does
 * not fit there even in the compact face: cfg.card_beside) — each in the largest face that fits. The card is the next
 * op's paste. Caller holds display_lock. */
static bool or_paint_text(uint16_t frame)
{
    if (!s_orr.b || !s_orr.fc.font) return false;
    const int64_t t0 = esp_timer_get_time();
    const bool fl = s_or.o.flipped;
    const int bx0 = fl ? OT_BESIDE_X0_FLIP : OT_BESIDE_X0_UP, bx1 = fl ? OT_BESIDE_X1_FLIP : OT_BESIDE_X1_UP;
    uint16_t card;
    int r;
    size_t l1;
    switch (or_text_screen(frame, &card)) {
    case OR_TEXT_LEAN:   /* §5f.7: a lean screen, full width */
        r = card < OR_LEAN_SCREENS ? orr_draw_fit(s_orr.lean[card], strlen(s_orr.lean[card]), OT_FULL_X0, OT_FULL_X1) : -1;
        break;
    case OR_TEXT_DETAIL: {   /* §5f.10: the card's brief beside it (or alone) */
        const char *br = orr_card_field(s_orr.b, card, ORR_F_BRIEF, &l1);
        const bool beside = card < OR_MAX_CARDS && s_or.o.cfg.card_beside[card];
        r = orr_draw_fit(br, l1, beside ? bx0 : OT_FULL_X0, beside ? bx1 : OT_FULL_X1);
        break;
    }
    case OR_TEXT_ARMED: {   /* §5f.8: "Shake the deck." ([prompt] when the bundle has no [prompt.armed]) */
        const char *pr = orr_prompt_armed(s_orr.b, &l1);
        r = orr_draw_fit(pr, l1, bx0, bx1);
        break;
    }
    default: {
        const char *pr = orr_prompt(s_orr.b, &l1);
        r = orr_draw_fit(pr, l1, bx0, bx1);
        break;
    }
    }
    const uint32_t us = (uint32_t)(esp_timer_get_time() - t0);
    s_orr.text_paints++;
    s_orr.text_us += us;
    if (us > s_orr.text_max_us) s_orr.text_max_us = us;
    if (r) ESP_LOGW(TAG, "oracle %s: text screen %u: %s", s_cur.item.id, frame, r < 0 ? "bad arguments" : "glyphs failed");
    return r >= 0;
}

/* §5f.7 the cards with a detail screen (a card.<i>.brief line) into the core config. */
static void orr_card_details(or_config_t *c)
{
    int n = 0, beside = 0;
    const ot_fonts_t f = orr_fonts();
    const rsvp_font_t *faces[3];
    const int nf = orr_faces(faces);
    for (int i = 0; i < c->cards && i < OR_MAX_CARDS; i++) {
        size_t l;
        const char *br = orr_card_field(s_orr.b, i, ORR_F_BRIEF, &l);
        c->card_detail[i] = l > 0;
        /* §5f.10 / §5f.11: the card beside its brief when the brief fits the box there in some face (the box has the
         * same size in both orientations) */
        c->card_beside[i] = l > 0 && ot_box_pick(&f, faces, nf, br, l, OT_BESIDE_X0_UP, OT_BESIDE_X1_UP, 0, OT_BOX_H) >= 0;
        n += l > 0;
        beside += c->card_beside[i];
    }
    ESP_LOGI(TAG, "oracle %s: %d of %u cards have a detail (brief) screen, %d of them beside the card", s_cur.item.id, n,
             c->cards, beside);
}

/* The "and" screen's page test (§5f.7): the text is one page in the full-width box (§5f.11) in the body font's normal
 * face (the screen itself may then use the large face when it fits that too). */
static bool orr_fits(void *ctx, const char *text, size_t len)
{
    (void)ctx;
    ot_fonts_t f = orr_fonts();
    return ot_lean_fits(&f, text, len);   /* core: the normal face, 520 x 224, both orientations (§5f.11) */
}

/* A draw reached THREE for the first time: compose its lean screens (by card, by position, by the numbers, together,
 * and; "and" page-tested with the body font) and its paragraph (for /status.oracle.reading; no screen since §5f.7), and
 * tell the core which lean screens have text. */
static void orr_compose_draw(void)
{
    or_t *o = &s_or.o;
    s_orr.active = false;
    s_orr.para_draw = o->draws;
    s_orr.para[0] = '\0';
    bool have[OR_LEAN_SCREENS] = { false };
    char *const out[ORR_LEAN_SCREENS] = { s_orr.lean[0], s_orr.lean[1], s_orr.lean[2], s_orr.lean[3], s_orr.lean[4] };
    const size_t caps[ORR_LEAN_SCREENS] = { sizeof s_orr.lean[0], sizeof s_orr.lean[1], sizeof s_orr.lean[2],
                                            sizeof s_orr.lean[3], sizeof s_orr.lean[4] };
    for (int k = 0; k < OR_LEAN_SCREENS; k++) s_orr.lean[k][0] = '\0';
    if (s_orr.b && s_orr.fc.font) {
        const int64_t t0 = esp_timer_get_time();
        const int n = orr_compose(s_orr.b, -1, o->three[0], o->three[1], o->three[2], s_orr.para, sizeof s_orr.para);
        s_orr.active = n > 0;
        if (n <= 0) s_orr.para[0] = '\0';
        char sec[200];
        orr_sections(s_orr.b, sec, sizeof sec);
        const int m = orr_compose_lean(s_orr.b, o->three[0], o->three[1], o->three[2], out, caps, orr_fits, NULL);
        const ot_fonts_t f = orr_fonts();
        int over = 0;
        const rsvp_font_t *faces[3];
        const int nf = orr_faces(faces);
        for (int k = 0; k < OR_LEAN_SCREENS && m == ORR_LEAN_SCREENS; k++) {
            have[k] = s_orr.lean[k][0] != '\0';
            if (have[k] && ot_box_pick(&f, faces, nf, s_orr.lean[k], strlen(s_orr.lean[k]), OT_FULL_X0, OT_FULL_X1, 0,
                                       OT_BOX_H) < 0) {
                over++;
            }
        }
        ESP_LOGI(TAG, "oracle %s: %d %d %d: lean %d%d%d%d%d (%u/%u/%u/%u/%u B)%s, paragraph %d B (%s), in %lld us",
                 s_cur.item.id, o->three[0], o->three[1], o->three[2], have[0], have[1], have[2], have[3], have[4],
                 (unsigned)strlen(s_orr.lean[0]), (unsigned)strlen(s_orr.lean[1]), (unsigned)strlen(s_orr.lean[2]),
                 (unsigned)strlen(s_orr.lean[3]), (unsigned)strlen(s_orr.lean[4]),
                 over ? " (some longer than a page even in compact: cut)" : "", n, sec, (long long)(esp_timer_get_time() - t0));
    }
    or_lean_screens(o, have);
}


static void or_unload(void)
{
    or_close_files();
    for (int i = 0; i < OR_ASSETS; i++) {
        free(s_or.f[i].table);
        s_or.f[i].table = NULL;
        memset(&s_or.f[i].a, 0, sizeof s_or.f[i].a);
    }
    free(s_or.deck_mem);
    s_or.deck_mem = NULL;
    memset(&s_or.deck_full, 0, sizeof s_or.deck_full);
    s_or.deck_tried = false;
    orr_unload();
}

static void publish_oracle(void)
{
    static player_oracle_status_t st;   /* player task only; ~1 KB with the text, off the stack */
    memset(&st, 0, sizeof st);
    st.drawn[0] = st.drawn[1] = st.drawn[2] = -1;
    st.card = -1;
    st.page = -1;
    strlcpy(st.state, "waits", sizeof st.state);
    if (s_cur.kind == CUR_ORACLE) {
        const or_t *o = &s_or.o;
        st.active = true;
        strlcpy(st.id, s_cur.item.id, sizeof st.id);
        st.cards = o->cfg.cards;
        strlcpy(st.state, or_state_str(o), sizeof st.state);
        int t[3];
        or_status_three(o, t);
        for (int i = 0; i < 3; i++) st.drawn[i] = (int16_t)t[i];
        st.card = (int16_t)or_status_card(o);
        st.page = (int8_t)or_status_page(o);
        const bool composed = s_orr.para_draw == o->draws;
        if (o->phase == OR_LEAN && composed && o->screen >= 0 && o->screen < OR_LEAN_SCREENS) {
            strlcpy(st.reading, s_orr.lean[o->screen], sizeof st.reading);   /* §5f.7: that screen's text */
        } else if (o->phase == OR_DETAIL && o->screen >= 0 && o->screen < 3) {
            size_t l;
            const char *br = orr_card_field(s_orr.b, o->three[o->screen], ORR_F_BRIEF, &l);
            if (l >= sizeof st.reading) l = sizeof st.reading - 1;
            memcpy(st.reading, br, l);
            st.reading[l] = '\0';
        } else if ((o->phase == OR_THREE || o->phase == OR_HOLD) && composed && s_orr.active) {
            strlcpy(st.reading, s_orr.para, sizeof st.reading);   /* the whole paragraph otherwise */
        }
    }
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    s_orstat = st;
    xSemaphoreGive(s_status_mutex);
}

static bool or_file_load(int i, const char *id)
{
    asset_info_t info;
    if (!storage_asset_find(id, &info)) return false;
    char path[96];
    storage_asset_path(id, path, sizeof path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    const size_t tbytes = hca_table_bytes(info.frames);
    uint8_t *table = heap_caps_malloc(tbytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    const bool ok = table && read_exact(fd, 0, table, tbytes) && hca_open(&s_or.f[i].a, table, tbytes) == HCA_OK;
    close(fd);
    if (!ok) {
        free(table);
        return false;
    }
    s_or.f[i].table = table;
    s_or.f[i].fd = -1;
    return true;
}

/* Stream op's frame into the framebuffer at its position (caller holds display_lock). */
static bool or_paint_op(const or_op_t *op)
{
    if (op->asset == OR_ASSET_TEXT) return or_paint_text(op->frame);   /* §5f.2: drawn, not an asset */
    if (op->asset >= OR_ASSETS || !s_or.f[op->asset].table) return false;
    or_file_t *f = &s_or.f[op->asset];
    hca_frame_info_t fi;
    if (hca_frame_info(&f->a, op->frame, &fi) != HCA_OK) return false;
    const uint16_t w = f->a.hdr.width, h = f->a.hdr.height;
    if (op->x < 0 || op->y < 0 || op->x + w > DISPLAY_W || op->y + h > DISPLAY_H) return false;
    if (op->asset == OR_ASSET_DECK && s_or.deck_mem) {   /* the deck cache: decode only */
        if (s_or.deck_full.hdr.width != w || s_or.deck_full.hdr.height != h) return false;   /* (never: or_deck_cache) */
        const hca_status_t hs = hca_decode_frame(&s_or.deck_full, op->frame, display_fb() + (size_t)op->y * DISPLAY_W + op->x,
                                                 DISPLAY_W);
        if (hs != HCA_OK) ESP_LOGE(TAG, "oracle %s: cached deck frame %u: %s", s_cur.item.id, op->frame, hca_status_str(hs));
        return hs == HCA_OK;
    }
    if (f->fd < 0) {
        char path[96];
        storage_asset_path(s_or.ids[op->asset], path, sizeof path);
        f->fd = open(path, O_RDONLY);
        if (f->fd < 0) return false;
    }
    const storage_status_t st = storage_frame_stream(f->fd, fi.offset, fi.length, w, h, f->a.hdr.compression,
                                                     display_fb() + (size_t)op->y * DISPLAY_W + op->x, DISPLAY_W, 0, w);
    if (st != STORAGE_OK) {
        ESP_LOGE(TAG, "oracle %s: %s frame %u: %s", s_cur.item.id, s_or.ids[op->asset], op->frame, storage_status_str(st));
    }
    return st == STORAGE_OK;
}

/* §5f.11 the corner arrow: on every screen but the shuffle. */
static bool or_hint_kind(void) { return s_or.o.phase != OR_SHUFFLE; }

/* Draw the arrow over the painted screen (caller holds display_lock) in the BOOT corner: top-right pointing right, or
 * bottom-left pointing left when the panel is flipped 180°. */
static void or_paint_hint(bool arrow, bool left)
{
    if (arrow) ot_draw_arrow(display_fb(), left);
}

/* Bring the framebuffer to draw `d`: only the ops that changed when the ground is the same, else all of it. With
 * `flush` the panel gets the changed rectangles (or one full flush). The §5f.9 hint is part of the screen: another
 * hint (three -> hold have the same ops) or another side (the panel flipped) repaints everything. */
static void or_paint(const or_draw_t *d, bool flush)
{
    const bool hint = or_hint_kind();
    const bool left = display_is_flipped();
    int mask = s_or.shown_ok ? or_draw_diff(&s_or.shown, d) : -1;
    if (mask >= 0 && (hint != s_or.hint || left != s_or.hint_left)) mask = -1;
    if (mask == 0) return;
    power_perf_begin();
    display_lock();
    const int64_t t0 = esp_timer_get_time();
    bool ok = true;
    if (mask < 0 && or_draw_black(d)) memset(display_fb(), 0, DISPLAY_FB_BYTES);
    for (int i = 0; i < d->n; i++) {
        if (mask < 0 || (mask & (1 << i))) ok &= or_paint_op(&d->op[i]);
    }
    if (mask < 0) {
        or_paint_hint(hint, left);   /* last: over the screen (a partial repaint never reaches the band) */
        s_or.hint = hint;
        s_or.hint_left = left;
    }
    const int64_t t1 = esp_timer_get_time();
    esp_err_t err = ESP_OK;
    if (flush && s_output) {
        if (mask < 0) {
            err = display_flush_full();
        } else {
            for (int i = 0; i < d->n && err == ESP_OK; i++) {
                if (!(mask & (1 << i))) continue;
                const or_asset_t a = (or_asset_t)d->op[i].asset;
                const int h = d->op[i].y + or_asset_h(a) > DISPLAY_H ? DISPLAY_H - d->op[i].y : or_asset_h(a);
                if (h > 0) err = display_flush_rect(d->op[i].x, d->op[i].y, or_asset_w(a), (uint16_t)h);
            }
        }
    }
    display_unlock();
    power_perf_end();
    if (err != ESP_OK) ESP_LOGE(TAG, "oracle flush: %s", esp_err_to_name(err));
    fb_touched();
    s_or.shown = *d;
    s_or.shown_ok = ok;   /* a failed op: the next paint is a full one */
    const uint32_t pu = (uint32_t)(t1 - t0);
    s_or.frames++;
    s_or.paint_us += pu;
    s_or.flush_us += (uint64_t)(esp_timer_get_time() - t1);
    if (pu > s_or.paint_max_us) s_or.paint_max_us = pu;
}

/* The item ends: holds released, files and tables dropped; the card shown last is remembered for the same text asset. */
static void or_close(void)
{
    or_release();
    if (s_orr.text_paints) {
        ESP_LOGI(TAG, "oracle %s: %lu text screens drawn (faces: %lu large, %lu normal, %lu compact, %lu cut), %llu us avg / "
                 "%lu max (layout + glyphs, before the flush)", s_cur.item.id, (unsigned long)s_orr.text_paints,
                 (unsigned long)s_orr.faces[0], (unsigned long)s_orr.faces[1], (unsigned long)s_orr.faces[2],
                 (unsigned long)s_orr.faces[3], (unsigned long long)(s_orr.text_us / s_orr.text_paints),
                 (unsigned long)s_orr.text_max_us);
    }
    or_unload();
    s_or.shown_ok = false;
}

/* Open the oracle of `it` and paint its waits screen into the framebuffer (caller holds display_lock and flushes). */
static bool or_begin(const pl_item_t *it)
{
    char msg[120];
    if (playlist_oracle_check(it, msg, sizeof msg) != PL_OK) {
        ESP_LOGW(TAG, "%s", msg);
        return false;
    }
    const int64_t t0 = esp_timer_get_time();
    s_or.cfg = it->orc;
    s_or.ids[OR_ASSET_TEXT][0] = '\0';   /* §5f.2: no text asset; the bundle + fonts draw the text screens */
    strlcpy(s_or.ids[OR_ASSET_DECK], it->orc.deck, sizeof s_or.ids[0]);
    strlcpy(s_or.ids[OR_ASSET_KEYS], it->orc.keys, sizeof s_or.ids[0]);   /* §5f.12: "" = no keyword row */
    s_or.ids[OR_ASSET_NOTES][0] = '\0';   /* §5f.7: the notes are no longer shown */
    bool ok = true;
    for (int i = 0; i < OR_ASSETS && ok; i++) {
        if (s_or.ids[i][0]) ok = or_file_load(i, s_or.ids[i]);
    }
    if (!ok) {
        ESP_LOGW(TAG, "oracle %s: cannot open its assets", it->id);
        or_unload();
        return false;
    }
    if (!orr_load()) {
        ESP_LOGW(TAG, "oracle %s: its bundle or font cannot be loaded", it->id);
        or_unload();
        return false;
    }
    or_config_t c = { .cards = it->orc.cards, .shake_g = it->orc.shake_g, .face_ms = it->orc.face_ms,
                      .page_ms = it->orc.page_ms, .hold_ms = it->orc.hold_ms, .keys = it->orc.keys[0] != '\0' };
    orr_card_details(&c);
    s_orr.para_draw = 0;   /* or_init restarts the draw count */
    s_orr.active = false;
    s_orr.text_paints = 0;
    s_orr.text_us = 0;
    s_orr.text_max_us = 0;
    memset(s_orr.faces, 0, sizeof s_orr.faces);
    or_init(&s_or.o, &c, esp_random());
    or_set_flipped(&s_or.o, display_is_flipped());   /* §5f.9: the three's y follows the orientation */
    or_draw_t d;
    or_step(&s_or.o, 0, 0.0f, false, &d);
    /* the waits screen, no flush (start_item flushes the whole frame) */
    s_or.shown_ok = false;
    const int64_t p0 = esp_timer_get_time();
    for (int i = 0; i < d.n && ok; i++) ok = or_paint_op(&d.op[i]);
    or_close_files();
    if (!ok) {
        or_unload();
        return false;
    }
    /* §5f.11: the first waits screen carries its arrow too (or_paint only adds it on a full repaint, and this
     * screen counts as shown; without this the hint appeared only at the next full repaint, e.g. armed). */
    s_or.hint = or_hint_kind();
    s_or.hint_left = display_is_flipped();
    or_paint_hint(s_or.hint, s_or.hint_left);
    s_or.shown = d;
    s_or.shown_ok = true;
    s_or.frames = 0;
    s_or.paint_us = s_or.flush_us = 0;
    s_or.paint_max_us = 0;
    ESP_LOGI(TAG, "oracle %s: %u cards, deck %s, keys %s, font %s%s, shake %.2f g, imu %s, "
             "waits painted in %lld ms (ready in %lld ms)", it->id, c.cards, it->orc.deck,
             it->orc.keys[0] ? it->orc.keys : "(none)", it->orc.font,
             s_orr.lview_ok ? " (large / normal / compact)" : s_orr.cview_ok ? " (normal / compact)" : "", (double)c.shake_g,
             imu_present() ? "yes" : "no (press / POST /oracle/draw only)", (long long)((esp_timer_get_time() - p0) / 1000),
             (long long)((esp_timer_get_time() - t0) / 1000));
    return true;
}

/* One step of the oracle: input in (shake metric, a press / turn / draw), the screen out, next wake-up. */
/* The forced row of a CMD_ORACLE draw's arg ((a+1) | (b+1) << 8 | (c+1) << 16; 0 = random): true and row[] set. */
static bool or_arg_row(uint32_t arg, int row[3])
{
    if (!arg) return false;
    for (int i = 0; i < 3; i++) row[i] = (int)((arg >> (8 * i)) & 0xFFu) - 1;
    return true;
}

static void or_frame(int action, uint32_t arg)
{
    if (!s_or.deck_tried) or_deck_cache();   /* once per item, before the clock is read (it takes a few hundred ms) */
    const int64_t now = esp_timer_get_time();
    int64_t el = now - s_or.last_us;
    if (el < 0) el = 0;
    const uint32_t dt = (uint32_t)(el / 1000);
    s_or.last_us += (int64_t)dt * 1000;   /* keep the sub-ms remainder: no drift of the timers */
    const float shake = (s_or.imu && action < 0) ? imu_get_shake() : 0.0f;
    const bool was_anim = or_animating(&s_or.o);
    const uint32_t draws0 = s_or.o.draws;
    or_set_flipped(&s_or.o, display_is_flipped());   /* §5f.9: the three sit away from the hint's corner */
    or_draw_t d;
    if (action == OR_CMD_DRAW) {
        or_step(&s_or.o, dt, 0.0f, false, &d);   /* time first, then the draw at "now" */
        int row[3];
        or_trigger(&s_or.o, or_arg_row(arg, row) ? row : NULL);
        or_step(&s_or.o, 0, 0.0f, false, &d);
    } else if (action == OR_CMD_BACK) {
        or_step(&s_or.o, dt, 0.0f, false, &d);   /* time first, then the previous screen (§5f.3) */
        or_back(&s_or.o);
        or_step(&s_or.o, 0, 0.0f, false, &d);
    } else {
        or_step(&s_or.o, dt, shake, action == OR_CMD_PRESS || action == OR_CMD_TURN, &d);
    }
    const bool anim = or_animating(&s_or.o);
    if (anim && (!was_anim || s_or.o.draws != draws0)) {
        s_or.shuf_t0 = now;
        s_or.frames = 0;
        s_or.paint_us = s_or.flush_us = 0;
        s_or.paint_max_us = 0;
        if (s_or.o.draws != draws0) {
            ESP_LOGI(TAG, "oracle %s: draw (%s): %d %d %d", s_cur.item.id,
                     action == OR_CMD_DRAW ? (arg ? "POST /oracle/draw, forced" : "POST /oracle/draw")
                     : action >= 0 ? "tap" : "shake", s_or.o.three[0], s_or.o.three[1], s_or.o.three[2]);
        }
    }
    /* §5f.7: a draw's lean screens and paragraph, composed when it first reaches the three (or a lean screen, for a
     * draw that got there by its timers) */
    if ((s_or.o.phase == OR_THREE || s_or.o.phase == OR_LEAN) && s_orr.para_draw != s_or.o.draws) {
        orr_compose_draw();
        or_step(&s_or.o, 0, 0.0f, false, &d);
    }
    or_perf(anim);
    or_paint(&d, true);
    if (was_anim && !anim && s_or.frames) {
        const uint32_t n = s_or.frames;
        ESP_LOGI("oracle", "%s: shuffle done in %lld ms, %lu paints, paint %llu us avg / %lu max, flush %llu us avg",
                 s_cur.item.id, (long long)((now - s_or.shuf_t0) / 1000), (unsigned long)n,
                 (unsigned long long)(s_or.paint_us / n), (unsigned long)s_or.paint_max_us,
                 (unsigned long long)(s_or.flush_us / n));
    }
    if (!anim) or_close_files();
    publish_oracle();
    const int64_t end = esp_timer_get_time();
    {   /* RTC breadcrumb for a stuck oracle on battery (printed at the next boot) */
        char note[96];
        const int sh = (int)(shake * 100.0f);
        snprintf(note, sizeof note, "or %s t=%lu ms dt=%lu shake=%d.%02d B=%d out=%d imu=%d", or_state_str(&s_or.o),
                 (unsigned long)s_or.o.t_ms, (unsigned long)dt, sh / 100, abs(sh) % 100, s_or.o.three[1], s_output, s_or.imu);
        health_item_note(note);
    }
    const uint32_t n = or_next_ms(&s_or.o);
    int64_t next = n == UINT32_MAX ? 0 : s_or.last_us + (int64_t)n * 1000;
    if (next && next < end + SCENE_MIN_GAP_US) next = end + SCENE_MIN_GAP_US;   /* behind: the shuffle skips ahead */
    /* §5f.8: a shake deals only on ARMED, so the metric is polled only there (elsewhere it is ignored anyway) */
    if (s_or.o.phase == OR_ARMED && s_or.imu && imu_present() && (next == 0 || next > end + OR_POLL_US)) {
        next = end + OR_POLL_US;
    }
    s_cur.next_frame_us = next;
}

/* CMD_ORACLE (player task): a press, POST /oracle/turn or POST /oracle/draw. */
static esp_err_t or_command(int action, uint32_t arg)
{
    if (s_cur.kind != CUR_ORACLE || !s_output || !s_or.f[OR_ASSET_DECK].table || !s_orr.b || s_frozen) {
        if (action == OR_CMD_PRESS && s_output && s_cur.kind != CUR_ORACLE) {
            /* the item changed under the press: it means "next" again */
            s_rd.held_text[0] = '\0';
            if (s_cur.override) {
                end_override(false);
            } else {
                advance(+1);
            }
            return ESP_OK;
        }
        return ESP_ERR_INVALID_STATE;
    }
    int row[3];
    if (action == OR_CMD_DRAW && or_arg_row(arg, row)) {
        for (int i = 0; i < 3; i++) {
            if (row[i] < 0 || row[i] >= (int)s_or.o.cfg.cards) return ESP_ERR_INVALID_ARG;
        }
        if (row[0] == row[1] || row[0] == row[2] || row[1] == row[2]) return ESP_ERR_INVALID_ARG;
    }
    if (action != OR_CMD_DRAW) {
        ESP_LOGI(TAG, "oracle %s: %s in %s", s_cur.item.id,
                 action == OR_CMD_PRESS ? "tap" : action == OR_CMD_BACK ? "back" : "turn", or_state_str(&s_or.o));
    }
    or_frame(action, arg);
    return ESP_OK;
}

/* ------------------------------------------------------------------ reader (RSVP, PROTOCOL §5c) */

static void fontc_unload(fontc_t *c)
{
    for (int i = 0; i < 6; i++) {
        free(c->atlas_data[i]);
        c->atlas_data[i] = NULL;
    }
    free(c->font);
    free(c->scratch);
    c->font = NULL;
    c->scratch = NULL;
    c->scratch_px = 0;
    c->id[0] = '\0';
}

static void reader_font_unload(void)
{
    if (s_rd.active) return;   /* in use */
    fontc_unload(&s_rd.fc);
}

/* Font document + its 2-4 atlases into PSRAM (cached while the same font id is used). `what` names the
 * user in the log ("reader", "oracle"). */
static bool fontc_load(fontc_t *c, const char *font_id, const char *what)
{
    if (c->font && strcmp(c->id, font_id) == 0) return true;
    fontc_unload(c);
    char *json = NULL;
    size_t len = 0;
    if (reader_font_read(font_id, &json, &len) != ESP_OK) {
        ESP_LOGW(TAG, "%s: font %s missing", what, font_id);
        return false;
    }
    c->font = heap_caps_malloc(sizeof *c->font, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    char err[64] = "";
    bool ok = c->font && rsvp_font_parse(json, len, c->font, err, sizeof err) == RSVP_OK;
    free(json);
    if (!ok) {
        ESP_LOGW(TAG, "%s: font %s invalid (%s)", what, font_id, err);
        fontc_unload(c);
        return false;
    }
    rsvp_font_t *f = c->font;
    const char *ids[4] = { f->normal.atlas_white, f->normal.atlas_accent, f->compact.atlas_white, f->compact.atlas_accent };
    const int n = f->has_compact ? 4 : 2;
    size_t total = 0;
    for (int i = 0; i < n && ok; i++) {
        size_t sz = 0;
        c->atlas_data[i] = load_whole(ids[i], &sz);
        ok = c->atlas_data[i] && hca_open(&c->atlas[i], c->atlas_data[i], sz) == HCA_OK;
        if (!ok) ESP_LOGW(TAG, "%s: font %s: atlas %s missing or invalid", what, font_id, ids[i]);
        total += sz;
    }
    rsvp_status_t bst = ok ? rsvp_font_bind(f, &c->atlas[0], &c->atlas[1], n == 4 ? &c->atlas[2] : NULL,
                                            n == 4 ? &c->atlas[3] : NULL) : RSVP_ERR_ATLAS;
    if (ok && bst != RSVP_OK) {
        ESP_LOGW(TAG, "%s: font %s: %s", what, font_id, rsvp_status_str(bst));
        ok = false;
    }
    if (ok && c->want_large && f->has_large) {   /* §5f.11: optional; a broken large face is skipped, not fatal */
        size_t s4 = 0, s5 = 0;
        c->atlas_data[4] = load_whole(f->large.atlas_white, &s4);
        c->atlas_data[5] = load_whole(f->large.atlas_accent, &s5);
        const bool lok = c->atlas_data[4] && c->atlas_data[5] && hca_open(&c->atlas[4], c->atlas_data[4], s4) == HCA_OK &&
                         hca_open(&c->atlas[5], c->atlas_data[5], s5) == HCA_OK &&
                         rsvp_font_bind_large(f, &c->atlas[4], &c->atlas[5]) == RSVP_OK;
        if (lok) {
            total += s4 + s5;
        } else {
            ESP_LOGW(TAG, "%s: font %s: large face unusable (atlases %s / %s): normal and compact only", what, font_id,
                     f->large.atlas_white, f->large.atlas_accent);
            for (int i = 4; i < 6; i++) {
                free(c->atlas_data[i]);
                c->atlas_data[i] = NULL;
            }
        }
    }
    if (ok) {
        /* glyph decode scratch: internal RAM if it can be spared (decoded for every glyph), else PSRAM */
        c->scratch_px = rsvp_font_scratch_px(f);
        c->scratch = heap_caps_malloc(c->scratch_px * 2, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        if (!c->scratch) c->scratch = heap_caps_malloc(c->scratch_px * 2, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        ok = c->scratch != NULL;
    }
    if (!ok) {
        fontc_unload(c);
        return false;
    }
    strlcpy(c->id, font_id, sizeof c->id);
    ESP_LOGI(TAG, "%s: font %s loaded: %ux%u%s%s, %u glyphs, atlases %u B in PSRAM", what, font_id, f->normal.cell_w,
             f->normal.cell_h, f->compact_bound ? " + compact" : "", f->large_bound ? " + large" : "", f->normal.count,
             (unsigned)total);
    return true;
}

static bool reader_font_load(const char *font_id) { return fontc_load(&s_rd.fc, font_id, "reader"); }

static void reader_close_files(void)
{
    if (s_rd.fd_txt >= 0) close(s_rd.fd_txt);
    if (s_rd.fd_idx >= 0) close(s_rd.fd_idx);
    s_rd.fd_txt = s_rd.fd_idx = -1;
}

static bool reader_open_files(void)
{
    if (s_rd.fd_txt >= 0 && s_rd.fd_idx >= 0) return true;
    reader_close_files();
    char path[96];
    reader_text_path(s_rd.info.id, path, sizeof path);
    s_rd.fd_txt = open(path, O_RDONLY);
    reader_idx_path(s_rd.info.id, path, sizeof path);
    s_rd.fd_idx = open(path, O_RDONLY);
    s_rd.idx_n = 0;
    if (s_rd.fd_txt < 0 || s_rd.fd_idx < 0) {
        ESP_LOGW(TAG, "reader: cannot open text %s", s_rd.info.id);
        reader_close_files();
        return false;
    }
    return true;
}

static void reader_save(void)
{
    if (!s_rd.active) return;
    s_rd.since_save = 0;
    reader_progress_set(s_rd.info.id, s_rd.phase == RD_END ? 0 : s_rd.word);
}

/* The reading stops (item ends, another item starts, reload): remember where. Font stays cached. */
static void reader_close(void)
{
    if (s_rd.active) reader_save();
    if (!s_rd.keep_pause) s_rd.paused_text[0] = '\0';
    reader_close_files();
    s_rd.active = false;
    publish_reader();
}

/* Index entry i (offset | flags << 29), read in blocks of READER_IDX_CACHE. */
static bool reader_idx(uint32_t i, uint32_t *e)
{
    if (i >= s_rd.info.words || !reader_open_files()) return false;
    if (i < s_rd.idx_base || i >= s_rd.idx_base + s_rd.idx_n) {
        uint32_t n = s_rd.info.words - i;
        if (n > READER_IDX_CACHE) n = READER_IDX_CACHE;
        if (!read_exact(s_rd.fd_idx, READER_IDX_HEADER + 4u * i, s_rd.idx_raw, n * 4u)) {
            s_rd.idx_n = 0;
            return false;
        }
        s_rd.idx_base = i;
        s_rd.idx_n = n;
    }
    const uint8_t *p = s_rd.idx_raw + 4u * (i - s_rd.idx_base);
    *e = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    return true;
}

/* Word i: its bytes into buf (w->len of them, from buf[0]) and its timing flags from the index. */
static bool reader_load_word(uint32_t i, rsvp_word_t *w, char *buf)
{
    uint32_t e;
    if (!reader_idx(i, &e)) return false;
    const uint32_t off = e & READER_IDX_OFF_MASK;
    if (off >= s_rd.info.bytes) return false;
    size_t n = s_rd.info.bytes - off;
    if (n > READER_TXT_READ) n = READER_TXT_READ;
    if (!read_exact(s_rd.fd_txt, off, buf, n) || !rsvp_word_at(buf, n, off + n == s_rd.info.bytes, w)) return false;
    w->flags = (uint8_t)(e >> READER_IDX_FLAG_SHIFT);
    return w->off == 0;
}

static void reader_flush(const rsvp_rect_t *d)
{
    if (!s_output || d->w <= 0 || d->h <= 0) return;
    esp_err_t err = display_flush_rect(d->x, d->y, d->w, d->h);
    if (err != ESP_OK) ESP_LOGE(TAG, "reader flush: %s", esp_err_to_name(err));
}

static void reader_draw_pause(bool on)
{
    rsvp_rect_t d;
    display_lock();
    rsvp_paint_pause(&s_rd.painter, s_rd.fc.font, on, display_fb(), s_rd.fc.scratch, s_rd.fc.scratch_px, &d);
    reader_flush(&d);
    display_unlock();
}

static void reader_stats(int64_t now)
{
    if (now - s_rd.stat_t0 < READER_STATS_US) return;
    if (s_rd.words_shown) {
        const uint32_t n = s_rd.words_shown;
        ESP_LOGI("reader", "%s: word %lu/%lu at %u wpm, %lu words in %lld s, paint %llu us, flush %llu us (avg)",
                 s_rd.info.id, (unsigned long)s_rd.word + 1, (unsigned long)s_rd.info.words, s_cur.item.wpm,
                 (unsigned long)n, (long long)((now - s_rd.stat_t0) / 1000000), (unsigned long long)(s_rd.paint_us / n),
                 (unsigned long long)(s_rd.flush_us / n));
    }
    s_rd.stat_t0 = now;
    s_rd.words_shown = 0;
    s_rd.paint_us = s_rd.flush_us = 0;
}

/* Paint word i (dirty band only) and flush it. */
static bool reader_show(uint32_t i)
{
    char buf[READER_TXT_READ];
    rsvp_word_t w;
    if (!reader_load_word(i, &w, buf)) {
        ESP_LOGW(TAG, "reader: %s: cannot read word %lu", s_rd.info.id, (unsigned long)i);
        return false;
    }
    power_perf_begin();
    display_lock();
    if (s_rd.fb_dirty) {
        rsvp_painter_invalidate(&s_rd.painter);
        s_rd.fb_dirty = false;
    }
    const bool full = s_rd.painter.full;
    const int64_t t0 = esp_timer_get_time();
    rsvp_rect_t d;
    int fails = rsvp_paint(&s_rd.painter, s_rd.fc.font, buf, w.len, display_fb(), s_rd.fc.scratch, s_rd.fc.scratch_px, &d, NULL);
    const int64_t t1 = esp_timer_get_time();
    reader_flush(&d);
    if (s_rd.paused && full) reader_draw_pause(true);   /* a full repaint wiped the mark */
    display_unlock();
    power_perf_end();
    const int64_t t2 = esp_timer_get_time();
    if (fails) ESP_LOGW(TAG, "reader: %d glyph(s) of word %lu failed to decode", fails, (unsigned long)i);
    s_rd.cur = w;
    s_rd.word = i;
    s_rd.phase = RD_WORD;
    s_rd.words_shown++;
    s_rd.paint_us += (uint64_t)(t1 - t0);
    s_rd.flush_us += (uint64_t)(t2 - t1);
    publish_reader();
    return true;
}

static void reader_blank(void)
{
    power_perf_begin();
    display_lock();
    rsvp_rect_t d;
    rsvp_paint(&s_rd.painter, s_rd.fc.font, NULL, 0, display_fb(), s_rd.fc.scratch, s_rd.fc.scratch_px, &d, NULL);
    reader_flush(&d);
    display_unlock();
    power_perf_end();
    s_rd.phase = RD_BLANK;
}

static void reader_end_card(void)
{
    const uint64_t total = rsvp_total_ms(s_rd.info.factor_x10, s_rd.info.paragraphs, s_cur.item.wpm);
    power_perf_begin();
    display_lock();
    rsvp_rect_t d;
    rsvp_paint_end_card(&s_rd.painter, s_rd.fc.font, s_rd.info.words, rsvp_minutes(total), display_fb(), s_rd.fc.scratch,
                        s_rd.fc.scratch_px, &d);
    if (s_rd.paused) reader_draw_pause(true);
    reader_flush(&d);
    display_unlock();
    power_perf_end();
    s_rd.phase = RD_END;
    reader_save();   /* finished: the next start begins at word 0 */
    ESP_LOGI(TAG, "reader: %s finished (%lu words, %lu min at %u wpm)", s_rd.info.id, (unsigned long)s_rd.info.words,
             (unsigned long)rsvp_minutes(total), s_cur.item.wpm);
    publish_reader();
}

/* A lone reader item finished (or hit its duration_ms cap): keep the end card on screen, no timers. */
static void reader_hold_end(void)
{
    if (s_rd.phase != RD_END) reader_end_card();
    strlcpy(s_rd.held_text, s_rd.info.id, sizeof s_rd.held_text);
    s_cur.next_frame_us = 0;
    s_cur.end_us = 0;
    s_rd.remaining_us = 0;
    ESP_LOGI(TAG, "reader: %s end card held (lone item)", s_rd.info.id);
}

/* Open `it` at its saved progress and paint the first word into the framebuffer (caller holds
 * display_lock and flushes). `hold_end`: a lone item whose end card was held: paint the end card again
 * instead of restarting the reading. */
static bool reader_begin(const pl_item_t *it, bool hold_end)
{
    if (!reader_font_load(it->font)) return false;
    if (!reader_text_info(it->id, &s_rd.info)) {
        ESP_LOGW(TAG, "reader: text %s missing", it->id);
        return false;
    }
    reader_close_files();
    if (!reader_open_files()) return false;
    uint32_t start = reader_progress_get(it->id);
    if (start >= s_rd.info.words) start = 0;
    s_rd.word = start;
    s_rd.since_save = 0;
    s_rd.phase = RD_WORD;
    s_rd.paused = strcmp(s_rd.paused_text, it->id) == 0;
    s_rd.remaining_us = 0;
    rsvp_painter_init(&s_rd.painter, s_rd.fc.font, DISPLAY_W, DISPLAY_H, RSVP_ORP_X);
    s_rd.fb_dirty = false;
    s_rd.active = true;
    const bool out = s_output;
    s_output = false;            /* paint only: start_item flushes the whole frame */
    bool ok = true;
    if (hold_end) {
        s_rd.word = s_rd.info.words ? s_rd.info.words - 1 : 0;
        reader_end_card();       /* draws the pause mark itself when paused */
    } else {
        s_rd.held_text[0] = '\0';
        ok = reader_show(start);
        if (ok && s_rd.paused) reader_draw_pause(true);
    }
    s_output = out;
    if (!ok) {
        s_rd.active = false;
        reader_close_files();
        return false;
    }
    s_rd.stat_t0 = esp_timer_get_time();
    s_rd.words_shown = 0;
    s_rd.paint_us = s_rd.flush_us = 0;
    ESP_LOGI(TAG, "reader: %s \"%s\", %lu words, from word %lu at %u wpm, font %s%s", it->id, s_rd.info.title,
             (unsigned long)s_rd.info.words, (unsigned long)start, it->wpm, it->font, s_rd.paused ? " [paused]" : "");
    return true;
}

/* Next timing slot from the previous one (exact pacing; a late tick does not burst). */
static void reader_schedule(uint32_t ms, int64_t now)
{
    s_cur.next_frame_us += (int64_t)ms * 1000;
    if (s_cur.next_frame_us < now) s_cur.next_frame_us = now + (int64_t)ms * 1000;
}

/* The current slot elapsed. Returns true when the reading is over (end card shown, no loop) or broken. */
static bool reader_tick(void)
{
    const int64_t now = esp_timer_get_time();
    reader_stats(now);
    switch (s_rd.phase) {
    case RD_WORD:
        if (rsvp_blank_ms(&s_rd.cur)) {
            reader_blank();
            reader_schedule(RSVP_PARA_BLANK_MS, now);
            return false;
        }
        /* fall through */
    case RD_BLANK: {
        const uint32_t next = s_rd.word + 1;
        if (next >= s_rd.info.words) {
            reader_end_card();
            s_cur.next_frame_us = now + (int64_t)RSVP_END_CARD_MS * 1000;
            return false;
        }
        if (!reader_show(next)) return true;
        if (++s_rd.since_save >= READER_SAVE_EVERY) reader_save();
        reader_schedule(rsvp_word_ms(&s_rd.cur, s_cur.item.wpm), now);
        return false;
    }
    case RD_END:
    default:
        if (!s_cur.item.loop && s_cur.single && !s_cur.override) {
            /* Lone rotation item: hold the end card (no restart); /next, a seek or from_word restarts. */
            reader_hold_end();
            return false;
        }
        if (!s_cur.item.loop) return true;
        if (!reader_show(0)) return true;   /* the end card set a full repaint */
        s_cur.next_frame_us = now + (int64_t)rsvp_word_ms(&s_rd.cur, s_cur.item.wpm) * 1000;
        return false;
    }
}

static void reader_set_paused(bool paused)
{
    if (paused == s_rd.paused) return;
    s_rd.paused = paused;
    const int64_t now = esp_timer_get_time();
    if (paused) {
        strlcpy(s_rd.paused_text, s_rd.info.id, sizeof s_rd.paused_text);
        s_rd.remaining_us = s_cur.end_us ? (s_cur.end_us > now ? s_cur.end_us - now : 1) : 0;
        s_cur.end_us = 0;           /* the duration_ms cap is frozen while paused */
        s_cur.next_frame_us = 0;
        reader_save();
    } else {
        s_rd.paused_text[0] = '\0';
        if (s_output) {
            uint32_t ms = s_rd.phase == RD_WORD ? rsvp_word_ms(&s_rd.cur, s_cur.item.wpm)
                        : s_rd.phase == RD_BLANK ? RSVP_PARA_BLANK_MS : RSVP_END_CARD_MS;
            s_cur.next_frame_us = now + (int64_t)ms * 1000;
            s_cur.end_us = s_rd.remaining_us ? now + s_rd.remaining_us : 0;
        }
        s_rd.remaining_us = 0;
    }
    reader_draw_pause(paused);
    ESP_LOGI(TAG, "reader: %s at word %lu", paused ? "paused" : "resumed", (unsigned long)s_rd.word);
    publish_reader();
}

static esp_err_t reader_seek(uint32_t word)
{
    if (word >= s_rd.info.words) return ESP_ERR_INVALID_ARG;
    if (!reader_show(word)) return ESP_FAIL;
    s_rd.held_text[0] = '\0';
    reader_save();
    if (!s_rd.paused && s_output) s_cur.next_frame_us = esp_timer_get_time() + (int64_t)rsvp_word_ms(&s_rd.cur, s_cur.item.wpm) * 1000;
    ESP_LOGI(TAG, "reader: seek to word %lu", (unsigned long)word);
    return ESP_OK;
}

/* PUT /playlist: reader items with from_word > 0 set where their text starts (PROTOCOL §5c "from_word
 * overrides it"); later starts resume from the saved progress. */
static void reader_apply_from_words(void)
{
    for (size_t i = 0; i < s_pl->count; i++) {
        const pl_item_t *it = &s_pl->items[i];
        if (it->type == PL_ITEM_READER && it->from_word > 0) {
            reader_progress_set(it->id, it->from_word);
            if (strcmp(s_rd.held_text, it->id) == 0) s_rd.held_text[0] = '\0';   /* from_word restarts it */
        }
    }
    for (size_t i = 0; i < s_pl->queue_count; i++) {
        const pl_item_t *it = &s_pl->queue[i].item;
        if (it->type == PL_ITEM_READER && it->from_word > 0) reader_progress_set(it->id, it->from_word);
    }
}

/* ------------------------------------------------------------------ item lifecycle */

static bool item_playable(const pl_item_t *it)
{
    if (it->missing) return false;
    return it->type == PL_ITEM_ASSET || it->type == PL_ITEM_READER ||
           it->type == PL_ITEM_ORACLE || it->type == PL_ITEM_BOARD
#if PL_SCENES
           || it->type == PL_ITEM_SCENE
#endif
        ; /* clock/text: not in v1 firmware */
}

/* Rotation items currently inside their time window. */
static bool item_active(const pl_item_t *it)
{
    if (!sched_has_window(it->from_min, it->until_min)) return true;
    return playlist_item_in_window(it, timekeeping_now(), timekeeping_tz(), timekeeping_synced());
}

static int active_count(void)
{
    int n = 0;
    for (size_t i = 0; i < s_pl->count; i++) n += item_playable(&s_pl->items[i]) && item_active(&s_pl->items[i]);
    return n;
}

static const char *item_name(const pl_item_t *it)
{
    return it->id;
}

static void apply_brightness_after_flush(bool fade)
{
    if (display_get_brightness() == s_brightness) return;
    if (fade || display_get_brightness() == 0) {
        display_fade_to(s_brightness, DISPLAY_FADE_MS);
        fb_touched();
    } else {
        display_set_brightness(s_brightness);
    }
}

/* Show the idle screen (empty / unplayable playlist). */
static void show_idle(void)
{
    close_current();
    s_cur.kind = CUR_IDLE;
    s_cur.override = false;
    s_cur.single = false;
    if (s_cur.queue_entry) {
        s_cur.queue_entry = false;
        sched_set_active(-1);
    }
    s_idle_active = active_count();
    display_lock();
    ui_screen_idle();
    fb_touched();
    if (s_output) {
        esp_err_t err = display_flush_full();
        if (err != ESP_OK) ESP_LOGE(TAG, "flush: %s", esp_err_to_name(err));
    }
    display_unlock();
    if (s_output) apply_brightness_after_flush(false);
    publish_status();
}

/* Open + render the first frame of `it`. Returns false if it cannot be played. */
static bool start_item(const pl_item_t *it, bool override, bool use_transition)
{
    if (!item_playable(it)) return false;
    bool fade = use_transition && s_output && it->transition == APPCFG_TRANSITION_FADE;
    if (fade && s_cur.kind != CUR_NONE && display_get_brightness() > 0) {
        display_fade_to(0, DISPLAY_FADE_MS);
        fb_touched();
    }
    close_current();
    s_cur.item = *it;
    s_cur.override = override;
    if (!override && s_cur.queue_entry) {
        s_cur.queue_entry = false;
        sched_set_active(-1);
    }
    s_cur.single = false;
    s_cur.frame = 0;
    s_cur.loops_done = 0;
    /* The only active rotation item (after window filtering) plays indefinitely: see "Lone item" in
     * README. Computed before opening: a lone reader that finished shows its end card again. */
    const bool single = !override && active_count() <= 1;

    power_perf_begin();
    bool ok;
    display_lock();
    if (it->type == PL_ITEM_ASSET) {
        asset_info_t info;
        if (storage_asset_find(it->id, &info) && info.strip) {
            ok = strip_begin(it);
        } else {
            ok = asset_open(it->id) && asset_decode(0);
        }
        if (ok) s_cur.kind = CUR_ASSET;
#if PL_SCENES
    } else if (it->type == PL_ITEM_SCENE) {
        ok = scene_begin(it);
        if (ok) s_cur.kind = CUR_SCENE;
#endif
    } else if (it->type == PL_ITEM_READER) {
        ok = reader_begin(it, single && !it->loop && strcmp(s_rd.held_text, it->id) == 0);
        if (ok) s_cur.kind = CUR_READER;
    } else if (it->type == PL_ITEM_ORACLE) {
        ok = or_begin(it);
        if (ok) s_cur.kind = CUR_ORACLE;
    } else {                                             /* PL_ITEM_BOARD (item_playable) */
        ok = board_begin(it);
        if (ok) s_cur.kind = CUR_BOARD;
    }
    if (ok) orient_sync();                               /* scenes stay upright (they follow real gravity) */
    if (ok && s_output) {
        int64_t t0 = esp_timer_get_time();
        esp_err_t err = display_flush_full();
        if (err != ESP_OK) ESP_LOGE(TAG, "flush: %s", esp_err_to_name(err));
        ESP_LOGD(TAG, "first frame flush %lld us", (long long)(esp_timer_get_time() - t0));
    }
    display_unlock();
    power_perf_end();

    if (!ok) {
        close_current();
        return false;
    }
    if (!s_output) {
        /* Offscreen render only: release the file so uploads/deletes are unconstrained. */
        if (s_cur.fd >= 0) close(s_cur.fd);
        s_cur.fd = -1;
        reader_close_files();
        publish_status();
        publish_reader();
        publish_oracle();
        return true;
    }
    apply_brightness_after_flush(fade);

    /* Timing starts once the item is visible. */
    int64_t now = esp_timer_get_time();
    uint32_t dur = it->duration_ms;
    s_cur.loop_bounded = false;
    int64_t scroll_end_us = 0;
    if (s_cur.kind == CUR_ASSET && s_cur.scrolling) {
        /* duration_ms > 0 wins (endless tape, cut by end_us); else `loops` passes; a single rotation
         * item scrolls forever like a looping animation. Travel starts once the item is visible. */
        const pl_scroll_t *sc = &it->scroll;
        s_cur.scroll_t0_us = now;
        s_cur.scroll_end_px = 0;
        /* POST /show of a strip without duration_ms: `loops` passes when the scroll gave them, else the
         * /show default of 60 s on an endless tape (queue entries always carry a duration). */
        if (dur == 0 && override && !sc->loops_set) dur = PLAYER_SHOW_DEFAULT_MS;
        if (dur == 0 && !single) {
            s_cur.scroll_end_px = (uint64_t)(sc->loops - 1) * (s_cur.strip_w + sc->gap_px) + s_cur.strip_w + DISPLAY_W;
            scroll_end_us = strip_time_of(s_cur.scroll_end_px);
        }
        s_cur.next_frame_us = now + STRIP_FRAME_US;
        s_st.stat_t0 = now;
        s_st.frames = 0;
        s_st.compose_us = s_st.flush_us = 0;
        strip_hold(true);
    } else if (s_cur.kind == CUR_ASSET && s_cur.asset.hdr.frame_count > 1) {
        s_cur.next_frame_us = now + (int64_t)frame_ms(0) * 1000;
        if (dur == 0 && !single) s_cur.loop_bounded = !override;
        if (dur == 0 && override) dur = PLAYER_SHOW_DEFAULT_MS;
    } else if (s_cur.kind == CUR_ASSET) {
        if (dur == 0) dur = override ? PLAYER_SHOW_DEFAULT_MS : STILL_DEFAULT_MS;
        if (s_cur.fd >= 0) close(s_cur.fd); /* still image: nothing more to read */
        s_cur.fd = -1;
#if PL_SCENES
    } else if (s_cur.kind == CUR_SCENE) {
        if (dur == 0) dur = override ? PLAYER_SHOW_DEFAULT_MS : PLAYLIST_SCENE_DEFAULT_MS;
        scene_hold(true);
        s_sc.last_step_us = now;
        s_sc.stat_t0 = now;
        s_cur.next_frame_us = now + SCENE_FRAME_US;
#endif
    } else if (s_cur.kind == CUR_ORACLE) {
        /* duration_ms as for a still (PROTOCOL §5f), deferred while a draw is in progress (§5f.8); a lone item
         * holds (end_us 0). The shake metric is polled every OR_POLL_US on ARMED while the IMU samples at 50 Hz;
         * presses, POST /oracle/draw|turn and the state machine's own timers move the rest. */
        if (dur == 0) dur = override ? PLAYER_SHOW_DEFAULT_MS : STILL_DEFAULT_MS;
        or_imu(true);
        s_or.last_us = now;
        s_cur.next_frame_us = now + OR_POLL_US;   /* the first step caches the deck (then: IMU polling, timers, presses) */
        publish_oracle();
    } else if (s_cur.kind == CUR_BOARD) {
        /* §5g: duration_ms as a scene's (0 = 60 s; a lone item holds); the row set every second, the scroll at
         * <= 30 fps only while it scrolls */
        if (dur == 0) dur = override ? PLAYER_SHOW_DEFAULT_MS : PLAYLIST_SCENE_DEFAULT_MS;
        s_bd.last_us = now;
        s_bd.stat_t0 = now;
        s_cur.next_tick_us = next_second_boundary_us();
        s_cur.next_frame_us = s_bd.b.scrolling ? now + (int64_t)BOARD_FRAME_MS * 1000 : 0;
    } else if (s_cur.kind == CUR_READER) {
        /* Words are paced by rsvp_word_ms(); the item ends after the end card (duration_ms 0) or when
         * duration_ms caps it. Paused: no timers, the cap waits. */
        if (s_rd.phase == RD_END) {
            dur = 0;                 /* a lone item's held end card (reader_begin hold_end): no timers */
            s_rd.remaining_us = 0;
        } else if (s_rd.paused) {
            s_rd.remaining_us = (int64_t)dur * 1000;
            dur = 0;
        } else {
            s_cur.next_frame_us = now + (int64_t)rsvp_word_ms(&s_rd.cur, it->wpm) * 1000;
        }
    }
    /* A lone item ignores duration_ms, except a reader item: its cap ends the reading on the held end card. */
    const bool lone_cap = single && s_cur.kind == CUR_READER;
    s_cur.end_us = ((single && !lone_cap) || s_cur.loop_bounded || dur == 0) ? 0 : now + (int64_t)dur * 1000;
    if (scroll_end_us) {
        s_cur.end_us = scroll_end_us;
        dur = (uint32_t)((scroll_end_us - now + 999) / 1000);
    }
    s_cur.single = single;
    publish_reader();
    ESP_LOGI(TAG, "%s %s%s%s (%s, %lu ms)", override ? "showing" : "playing",
             item_name(it), single ? " [single]" : "", s_cur.scrolling ? " [scrolling]" : s_cur.strip ? " [strip, still]" : "",
             it->transition == APPCFG_TRANSITION_FADE ? "fade" : "cut", (unsigned long)(s_cur.end_us ? dur : 0));
    publish_status();
    return true;
}

/* Move through the playlist by `dir` (+1 / -1, or 0 = (re)start the current index) until an
 * item plays; falls back to the idle screen if none can. */
static void advance(int dir)
{
    const int n = (int)s_pl->count;
    if (n == 0) {
        s_index = -1;
        show_idle();
        return;
    }
    int first;
    if (s_index < 0 || s_index >= n) {
        first = 0;
    } else {
        first = ((s_index + dir) % n + n) % n;
    }
    const int step = dir < 0 ? -1 : 1;
    bool any_active = false;
    for (int attempt = 0; attempt < n; attempt++) {
        int idx = ((first + attempt * step) % n + n) % n;
        if (!item_active(&s_pl->items[idx])) continue;   /* outside its from/until window */
        any_active = true;
        s_index = idx;
        if (start_item(&s_pl->items[idx], false, true)) return;
    }
    ESP_LOGW(TAG, "%s", any_active ? "nothing playable in playlist" : "every item is outside its time window");
    show_idle();
}

static void start_override(const pl_item_t *it)
{
    if (!start_item(it, true, true)) {
        ESP_LOGW(TAG, "cannot show %s", item_name(it));
        if (s_cur.kind == CUR_NONE) advance(0);   /* the previous item was already closed */
    }
}

/* Can `it` be started right now (cheap checks, before the current item is torn down)? */
static bool content_available(const pl_item_t *it)
{
    if (!item_playable(it)) return false;
    switch (it->type) {
    case PL_ITEM_ASSET: {
        asset_info_t a;
        return storage_asset_find(it->id, &a) && !a.atlas;
    }
    case PL_ITEM_READER: return reader_text_exists(it->id) && reader_font_exists(it->font);
    case PL_ITEM_ORACLE: {
        char msg[120];
        return playlist_oracle_check(it, msg, sizeof msg) == PL_OK;
    }
#if PL_SCENES
    case PL_ITEM_SCENE: return scene_find(it->id) != NULL;
#endif
    case PL_ITEM_BOARD: return storage_asset_find(it->id, NULL);   /* §5g: board_begin checks the sheet */
    default: return false;
    }
}

/* Play queue[qi] now as an interrupt; the rotation resumes when it ends. */
static void start_queue(int qi, bool test)
{
    const pl_queue_entry_t *qe = &s_pl->queue[qi];
    if (!content_available(&qe->item)) {
        ESP_LOGW(TAG, "queue entry %s: content %s unavailable, skipped", qe->id, item_name(&qe->item));
        return;   /* already marked done by sched_poll (or a test): nothing to undo */
    }
    ESP_LOGI(TAG, "queue entry %s%s: %s for %lu ms", qe->id, test ? " (test)" : "", item_name(&qe->item),
             (unsigned long)qe->item.duration_ms);
    if (!start_item(&qe->item, true, true)) {
        ESP_LOGW(TAG, "queue entry %s failed to start", qe->id);
        s_cur.override = false;
        advance(0);
        return;
    }
    s_cur.queue_entry = true;
    strlcpy(s_cur.queue_id, qe->id, sizeof s_cur.queue_id);
    sched_set_active(qi);
    publish_status();
}

/* An override (show or queue entry) ended or was cancelled: back to the rotation, or to a /show
 * that was deferred because a queue entry was playing. */
static void end_override(bool allow_pending)
{
    const bool was_queue = s_cur.queue_entry;
    s_cur.override = false;
    s_cur.queue_entry = false;
    sched_set_active(-1);
    if (was_queue && allow_pending && s_pending_show) {
        s_pending_show = false;
        start_override(&s_pending_item);
        return;
    }
    s_pending_show = false;
    advance(0);   /* back to the interrupted playlist item */
}

/* Restart whatever is current (after reload / output re-enable). */
static void restart_current(bool use_transition)
{
    if (s_cur.override && start_item(&s_cur.item, true, use_transition)) return;
    s_cur.override = false;
    advance(0);
}

/* ------------------------------------------------------------------ scheduler tick */

static void sched_reload(void)
{
    size_t n = s_pl->queue_count;
    sched_slot_t *slots = n ? heap_caps_malloc(n * sizeof *slots, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT) : NULL;
    if (n && !slots) {
        ESP_LOGE(TAG, "no memory for the queue: entries ignored");
        n = 0;
    }
    for (size_t i = 0; i < n; i++) {
        strlcpy(slots[i].id, s_pl->queue[i].id, sizeof slots[i].id);
        slots[i].at = s_pl->queue[i].at;
    }
    sched_load(slots, n);
    free(slots);
    s_has_windows = false;
    for (size_t i = 0; i < s_pl->count; i++) {
        s_has_windows |= sched_has_window(s_pl->items[i].from_min, s_pl->items[i].until_min);
    }
    if (s_cur.queue_entry) sched_set_active(sched_find(s_cur.queue_id));
    s_next_sched_us = (s_has_windows || s_pl->queue_count) ? esp_timer_get_time() + SCHED_TICK_US : 0;
}

/* Once per second while the panel shows content: fire due queue entries, and keep the rotation
 * consistent with the time windows (current item's window closed, an idle screen whose items'
 * windows opened, a "single" item that now has company). */
static void sched_tick(void)
{
    s_next_sched_us = (s_has_windows || s_pl->queue_count) ? esp_timer_get_time() + SCHED_TICK_US : 0;
    if (!s_cur.queue_entry && s_pl->queue_count) {
        int qi = sched_poll(timekeeping_now(), timekeeping_synced());
        if (qi >= 0 && (size_t)qi < s_pl->queue_count) {
            start_queue(qi, false);
            return;
        }
    }
    if (s_cur.override || !s_has_windows) return;
    if (s_cur.kind == CUR_IDLE) {
        /* Retry only when more items became active (a window opened), not every second for an
         * item that is active but cannot start (e.g. a reader item without its font). */
        const int n = active_count();
        if (n > s_idle_active) {
            advance(0);
        } else {
            s_idle_active = n;
        }
    } else if (s_cur.kind != CUR_NONE && !item_active(&s_cur.item)) {
        ESP_LOGI(TAG, "%s: time window closed", item_name(&s_cur.item));
        advance(+1);
    } else if (s_cur.single && active_count() > 1) {
        advance(+1);
    }
}

/* ------------------------------------------------------------------ periodic work */

static void on_frame_due(void)
{
    uint16_t next = s_cur.frame + 1;
    if (next >= s_cur.asset.hdr.frame_count) {
        next = 0;
        s_cur.loops_done++;
        if (s_cur.loop_bounded && s_cur.loops_done >= s_cur.item.loops) {
            advance(+1);
            return;
        }
    }
    power_perf_begin();
    display_lock();
    bool ok = asset_decode(next);
    esp_err_t err = ok ? display_flush_full() : ESP_FAIL;
    display_unlock();
    power_perf_end();
    if (!ok) {
        advance(+1);
        return;
    }
    if (err != ESP_OK) ESP_LOGE(TAG, "flush: %s", esp_err_to_name(err));
    s_cur.frame = next;
    int64_t now = esp_timer_get_time();
    s_cur.next_frame_us += (int64_t)frame_ms(next) * 1000;
    if (s_cur.next_frame_us < now) s_cur.next_frame_us = now + (int64_t)frame_ms(next) * 1000; /* late: don't burst */
}

/* §5f.8 no interruptions: a draw is in progress on the current oracle (any screen other than waits). The item's end
 * (duration_ms), queue entries and the time windows wait until it is back at waits; /show, a new playlist and
 * /queue/test still act at once. */
static bool s_or_held;   /* or_holds() at the last pass of the player loop */

static bool or_holds(void) { return s_cur.kind == CUR_ORACLE && or_in_draw(&s_or.o); }

/* Once per pass of the player loop: when a draw ends (back at waits, or the oracle replaced), what waited fires at
 * once if still due: the item's end (end_us in the past), a scheduler tick now (queue entries — sched_poll skips those
 * more than 10 minutes late — and windows). */
static void or_hold_check(void)
{
    const bool held = or_holds();
    if (held == s_or_held) return;
    s_or_held = held;
    const int64_t now = esp_timer_get_time();
    if (held) {
        ESP_LOGI(TAG, "oracle %s: a draw (%s): the item's end, queue and windows wait", s_cur.item.id,
                 or_state_str(&s_or.o));
        return;
    }
    const bool end = s_cur.end_us && now >= s_cur.end_us;
    if (s_has_windows || s_pl->queue_count) s_next_sched_us = now;
    ESP_LOGI(TAG, "draw over (%s): %s%s", s_cur.kind == CUR_ORACLE ? "back at waits" : "item changed",
             end ? "item end due, " : "",
             (s_has_windows || s_pl->queue_count) ? "scheduler tick now" : "nothing scheduled");
}

static int64_t next_deadline(void)
{
    int64_t d = 0;
    int64_t c[5] = { s_cur.next_frame_us, s_cur.end_us, s_cur.next_tick_us, s_output ? s_next_sched_us : 0,
                     s_output ? s_badge_next_us : 0 };
    if (s_frozen) {   /* only the pulse and the unfreeze safety net run while frozen */
        c[0] = c[1] = c[2] = c[3] = 0;
        c[0] = s_frozen_until_us;
    } else if (or_holds()) {
        /* §5f.8: a draw in progress: only the oracle's own frames / timers; the end, queue and windows wait */
        c[1] = c[3] = 0;
    }
    for (int i = 0; i < 5; i++) {
        if (c[i] && (d == 0 || c[i] < d)) d = c[i];
    }
    return d;
}

static void service_timers(void)
{
    int64_t now = esp_timer_get_time();
    if (s_badge_next_us && now >= s_badge_next_us) badge_paint();   /* cheap; falls through */
    const bool held = or_holds();   /* §5f.8: a draw in progress defers the end and the scheduler */
    if (!held && s_cur.end_us && now >= s_cur.end_us) {
        if (s_cur.kind == CUR_READER && s_cur.single && !s_cur.override && s_rd.active) {
            reader_hold_end();       /* lone reader: duration_ms cap reached, hold the end card */
            return;
        }
        if (s_cur.override) {
            end_override(true);
        } else {
            advance(+1);
        }
        return;
    }
    if (!held && s_next_sched_us && now >= s_next_sched_us) {
        sched_tick();
        return;
    }
#if PL_SCENES
    if (s_cur.kind == CUR_SCENE && s_cur.next_frame_us && now >= s_cur.next_frame_us) {
        scene_frame();
        return;
    }
#endif
    if (s_cur.kind == CUR_ORACLE && s_cur.next_frame_us && now >= s_cur.next_frame_us) {
        or_frame(-1, 0);
        return;
    }
    if (s_cur.kind == CUR_READER && s_cur.next_frame_us && now >= s_cur.next_frame_us) {
        if (reader_tick()) {
            if (s_cur.override) {
                end_override(true);
            } else {
                advance(+1);
            }
        }
        return;
    }
    if (s_cur.kind == CUR_ASSET && s_cur.scrolling && s_cur.next_frame_us && now >= s_cur.next_frame_us) {
        strip_frame();
        return;
    }
    if (s_cur.kind == CUR_ASSET && s_cur.next_frame_us && now >= s_cur.next_frame_us) {
        on_frame_due();
        return;
    }
    if (s_cur.kind == CUR_BOARD && s_cur.next_tick_us && now >= s_cur.next_tick_us) {
        board_tick();
        return;
    }
    if (s_cur.kind == CUR_BOARD && s_cur.next_frame_us && now >= s_cur.next_frame_us) {
        board_frame();
    }
}

/* ------------------------------------------------------------------ command handling */

static void handle(const cmd_t *c);

/* Leave the frozen state (player_release_files): restart the current item (its files are reopened) and
 * replay the commands that were deferred meanwhile. */
static void unfreeze(bool restart)
{
    if (!s_frozen) return;
    s_frozen = false;
    s_frozen_until_us = 0;
    if (restart) {
        s_rd.keep_pause = true;
        restart_current(false);
        s_rd.keep_pause = false;
    }
    const int n = s_deferred_n;
    s_deferred_n = 0;
    for (int i = 0; i < n; i++) handle(&s_deferred[i]);
}

/* CMD_RELEASE: close the files the current item streams from if they are asset/text `id`. */
static bool release_files(const char *id, bool text)
{
    bool hit = false;
    if (!text && s_cur.kind == CUR_ASSET && s_cur.fd >= 0 && strcmp(s_cur.item.id, id) == 0) {
        close(s_cur.fd);
        s_cur.fd = -1;
        hit = true;
    } else if (!text && s_cur.kind == CUR_ORACLE) {
        for (int i = 0; i < OR_ASSETS; i++) {   /* only open during a shuffle */
            if (s_or.f[i].fd >= 0 && strcmp(s_or.ids[i], id) == 0) hit = true;
        }
        if (hit) or_close_files();
    } else if (text && s_cur.kind == CUR_READER && s_rd.active && s_rd.fd_txt >= 0 && strcmp(s_rd.info.id, id) == 0) {
        reader_save();
        reader_close_files();
        hit = true;
    }
    if (hit) {
        s_frozen = true;
        s_frozen_until_us = esp_timer_get_time() + FREEZE_MAX_US;
        ESP_LOGI(TAG, "%s %s replaced/deleted while on screen: frozen until reload", text ? "text" : "asset", id);
    }
    return hit;
}

/* CMD_FORGET (POST /erase): let go of every stored file and of everything that names stored content, and show the
 * idle screen. The playlist is emptied here in RAM, not re-read: the caller removes the files only after this, and
 * nothing may reopen one meanwhile (with an empty playlist and no override there is nothing to start). */
static void forget_content(void)
{
    s_deferred_n = 0;            /* deferred commands (a /show, a press) would reopen files */
    s_frozen = s_reload_frozen = false;
    s_frozen_until_us = 0;
    s_pending_show = false;
    close_current();             /* a reading saves its position here: erased with the rest */
    s_cur.override = false;
    s_rd.held_text[0] = s_rd.paused_text[0] = '\0';
    reader_font_unload();
    s_pl->count = s_pl->queue_count = 0;
    sched_reload();              /* empty queue: the done-set is forgotten as well */
    s_index = -1;
    show_idle();
    ESP_LOGI(TAG, "content erased: idle");
}

/* POST /show of a strip: the scroll it was given, else the first playlist item (then queue entry)
 * showing that asset with a scroll, else the default scroll. Without any, a shown strip would be a
 * still of its first 536 px (PROTOCOL §4 says so for playlist items without `scroll`). */
static void show_scroll(pl_item_t *it, const pl_scroll_t *given)
{
    asset_info_t info;
    if (!storage_asset_find(it->id, &info) || !info.strip) return;   /* scroll only acts on strips */
    const char *from = "the request";
    if (given->on) {
        it->scroll = *given;
    } else {
        from = NULL;
        for (size_t i = 0; i < s_pl->count && !from; i++) {
            const pl_item_t *p = &s_pl->items[i];
            if (p->type == PL_ITEM_ASSET && p->scroll.on && strcmp(p->id, it->id) == 0) {
                it->scroll = p->scroll;
                from = "its playlist item";
            }
        }
        for (size_t i = 0; i < s_pl->queue_count && !from; i++) {
            const pl_item_t *p = &s_pl->queue[i].item;
            if (p->type == PL_ITEM_ASSET && p->scroll.on && strcmp(p->id, it->id) == 0) {
                it->scroll = p->scroll;
                from = "its queue entry";
            }
        }
        if (!from) {
            it->scroll = (pl_scroll_t){ .on = true, .gap_px = PL_SCROLL_DEF_GAP, .loops = 1,
                                        .mpx_per_s = PL_SCROLL_DEF_PX_S * 1000u };
            from = "the default";
        }
        it->scroll.loops_set = false;   /* borrowed scroll: the show lasts its duration (as PixelClipKit's showScroll) */
    }
    ESP_LOGI(TAG, "show %s: strip scroll from %s (%.1f px/s %s, gap %u%s)", it->id, from,
             (double)it->scroll.mpx_per_s / 1000.0, it->scroll.right ? "right" : "left", it->scroll.gap_px,
             it->scroll.loops_set ? ", loops given" : "");
}

/* ------------------------------------------------------------------ reload (uploads, deletes, PUT /playlist) */

static const char *const s_reload_kind_names[] = { "reload", "playlist", "asset", "text", "font" };

/* Is asset `id` one of the atlases of the cached font `c`? */
static bool fontc_has_atlas(const fontc_t *c, const char *id)
{
    if (!c->font || !id[0]) return false;
    const rsvp_font_t *f = c->font;
    const char *ids[4] = { f->normal.atlas_white, f->normal.atlas_accent, f->compact.atlas_white, f->compact.atlas_accent };
    const int n = f->has_compact ? 4 : 2;
    for (int i = 0; i < n; i++) {
        if (strcmp(ids[i], id) == 0) return true;
    }
    return f->large_bound && (strcmp(f->large.atlas_white, id) == 0 || strcmp(f->large.atlas_accent, id) == 0);
}

/* Does the change touch font cache `c` (its document or one of its atlases)? */
static bool fontc_touched(const fontc_t *c, player_reload_kind_t k, const char *id)
{
    if (!c->font) return false;
    return (k == PLAYER_RELOAD_FONT && strcmp(c->id, id) == 0) || (k == PLAYER_RELOAD_ASSET && fontc_has_atlas(c, id));
}

static const char *cur_kind_name(void)
{
    switch (s_cur.kind) {
    case CUR_IDLE: return "idle";
    case CUR_ASSET: return s_cur.strip ? "strip" : "asset";
    case CUR_SCENE: return "scene";
    case CUR_READER: return "reader";
    case CUR_ORACLE: return "oracle";
    case CUR_BOARD: return "board";
    default: return "none";
    }
}

/* Does the change concern the content on screen (its files / documents)? Fills `why` when it does. */
static bool reload_touches_content(player_reload_kind_t k, const char *id, bool deleted, bool frozen, char *why, size_t n)
{
    const char *op = deleted ? "delete" : "upload";
    if (frozen) {   /* release_files() closed the item's file for this very change */
        snprintf(why, n, "%s %s (its file)", op, id);
        return true;
    }
    switch (s_cur.kind) {
    case CUR_NONE:
    case CUR_IDLE:
        /* the change may have made something playable: (re)start the rotation (cheap: no content runs) */
        snprintf(why, n, "%s%s%s on the idle screen", s_reload_kind_names[k], id[0] ? " " : "", id);
        return true;
    case CUR_ASSET:
        if (k == PLAYER_RELOAD_ASSET && strcmp(s_cur.item.id, id) == 0) {
            snprintf(why, n, "%s %s", op, id);
            return true;
        }
        break;
    case CUR_BOARD:
        if (k == PLAYER_RELOAD_ASSET && strcmp(s_cur.item.id, id) == 0) {
            snprintf(why, n, "%s %s (board sheet)", op, id);
            return true;
        }
        break;
    case CUR_ORACLE:
        for (int i = 0; i < OR_ASSETS && k == PLAYER_RELOAD_ASSET; i++) {
            if (s_or.ids[i][0] && strcmp(s_or.ids[i], id) == 0) {
                snprintf(why, n, "%s %s (oracle asset)", op, id);
                return true;
            }
        }
        /* §5f.2: the bundle draws every text screen and the paragraph, the fonts draw them: any change restarts */
        if ((k == PLAYER_RELOAD_TEXT && strcmp(s_cur.item.id, id) == 0) ||
            (k == PLAYER_RELOAD_FONT && (strcmp(s_or.cfg.font, id) == 0 || (s_or.cfg.font_big[0] &&
                                                                           strcmp(s_or.cfg.font_big, id) == 0))) ||
            (k == PLAYER_RELOAD_ASSET && (fontc_has_atlas(&s_orr.fc, id) || fontc_has_atlas(&s_orr.fcb, id)))) {
            snprintf(why, n, "%s %s (oracle bundle / font)", op, id);
            return true;
        }
        break;
    case CUR_READER:
        if (k == PLAYER_RELOAD_TEXT && strcmp(s_cur.item.id, id) == 0) {
            snprintf(why, n, "%s text %s", op, id);
            return true;
        }
        if (k == PLAYER_RELOAD_FONT && strcmp(s_cur.item.font, id) == 0) {
            snprintf(why, n, "%s font %s", op, id);
            return true;
        }
        if (k == PLAYER_RELOAD_ASSET && fontc_has_atlas(&s_rd.fc, id)) {
            snprintf(why, n, "%s %s (reader font atlas)", op, id);
            return true;
        }
        break;
    default:   /* scenes use no stored content */
        break;
    }
    if (k == PLAYER_RELOAD_ALL) {
        snprintf(why, n, "reload");
        return true;
    }
    return false;
}

static bool same_entry(const pl_item_t *a, const pl_item_t *b)
{
    return a->json_hash != 0 && a->json_hash == b->json_hash && a->type == b->type && strcmp(a->id, b->id) == 0;
}

/* A rotation item stays on screen when the re-read playlist still has its exact entry (index updated if it
 * moved), it was not given a from_word, and whether it is the lone item did not change. */
static bool rotation_entry_kept(bool playlist_put, char *why, size_t n)
{
    const int count = (int)s_pl->count;
    int found = -1;
    if (s_index >= 0 && s_index < count && same_entry(&s_pl->items[s_index], &s_cur.item)) found = s_index;
    for (int i = 0; i < count && found < 0; i++) {
        if (same_entry(&s_pl->items[i], &s_cur.item)) found = i;
    }
    if (found < 0) {
        snprintf(why, n, "playlist entry changed or removed");
        return false;
    }
    const pl_item_t *it = &s_pl->items[found];
    if (playlist_put && it->type == PL_ITEM_READER && it->from_word > 0) {
        snprintf(why, n, "playlist sets from_word %lu", (unsigned long)it->from_word);
        return false;
    }
    if (!item_active(it)) {
        snprintf(why, n, "outside its time window");
        return false;
    }
    const bool single = active_count() <= 1;
    if (single != s_cur.single) {
        snprintf(why, n, "%s", single ? "now the lone item" : "no longer the lone item");
        return false;
    }
    if (found != s_index) {
        ESP_LOGI(TAG, "%s %s: playlist entry moved from index %d to %d (keeps playing)", cur_kind_name(),
                 item_name(&s_cur.item), s_index, found);
        s_index = found;
    }
    return true;
}

/* CMD_RELOAD (README "Uploads during playback"): re-read the playlist and restart the item on screen only
 * when the change concerns it. A scene / reader / strip / animation that has nothing to do with
 * the uploaded or deleted id keeps running (it used to restart at every upload of a sync: 9 restarts of the
 * water scene in 4 s on 2026-10-15). */
static void reload(const cmd_t *c)
{
    const player_reload_kind_t k = c->value <= PLAYER_RELOAD_FONT ? (player_reload_kind_t)c->value : PLAYER_RELOAD_ALL;
    const char *id = c->id;
    const bool deleted = c->arg != 0;
    const bool frozen = s_reload_frozen;
    s_reload_frozen = false;
    playlist_load(s_pl);
    sched_reload();

    char why[96] = "";
    bool restart = reload_touches_content(k, id, deleted, frozen, why, sizeof why);
    if (!restart && s_cur.kind != CUR_NONE && s_cur.kind != CUR_IDLE && !s_cur.override) {
        restart = !rotation_entry_kept(k == PLAYER_RELOAD_PLAYLIST, why, sizeof why);
    }
    s_rd.keep_pause = true;
    /* A reading that restarts closes first, so its saved progress cannot overwrite a from_word below. */
    if (restart && s_cur.kind == CUR_READER) close_current();
    if (k == PLAYER_RELOAD_PLAYLIST) reader_apply_from_words();
    /* Caches: drop what may be stale unless the running item uses it and keeps playing. */
    if ((k == PLAYER_RELOAD_FONT || k == PLAYER_RELOAD_ASSET || k == PLAYER_RELOAD_ALL) &&
        (k == PLAYER_RELOAD_ALL || fontc_touched(&s_rd.fc, k, id))) {
        reader_font_unload();   /* no-op while a reading uses it (then it was not touched) */
    }

    if (restart) {
        ESP_LOGI(TAG, "restart %s%s %s: reason=%s", s_cur.override ? (s_cur.queue_entry ? "queue " : "show ") : "",
                 cur_kind_name(), s_cur.kind == CUR_NONE || s_cur.kind == CUR_IDLE ? "-" : item_name(&s_cur.item), why);
        restart_current(false);
    } else {
        if (s_cur.kind != CUR_NONE) {
            ESP_LOGI(TAG, "reload (%s%s%s%s): %s %s keeps playing", deleted ? "delete " : k == PLAYER_RELOAD_PLAYLIST ?
                     "" : "upload ", s_reload_kind_names[k], id[0] ? " " : "", id, cur_kind_name(),
                     item_name(&s_cur.item));
        }
        publish_status();
    }
    s_rd.keep_pause = false;
    if (s_deferred_n) {
        s_frozen = true;   /* unfreeze() replays only from the frozen state */
        unfreeze(false);
    }
}

static void handle(const cmd_t *c)
{
    if (s_frozen) {
        switch (c->type) {
        case CMD_NEXT: case CMD_PREV: case CMD_SHOW_ASSET: case CMD_QUEUE_TEST: case CMD_TIME:
        case CMD_REFRESH: case CMD_READER: case CMD_SHOW_ITEM: case CMD_ORACLE:
            if (c->ack) {
                unfreeze(true);    /* a waiting caller: never stall it behind an upload */
                break;
            }
            /* asynchronous and would reopen files (button, controller): replay after the reload */
            if (s_deferred_n < DEFER_MAX) {
                s_deferred[s_deferred_n++] = *c;
            } else {
                ESP_LOGW(TAG, "frozen: command %d dropped", (int)c->type);
            }
            return;
        case CMD_OUTPUT:
            unfreeze(true);
            break;
        case CMD_RELOAD:
            s_frozen = false;  /* the reload below restarts the item; deferred commands follow it */
            s_reload_frozen = true;
            break;
        default:
            break;
        }
    }
    switch (c->type) {
    case CMD_NEXT:
    case CMD_PREV:
        s_rd.held_text[0] = '\0';   /* next/prev (button double press) restarts a held lone reader */
        if (s_cur.override) {
            end_override(false);
        } else {
            advance(c->type == CMD_NEXT ? +1 : -1);
        }
        break;
    case CMD_SHOW_ASSET: {
        pl_item_t it = { .type = PL_ITEM_ASSET,
                         .duration_ms = c->value, .loops = 1, .transition = APPCFG_TRANSITION_FADE,
                         .from_min = SCHED_NO_WINDOW, .until_min = SCHED_NO_WINDOW };
        strlcpy(it.id, c->id, sizeof it.id);
        show_scroll(&it, &c->scroll);
        if (!c->scroll.on) show_item_borrow(&it);
        if (s_cur.queue_entry) {
            /* A queue entry wins over /show (PROTOCOL §4): play the show after it. */
            ESP_LOGI(TAG, "show %s deferred until queue entry %s ends", item_name(&it), s_cur.queue_id);
            s_pending_item = it;
            s_pending_show = true;
        } else {
            start_override(&it);
        }
        break;
    }
    case CMD_SHOW_ITEM: {
        xSemaphoreTake(s_status_mutex, portMAX_DELAY);
        pl_item_t it = s_show_req;
        xSemaphoreGive(s_status_mutex);
        it.duration_ms = c->value;
        it.transition = APPCFG_TRANSITION_FADE;
        it.from_min = it.until_min = SCHED_NO_WINDOW;
        if (s_cur.queue_entry) {
            ESP_LOGI(TAG, "show %s deferred until queue entry %s ends", item_name(&it), s_cur.queue_id);
            s_pending_item = it;
            s_pending_show = true;
        } else {
            start_override(&it);
        }
        break;
    }
    case CMD_ORACLE:
        s_rd_result = or_command((int)c->value, c->arg);
        break;
    case CMD_QUEUE_TEST: {
        int qi = -1;
        for (size_t i = 0; i < s_pl->queue_count && qi < 0; i++) {
            if (strcmp(s_pl->queue[i].id, c->id) == 0) qi = (int)i;
        }
        if (qi >= 0) {
            start_queue(qi, true);
        } else {
            ESP_LOGW(TAG, "queue test: no entry %s", c->id);
        }
        break;
    }
    case CMD_TIME:
        /* Clock or timezone changed: re-apply the windows now, also offscreen during a session (so
         * GET /status and /screenshot reflect them). Queue entries still fire only from the tick. */
        if (!s_cur.override && s_has_windows &&
            (s_cur.kind == CUR_IDLE || (s_cur.kind != CUR_NONE && !item_active(&s_cur.item)))) {
            advance(0);
        }
        break;
    case CMD_READER: {
        esp_err_t r = ESP_OK;
        if (s_cur.kind != CUR_READER || !s_rd.active) {
            r = ESP_ERR_INVALID_STATE;
        } else if (c->value == PLAYER_READER_PAUSE) {
            reader_set_paused(true);
        } else if (c->value == PLAYER_READER_RESUME) {
            reader_set_paused(false);
        } else if (c->value == PLAYER_READER_TOGGLE) {
            reader_set_paused(!s_rd.paused);
        } else if (c->value == PLAYER_READER_SEEK) {
            r = reader_seek(c->arg);
        } else {
            r = ESP_ERR_INVALID_ARG;
        }
        s_rd_result = r;
        break;
    }
    case CMD_RELOAD:
        reload(c);
        break;
    case CMD_BADGE:
        if ((player_badge_t)c->value != s_badge) {
            s_badge = (player_badge_t)c->value;
            s_badge_phase = 0;
            s_badge_next_us = 0;
            badge_paint();
        }
        break;
    case CMD_RELEASE:
        s_rd_result = release_files(c->id, c->value != 0) ? ESP_OK : ESP_ERR_NOT_FOUND;
        break;
    case CMD_FORGET:
        forget_content();
        s_rd_result = ESP_OK;
        break;
    case CMD_BRIGHTNESS:
        s_brightness = (uint8_t)c->value;
        if (s_output && s_cur.kind != CUR_NONE) display_set_brightness(s_brightness);
        break;
    case CMD_OUTPUT:
        fb_touched();   /* system screens painted the framebuffer meanwhile */
        if (c->value && !s_output) {
            s_output = true;
            if (s_has_windows || s_pl->queue_count) s_next_sched_us = esp_timer_get_time() + SCHED_TICK_US;
            s_rd.keep_pause = true;
            restart_current(false);
            s_rd.keep_pause = false;
            badge_paint();
        } else if (!c->value && s_output) {
            s_output = false;
            badge_paint();                                   /* output off: overlay removed */
            if (s_cur.fd >= 0) close(s_cur.fd);
            s_cur.fd = -1;
            s_cur.next_frame_us = s_cur.end_us = s_cur.next_tick_us = 0;
            if (s_cur.kind == CUR_SCENE) scene_release();   /* no CPU lock / IMU while hidden */
            if (s_cur.kind == CUR_ORACLE) {
                or_release();
                or_close_files();
            }
            if (s_cur.kind == CUR_READER) {
                reader_save();                              /* the session may end with a reboot */
                reader_close_files();
            }
            strip_release();                                 /* a session may need the PSRAM */
        }
        break;
    case CMD_ORIENT:
        orient_sync();    /* between frames: MADCTL + one full re-send of the framebuffer */
        if (s_cur.kind == CUR_ORACLE && s_output && !s_frozen && s_or.f[OR_ASSET_DECK].table &&
            s_or.shown_ok && s_or.hint_left != display_is_flipped()) {
            /* §5f.9: the hint follows the button to its corner, the three move away from it */
            or_set_flipped(&s_or.o, display_is_flipped());
            or_draw_t d;
            or_draw(&s_or.o, &d);
            or_paint(&d, true);
            if (!or_animating(&s_or.o)) or_close_files();
        }
        break;
    case CMD_REFRESH:
        fb_touched();
        s_rd.keep_pause = true;
        if (!s_output) restart_current(false);
        s_rd.keep_pause = false;
        break;
    }
    if (c->ack) xSemaphoreGive(c->ack);
}

/* Between two loop iterations the player holds no transient perf lock, and the scene / strip holds match
 * what is on screen (README "Light sleep on battery": a leaked hold keeps the CPU at 160 MHz, a missing
 * one is harmless; both mean a broken pairing somewhere). Logged; fatal in the bench build. */
static void check_perf_holds(void)
{
    static uint32_t s_reported;
#if PL_SCENES
    const int scene_expect = s_sc.perf ? 1 : 0;
#else
    const int scene_expect = 0;
#endif
    const int strip_expect = s_st.perf ? 1 : 0;
    const int or_expect = s_or.perf ? 1 : 0;
    const int orc = power_perf_held(POWER_PERF_ORACLE);
    const int tr = power_perf_held(POWER_PERF_TRANSIENT);
    const int sc = power_perf_held(POWER_PERF_SCENE);
    const int st = power_perf_held(POWER_PERF_STRIP);
    if (tr == 0 && sc == scene_expect && st == strip_expect && orc == or_expect) return;
    if (s_reported++ < 5) {
        ESP_LOGE(TAG, "PM LOCK ACCOUNTING: player holds transient=%d scene=%d (expected %d) strip=%d (expected %d) "
                 "oracle=%d (expected %d)", tr, sc, scene_expect, st, strip_expect, orc, or_expect);
    }
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST
    abort();   /* the soak must see it: a reboot is counted, the log line above says why */
#endif
}

static void player_task(void *arg)
{
    appcfg_t cfg;
    appcfg_get(&cfg);
    s_brightness = cfg.brightness;
    health_beat(HEALTH_SRC_PLAYER);
    advance(0);
    for (;;) {
        cmd_t c;
        health_beat(HEALTH_SRC_PLAYER);   /* the RTC watchdog is only fed while this keeps coming */
        check_perf_holds();
        or_hold_check();
        int64_t deadline = next_deadline();
        /* Never block forever: wake at least every HEALTH_PLAYER_MAX_WAIT_MS to beat (a no-op pass through
         * service_timers when nothing is due). Waiting on the queue with a tick timeout is what tickless idle
         * turns into a timed light sleep. */
        TickType_t wait = pdMS_TO_TICKS(HEALTH_PLAYER_MAX_WAIT_MS);
        if (deadline) {
            int64_t us = deadline - esp_timer_get_time();
            if (us < (int64_t)HEALTH_PLAYER_MAX_WAIT_MS * 1000) wait = us <= 0 ? 0 : pdMS_TO_TICKS((us + 999) / 1000);
        }
        if (xQueueReceive(s_q, &c, wait) == pdTRUE) {
            handle(&c);
        } else if (s_frozen) {
            const int64_t now = esp_timer_get_time();
            if (s_badge_next_us && now >= s_badge_next_us) badge_paint();
            if (now >= s_frozen_until_us) {
                ESP_LOGW(TAG, "frozen for %d s without a reload: restarting", FREEZE_MAX_US / 1000000);
                unfreeze(true);
            }
        } else if (s_output) {
            service_timers();
        }
    }
}

/* ------------------------------------------------------------------ public API */

static void post(cmd_type_t type, const char *id, uint32_t value)
{
    if (!s_q) return;   /* player_init() failed */
    cmd_t c = { .type = type, .value = value };
    if (id) strlcpy(c.id, id, sizeof c.id);
    if (xQueueSend(s_q, &c, pdMS_TO_TICKS(1000)) != pdTRUE) ESP_LOGE(TAG, "command queue full");
}

int player_orient_post(uint32_t wait_ms)
{
    if (!s_q) return -1;
    const cmd_t c = { .type = CMD_ORIENT };
    return xQueueSend(s_q, &c, pdMS_TO_TICKS(wait_ms)) == pdTRUE ? 1 : 0;
}

void player_next(void) { post(CMD_NEXT, NULL, 0); }
void player_prev(void) { post(CMD_PREV, NULL, 0); }
void player_show_asset(const char *id, uint32_t duration_ms) { post(CMD_SHOW_ASSET, id, duration_ms); }

void player_show_asset_scroll(const char *id, uint32_t duration_ms, const pl_scroll_t *scroll)
{
    if (!s_q) return;
    cmd_t c = { .type = CMD_SHOW_ASSET, .value = duration_ms };
    if (id) strlcpy(c.id, id, sizeof c.id);
    if (scroll) c.scroll = *scroll;
    if (xQueueSend(s_q, &c, pdMS_TO_TICKS(1000)) != pdTRUE) ESP_LOGE(TAG, "command queue full");
}

static esp_err_t post_sync(cmd_t *c);

void player_show_item(const pl_item_t *it)
{
    if (!s_q || !it) return;
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    s_show_req = *it;
    xSemaphoreGive(s_status_mutex);
    post(CMD_SHOW_ITEM, it->id, it->duration_ms);
}

void player_get_oracle(player_oracle_status_t *out)
{
    if (!s_status_mutex) {
        memset(out, 0, sizeof *out);
        out->drawn[0] = out->drawn[1] = out->drawn[2] = -1;
        out->card = -1;
        out->page = -1;
        strlcpy(out->state, "waits", sizeof out->state);
        return;
    }
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    *out = s_orstat;
    xSemaphoreGive(s_status_mutex);
}

esp_err_t player_oracle_draw(const int cards[3])
{
    uint32_t arg = 0;   /* 0 = random; else (a+1) | (b+1) << 8 | (c+1) << 16 */
    if (cards) {
        for (int i = 0; i < 3; i++) {
            if (cards[i] < 0 || cards[i] >= OR_MAX_CARDS) return ESP_ERR_INVALID_ARG;
            arg |= (uint32_t)(cards[i] + 1) << (8 * i);
        }
    }
    cmd_t c = { .type = CMD_ORACLE, .value = OR_CMD_DRAW, .arg = arg };
    return post_sync(&c);
}

esp_err_t player_oracle_turn(void)
{
    cmd_t c = { .type = CMD_ORACLE, .value = OR_CMD_TURN };
    return post_sync(&c);
}

esp_err_t player_oracle_back_sync(void)
{
    cmd_t c = { .type = CMD_ORACLE, .value = OR_CMD_BACK };
    return post_sync(&c);
}

bool player_oracle_showing(void)
{
    if (!s_status_mutex) return false;
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    const bool active = s_orstat.active;
    xSemaphoreGive(s_status_mutex);
    return active && s_output;
}

bool player_oracle_back(void)
{
    if (!player_oracle_showing()) return false;
    post(CMD_ORACLE, NULL, OR_CMD_BACK);   /* asynchronous; ignored if the item changed meanwhile */
    return true;
}

bool player_oracle_press(void)
{
    if (!s_status_mutex) return false;
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    const bool active = s_orstat.active;
    xSemaphoreGive(s_status_mutex);
    if (!active) return false;
    post(CMD_ORACLE, NULL, OR_CMD_PRESS);   /* asynchronous; if the item changed meanwhile it means "next" */
    return true;
}

void player_reload_for(player_reload_kind_t kind, const char *id, bool deleted)
{
    if (!s_q) return;
    cmd_t c = { .type = CMD_RELOAD, .value = (uint32_t)kind, .arg = deleted ? 1 : 0 };
    if (id) strlcpy(c.id, id, sizeof c.id);
    if (xQueueSend(s_q, &c, pdMS_TO_TICKS(1000)) != pdTRUE) ESP_LOGE(TAG, "command queue full");
}
void player_reload(void) { player_reload_for(PLAYER_RELOAD_ALL, NULL, false); }
void player_reload_playlist(void) { player_reload_for(PLAYER_RELOAD_PLAYLIST, NULL, false); }
void player_reader_toggle(void) { post(CMD_READER, NULL, PLAYER_READER_TOGGLE); }

void player_get_reader(player_reader_status_t *out)
{
    if (!s_status_mutex) {
        *out = (player_reader_status_t){ 0 };
        return;
    }
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    *out = s_rstat;
    xSemaphoreGive(s_status_mutex);
}

bool player_reader_active(void)
{
    player_reader_status_t r;
    player_get_reader(&r);
    return r.active;
}

/* Synchronous command: post `c` and wait (<= 2 s) for the player's s_rd_result. One caller at a time
 * (s_rd_lock); the shared ack semaphore is drained first so a late give from a timed-out call is ignored. */
static esp_err_t post_sync(cmd_t *c)
{
    if (!s_q || !s_rd_lock || !s_rd_ack) return ESP_ERR_INVALID_STATE;
    xSemaphoreTake(s_rd_lock, portMAX_DELAY);
    xSemaphoreTake(s_rd_ack, 0);
    c->ack = s_rd_ack;
    esp_err_t r;
    if (xQueueSend(s_q, c, pdMS_TO_TICKS(1000)) != pdTRUE) {
        r = ESP_ERR_TIMEOUT;
    } else if (xSemaphoreTake(s_rd_ack, pdMS_TO_TICKS(2000)) != pdTRUE) {
        r = ESP_ERR_TIMEOUT;
    } else {
        r = s_rd_result;
    }
    xSemaphoreGive(s_rd_lock);
    return r;
}

bool player_release_files(const char *asset_id, const char *text_id)
{
    bool hit = false;
    if (asset_id && asset_id[0]) {
        cmd_t c = { .type = CMD_RELEASE, .value = 0 };
        strlcpy(c.id, asset_id, sizeof c.id);
        hit |= post_sync(&c) == ESP_OK;
    }
    if (text_id && text_id[0]) {
        cmd_t c = { .type = CMD_RELEASE, .value = 1 };
        strlcpy(c.id, text_id, sizeof c.id);
        hit |= post_sync(&c) == ESP_OK;
    }
    return hit;
}

esp_err_t player_forget_content(void)
{
    cmd_t c = { .type = CMD_FORGET };
    return post_sync(&c);
}

void player_set_badge(player_badge_t badge) { post(CMD_BADGE, NULL, (uint32_t)badge); }

esp_err_t player_reader_control(player_reader_action_t action, uint32_t word)
{
    cmd_t c = { .type = CMD_READER, .value = (uint32_t)action, .arg = word };
    return post_sync(&c);
}

void player_set_brightness(uint8_t level) { post(CMD_BRIGHTNESS, NULL, level); }
void player_refresh_offscreen(void) { post(CMD_REFRESH, NULL, 0); }

void player_upload_active(bool active)
{
    /* Counted (nested / overlapping callers); only the 0 <-> 1 edges are logged. */
    static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
    int now;
    portENTER_CRITICAL(&mux);
    if (active) {
        now = ++s_uploads_rx;
    } else {
        now = s_uploads_rx > 0 ? --s_uploads_rx : 0;
    }
    portEXIT_CRITICAL(&mux);
    if (active && now == 1) ESP_LOGI(TAG, "scenes: upload in progress, 15 fps cap");
    if (!active && now == 0) ESP_LOGI(TAG, "scenes: upload done, 30 fps again");
}
void player_queue_test(const char *queue_id) { post(CMD_QUEUE_TEST, queue_id, 0); }
void player_time_changed(void) { post(CMD_TIME, NULL, 0); }

void player_set_output(bool enabled)
{
    /* One long-lived semaphore (only the controller task calls this). A per-call semaphore that is
     * deleted after a timeout would be given later by the player task = use-after-free. A late
     * give from a timed-out call is drained before the next request instead. */
    static SemaphoreHandle_t ack;
    if (!s_q) return;
    if (!ack) ack = xSemaphoreCreateBinary();
    if (!ack) {
        ESP_LOGE(TAG, "set_output: no semaphore");
        return;
    }
    xSemaphoreTake(ack, 0);
    cmd_t c = { .type = CMD_OUTPUT, .value = enabled, .ack = ack };
    if (xQueueSend(s_q, &c, pdMS_TO_TICKS(2000)) != pdTRUE) {
        ESP_LOGE(TAG, "set_output: queue full");
    } else if (xSemaphoreTake(ack, pdMS_TO_TICKS(5000)) != pdTRUE) {
        ESP_LOGE(TAG, "set_output: no ack");
    }
}

void player_get_status(player_status_t *out)
{
    if (!s_status_mutex) {
        *out = (player_status_t){ .index = -1 };
        return;
    }
    xSemaphoreTake(s_status_mutex, portMAX_DELAY);
    *out = s_status;
    xSemaphoreGive(s_status_mutex);
}

esp_err_t player_init(void)
{
    QueueHandle_t q = xQueueCreate(8, sizeof(cmd_t));
    s_status_mutex = xSemaphoreCreateMutex();
    s_rd_lock = xSemaphoreCreateMutex();
    s_rd_ack = xSemaphoreCreateBinary();
    s_pl = heap_caps_calloc(1, sizeof(playlist_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    ESP_RETURN_ON_FALSE(q && s_status_mutex && s_pl && s_rd_lock && s_rd_ack, ESP_ERR_NO_MEM, TAG, "no mem");
    playlist_load(s_pl);
    sched_reload();
    publish_status();
    publish_oracle();
    s_q = q;   /* published only once the task can consume it (API calls are no-ops before) */
    BaseType_t ok = xTaskCreate(player_task, "player", PLAYER_TASK_STACK, NULL, PLAYER_TASK_PRIO, NULL);
    if (ok != pdPASS) {
        s_q = NULL;
        ESP_LOGE(TAG, "no memory for the player task");
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
