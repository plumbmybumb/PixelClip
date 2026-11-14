/* playlist.h — playlist document (PROTOCOL §4 "Playlist JSON" + "Scheduling"), stored as
 * /playlist.json. The stored file is the JSON the app sent (validated); GET returns it verbatim, so
 * keys the firmware does not interpret survive a round trip. */
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "esp_err.h"
#include "appcfg.h"
#include "sched.h"

/* Live scenes: the playlist can carry scene items when core/ provides the scene engine. CMake
 * defines PIXELCLIP_HAVE_SCENES=1 when core/src/scene.c is present (see player/CMakeLists.txt). */
#if defined(PIXELCLIP_HAVE_SCENES) && PIXELCLIP_HAVE_SCENES && __has_include("scene.h")
#include "scene.h"
#define PL_SCENES 1
#else
#define PL_SCENES 0
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define PLAYLIST_MAX_ITEMS 128
#define PLAYLIST_MAX_QUEUE SCHED_QUEUE_MAX
#define PLAYLIST_MAX_BYTES 16384
#define PLAYLIST_SCENE_DEFAULT_MS 60000   /* scene item with duration_ms 0 */

/* `scroll` on an asset item (PROTOCOL §4 "Scrolling strips"). Applies only when the asset is a strip
 * (is_strip); ignored for other content. */
#define PL_SCROLL_MIN_PX_S   10
#define PL_SCROLL_MAX_PX_S   400
#define PL_SCROLL_MAX_GAP    2000
#define PL_SCROLL_DEF_PX_S   80
#define PL_SCROLL_DEF_GAP    0
typedef struct pl_scroll {
    bool on;                     /* the item has a "scroll" object */
    bool right;                  /* direction "right" (content moves right, enters from the left) */
    uint16_t gap_px;             /* black between repeats, 0..2000 */
    uint16_t loops;              /* passes, >= 1 (ignored when duration_ms > 0) */
    bool loops_set;              /* "loops" was given (a /show without duration_ms then plays them) */
    uint32_t mpx_per_s;          /* speed in milli-pixels per second (10..400 px/s, fractions kept) */
} pl_scroll_t;

typedef enum { PL_ITEM_ASSET, PL_ITEM_CLOCK, PL_ITEM_TEXT, PL_ITEM_SCENE, PL_ITEM_READER,
               PL_ITEM_ORACLE, PL_ITEM_BOARD } pl_item_type_t;

/* Board items (PROTOCOL §5g): {"type":"board","id":"<sheet>","header":0,"empty":1,"rows":[{"frame":2,"until":t},…],
 * "scroll_px_s":16}; queue entries name the sheet "asset". The sheet: an .hca of 1..48 frames of w x h (w <= 536,
 * 16 <= h <= 240, N*w*h <= 1 048 576 px), not a strip. rows 1..47, frame 0..N-1, until optional integer unix seconds
 * (0..4294967295); header / empty optional frames; scroll_px_s 4..60 (default 16). */
#define PL_BOARD_MAX_ROWS   47
#define PL_BOARD_MAX_FRAMES 48
#define PL_BOARD_MAX_PX     1048576u
typedef struct {
    uint8_t nrows;
    int8_t header, empty;                  /* frame or -1 */
    uint8_t speed;                         /* px/s */
    uint64_t has_until;                    /* bit i: row i has an until */
    uint8_t frame[PL_BOARD_MAX_ROWS];
    uint32_t until[PL_BOARD_MAX_ROWS];     /* unix seconds */
} pl_board_t;

/* Oracle items (PROTOCOL §5f, §5f.2, §5f.6, §5f.7, §5f.10): {"type":"oracle","id":"<reader bundle, a /texts id>",
 * "deck":"<D>","font":"<body font>","cards":22,"shake_g":0.9}. Queue entries name the bundle "asset". The clip draws the
 * prompt, the lean screens and the details from the bundle with the font. id: a stored text (422 unknown_text) with a
 * [prompt] line and card.<i>.reading for every card i < cards (422 invalid_playlist otherwise); "reader": accepted for
 * one release, must equal id; "font" required (a /fonts id, 422 unknown_font); "font_big" optional (unused); "notes",
 * "pages", "mode" and "daily" are accepted and ignored. cards integer 3..78; deck required: D 108x206 glyph atlas
 * (§5f.12), 1 + cards frames; keys optional: K 160x34 atlas, cards frames (absent: no keyword row). shake_g 0.4..2.0; face_ms / page_ms (default 0 = only by
 * hand) / hold_ms (the idle timeout back to waits, default 300000, 0 = never) integers 0..86400000 (§5f.3). */
#define PL_OR_MAX_CARDS     78
#define PL_OR_MIN_CARDS     3
#define PL_OR_MAX_PAGES     3
#define PL_OR_BUNDLE_MAX    (96 * 1024)   /* bytes of a reader bundle (§5f.2: ~80 KB) */
#define PL_OR_FACE_DEF_MS   0u        /* §5f.3: paged by hand; non-zero values still auto-advance */
#define PL_OR_PAGE_DEF_MS   0u
#define PL_OR_HOLD_DEF_MS   300000u   /* the idle timeout back to waits (0 = never) */
#define PL_OR_SHAKE_MIN     0.4
#define PL_OR_SHAKE_MAX     2.0
#define PL_OR_SHAKE_DEF     0.9f
typedef struct {
    uint16_t cards;
    uint8_t pages;
    float shake_g;
    uint32_t face_ms, page_ms, hold_ms;
    char deck[33], keys[33];              /* asset ids (keys "" = none: no keyword row, §5f.12) */
    char reader[33];                      /* the bundle (= the item's id) */
    char font[33], font_big[33];          /* body font (required), numeral font ("" = the body font) */
} pl_oracle_t;

/* Reader items (PROTOCOL §5c): {"type":"reader","text":"id","font":"id","wpm":300,"from_word":0,"loop":false,
 * "duration_ms":0}. wpm PL_READER_WPM_MIN..MAX (default 300). */
#define PL_READER_WPM_MIN 50
#define PL_READER_WPM_MAX 1500
#define PL_READER_WPM_DEF 300

typedef struct {
    pl_item_type_t type;
    char id[33];                 /* asset id (PL_ITEM_ASSET, PL_ITEM_ORACLE), scene id (PL_ITEM_SCENE) or text id (PL_ITEM_READER) */
    uint32_t duration_ms;        /* 0 = loops (animations) / 5 s (stills) / 60 s (scene) */
    uint16_t loops;              /* >= 1 */
    appcfg_transition_t transition;
    int16_t from_min, until_min; /* local time-of-day window in minutes, SCHED_NO_WINDOW = none */
    bool missing;                /* stored document references something that is gone: never plays */
    pl_scroll_t scroll;          /* asset items: optional scrolling (strips only) */
    char font[33];               /* reader items: font id */
    uint16_t wpm;                /* reader items: words per minute */
    bool loop;                   /* reader items: start again after the end card instead of moving on */
    uint32_t from_word;          /* reader items: > 0 = start there (applied when the playlist is PUT) */
    bool has_seed;               /* scene items: "seed" given (deterministic), else esp_random() */
    char sheet[33];              /* scene "words" (§5b.1): the sheet asset (items / show: "id", queue entries: "asset") */
    uint32_t seed;
    pl_oracle_t orc;             /* oracle items */
    pl_board_t board;            /* board items (§5g); `id` is the sheet */
    uint32_t json_hash;          /* hash of the item's whole JSON object (every key, also ones the firmware
                                    ignores; key order does not matter), never 0 for a parsed item: the player
                                    keeps an item playing across a PUT /playlist when its entry is unchanged */
#if PL_SCENES
    scene_params_t params;       /* scene items: the known parameters, validated */
#endif
} pl_item_t;

typedef struct {
    char id[SCHED_ID_MAX + 1];
    int64_t at;                  /* unix seconds */
    pl_item_t item;              /* duration_ms already defaulted (SCHED_DEFAULT_MS) */
} pl_queue_entry_t;

typedef struct {
    size_t count;
    pl_item_t items[PLAYLIST_MAX_ITEMS];
    size_t queue_count;          /* sorted by `at` (stable) */
    pl_queue_entry_t queue[PLAYLIST_MAX_QUEUE];
} playlist_t;

typedef enum {
    PL_OK = 0,
    PL_ERR_JSON,           /* not JSON / wrong shape -> 400 bad_json */
    PL_ERR_INVALID,        /* bad field values -> 422 invalid_playlist */
    PL_ERR_UNKNOWN_ASSET,  /* references a missing asset (or a glyph atlas) -> 422 unknown_asset */
    PL_ERR_UNKNOWN_SCENE,  /* scene id not in the registry (or no scene engine) -> 422 unknown_scene */
    PL_ERR_INVALID_PARAMS, /* scene params not a flat object / value out of range -> 422 invalid_params */
    PL_ERR_UNKNOWN_TEXT,   /* reader item: no such text -> 422 unknown_text */
    PL_ERR_UNKNOWN_FONT,   /* reader item: no such font -> 422 unknown_font */
} pl_status_t;

/* Parse + validate. `out` may be NULL (validate only). */
pl_status_t playlist_parse(const char *json, size_t len, playlist_t *out, char *msg, size_t msg_len);

/* Parse + validate a "scroll" object (NULL = absent: out->on stays false) with the playlist rules;
 * used by POST /show/{id}. PL_ERR_INVALID with a message on bad values. */
struct cJSON;
pl_status_t playlist_parse_scroll(const struct cJSON *scroll, pl_scroll_t *out, char *msg, size_t msg_len);

/* Parse + validate one item object with the playlist rules (POST /show/{id} with a "type":"oracle" body).
 * `id` names the asset (the path's id; the object's own "id" is ignored). */
pl_status_t playlist_parse_show_item(const struct cJSON *obj, const char *id, pl_item_t *out, char *msg, size_t msg_len);

/* Check what an oracle item uses (PROTOCOL §5f, §5f.2; cheap, no file read): the bundle text exists
 * (PL_ERR_UNKNOWN_TEXT), the fonts exist (PL_ERR_UNKNOWN_FONT), the deck (and the keys, when given) exist
 * (PL_ERR_UNKNOWN_ASSET) with their size / frame count / kind (PL_ERR_INVALID); the message names what. */
pl_status_t playlist_oracle_check(const pl_item_t *it, char *msg, size_t msg_len);

/* Persist already-validated JSON. */
esp_err_t playlist_store(const char *json, size_t len);

/* Load the stored playlist into `out` (empty playlist if missing or now invalid). */
void playlist_load(playlist_t *out);

/* Stored JSON (malloc'd, caller frees); `{"version":1,"items":[]}` if none. */
char *playlist_read_json(void);

/* Remove every item and queue entry referencing asset `id` from the stored playlist (asset items; oracle items using it
 * as their deck or keys; words scenes using it as their sheet). */
esp_err_t playlist_remove_asset(const char *id);

/* Remove every reader item and queue entry whose `key` ("text" or "font") is `id`, and the oracle items whose bundle
 * ("id" / queue "asset") or body "font" it is. */
esp_err_t playlist_remove_reader(const char *key, const char *id);

/* A stored playlist item (or queue entry) is an oracle whose bundle is `bundle_id` (POST /show/{id} without a body). */
bool playlist_oracle_uses(const char *bundle_id);
/* §5b.1 / §5g: a words scene or a board item (items "id") or queue entry ("asset") of the stored playlist uses this sheet. */
bool playlist_words_uses(const char *sheet_id);

/* Is `it` inside its time window right now? Items without a window always are; windowed items
 * need a synced clock (the device's local time is meaningless otherwise). */
bool playlist_item_in_window(const pl_item_t *it, int64_t now, int32_t tz_offset_s, bool clock_synced);

#ifdef __cplusplus
}
#endif
