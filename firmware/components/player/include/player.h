/* player.h — playlist state machine and renderer (PROTOCOL §4/§5).
 *
 * A single task owns the framebuffer while output is enabled: it streams .hca frames from flash
 * (one frame at a time through a PSRAM scratch buffer), paces them with per-frame durations,
 * runs cut/fade transitions and the "show now" override. All API calls are asynchronous
 * commands except player_set_output(), which blocks until the player has acknowledged.
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"
#include "playlist.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PLAYER_SHOW_DEFAULT_MS 60000  /* POST /show without duration_ms */

esp_err_t player_init(void);

void player_next(void);
void player_prev(void);
/* Play an asset now, then return to the playlist. duration_ms 0 = default. */
void player_show_asset(const char *id, uint32_t duration_ms);
/* POST /show/{id} with an optional "scroll" (playlist.h pl_scroll_t; NULL = none given). For a strip
 * without one the player uses the scroll of the first playlist item (then queue entry) showing that
 * asset, else the default scroll (80 px/s, left, gap 0). A shown strip without duration_ms scrolls
 * for PLAYER_SHOW_DEFAULT_MS (an endless tape), or plays `loops` passes when the scroll gives them. */
struct pl_scroll;
void player_show_asset_scroll(const char *id, uint32_t duration_ms, const struct pl_scroll *scroll);
/* POST /show/{id} with an item body ("type":"oracle", playlist_parse_show_item): play `it` now,
 * then return to the playlist. duration_ms 0 = PLAYER_SHOW_DEFAULT_MS. A POST /show/{id} without a body shows an
 * asset that a playlist (then queue) oracle item uses as that item (its own fields). */
void player_show_item(const pl_item_t *it);
/* Play queue[] entry `queue_id` now (POST /queue/test, development aid): same as when it comes due,
 * but it is not marked done and ignores the clock. Unknown ids are ignored. */
void player_queue_test(const char *queue_id);
/* The wall clock or tz offset changed (POST /time, PUT /config): re-apply time windows now. */
void player_time_changed(void);
/* What changed in storage (player_reload_for). The player re-reads playlist.json, then restarts the item
 * on screen ONLY when the change concerns it (README "Uploads during playback"): an upload / delete of the
 * asset, text or font it uses (an animation's or strip's asset, a reader item's text, font or font
 * atlases), or a PUT /playlist that
 * changed or removed its own entry (whole JSON object compared, scroll / params / windows included; a moved
 * identical entry only updates the index), gave it a from_word, or changed whether it is the lone item.
 * Scenes are never restarted by uploads. Each decision is logged:
 *   `player: restart scene water: reason=playlist entry changed or removed`
 *   `player: reload (upload font serif-x-n): scene water keeps playing` */
typedef enum {
    PLAYER_RELOAD_ALL,        /* unknown change: restart the current item (fallback) */
    PLAYER_RELOAD_PLAYLIST,   /* PUT /playlist (reader items with from_word > 0 also set their progress) */
    PLAYER_RELOAD_ASSET,      /* asset `id` stored / replaced (deleted = true: removed) */
    PLAYER_RELOAD_TEXT,       /* reader text `id` */
    PLAYER_RELOAD_FONT,       /* reader font document `id` */
} player_reload_kind_t;
void player_reload_for(player_reload_kind_t kind, const char *id, bool deleted);
/* = player_reload_for(PLAYER_RELOAD_ALL, NULL, false) */
void player_reload(void);
/* = player_reload_for(PLAYER_RELOAD_PLAYLIST, NULL, false) */
void player_reload_playlist(void);
/* Live brightness (0..255): applied immediately when output is on, else on resume. */
void player_set_brightness(uint8_t level);

/* false: stop touching the panel/framebuffer (returns once idle) — used for system screens and
 * upload mode. true: restart the current item on the (already awake) panel, fading in. */
void player_set_output(bool enabled);
/* While output is disabled: render the current item's first frame into the framebuffer without
 * flushing (so GET /screenshot shows what will play). */
void player_refresh_offscreen(void);
/* An upload body is being received and stored (http_api.c: PUT /assets, /texts; nested calls counted).
 * While one is, live scenes run at 15 fps instead of 30 (README "Session-time safety": scene + WiFi RX +
 * flash writes is the heaviest mix for CPU, PSRAM bandwidth and the QSPI flush interrupts); the rest of a
 * session runs at full rate. Takes effect at the next frame; non-blocking, any task. */
void player_upload_active(bool active);

/* Upload-session connection indicator: a 6x6 dot in the brand accent colour in the top-right corner,
 * drawn as a display overlay (never into the framebuffer, so GET /screenshot shows the content only).
 * STEADY = hotspot up, waiting for a client; PULSE = a client is connected (fades 25..100 % over
 * 1.6 s). Visible only while the player owns the panel (output enabled). */
typedef enum { PLAYER_BADGE_OFF, PLAYER_BADGE_STEADY, PLAYER_BADGE_PULSE } player_badge_t;
void player_set_badge(player_badge_t badge);

/* Screen-on upload sessions: an upload is about to replace (rename over) or delete asset `asset_id` /
 * text `text_id` (either may be NULL). LittleFS refuses to unlink or rename an open file, so if the item
 * on screen streams from that file (an animation's .hca, a reader item's text + index) the player
 * closes it and freezes on the frame it shows. Returns true when it did: the caller must then call
 * player_reload_for() with that id (also on failure) to unfreeze; the player also unfreezes by itself after 30 s.
 * Blocks until the player has acted (<= 2 s). */
bool player_release_files(const char *asset_id, const char *text_id);

/* POST /erase, before any file is removed: the player closes whatever it shows, forgets the playlist, the queue, a
 * pending /show and its cached fonts and decks, and shows the idle screen (offscreen while the panel is off). Nothing
 * of the stored content is open or referenced afterwards. Blocks until the player has acted (<= 2 s); ESP_ERR_TIMEOUT
 * when it did not answer (then nothing may be removed). */
esp_err_t player_forget_content(void);

/* ---- Oracle (PROTOCOL §5f) ---- */

#define PLAYER_ORACLE_READING_MAX 900   /* = ORR_TEXT_MAX (core oracle_reader.h, PROTOCOL §5f.1) */

typedef struct {
    bool active;            /* an oracle item is the current item */
    char id[33];            /* its bundle */
    uint16_t cards;
    char state[12];         /* "waits" | "shuffle" | "three" | "short" | "thread" | "reading" | "reading-out" | "hold" */
    int16_t drawn[3];       /* A, B, C (from "three" on), -1 = none */
    int16_t card;           /* the card whose reading shows, -1 = none */
    int8_t page;            /* reading / paragraph page, the short screen (0..2), -1 = none */
    char reading[PLAYER_ORACLE_READING_MAX + 1];   /* the short screen's text ("short") / the paragraph ("reading-out") */
} player_oracle_status_t;
void player_get_oracle(player_oracle_status_t *out);
/* POST /oracle/draw: a draw now (PROTOCOL §5f.6): `cards` forces the row (three distinct indices < cards), NULL =
 * random. POST /oracle/turn: a turn like a press (draws in waits, nothing during the shuffle). Both wait (<= 2 s) for
 * the player. ESP_ERR_INVALID_STATE: no oracle on screen (none current or the panel is off); ESP_ERR_INVALID_ARG: a
 * bad forced row; ESP_ERR_TIMEOUT: player busy. */
esp_err_t player_oracle_draw(const int cards[3]);
esp_err_t player_oracle_turn(void);
/* BOOT short press (app_main): true when an oracle item is the current item and the press is its own (draw / turn):
 * the press is then not "next". Non-blocking. */
bool player_oracle_press(void);
/* §5f.3: a double tap while an oracle shows = the previous screen (non-blocking; false when no oracle shows). */
bool player_oracle_back(void);
/* POST /oracle/back: the previous screen, waits (<= 2 s) for the player; errors as player_oracle_turn. */
esp_err_t player_oracle_back_sync(void);
/* An oracle item is on screen (the panel on): the button's taps are its own (§5f.3). */
bool player_oracle_showing(void);

typedef struct {
    size_t count;        /* playlist items */
    int index;           /* current playlist index, -1 if empty */
    char current[48];    /* asset id, "scene:<id>", "reader:<text id>", "oracle:<asset id>",
                          * or "" when idle */
    bool override;       /* a "show now" item or a queue entry is playing */
} player_status_t;
void player_get_status(player_status_t *out);

/* ---- Reader mode (PROTOCOL §5c) ---- */

typedef enum {
    PLAYER_READER_PAUSE,
    PLAYER_READER_RESUME,
    PLAYER_READER_TOGGLE,
    PLAYER_READER_SEEK,     /* show word `word` (0-based) now */
} player_reader_action_t;

typedef struct {
    bool active;            /* a reader item is the current item */
    char text[33], font[33];
    char title[64];
    uint32_t word;          /* index of the word on screen (0-based) */
    uint32_t words;
    bool paused;
    bool end_card;          /* the "fin" card is showing */
    uint16_t wpm;
} player_reader_status_t;

void player_get_reader(player_reader_status_t *out);
bool player_reader_active(void);
/* Apply an action and wait (<= 2 s) for the player. ESP_ERR_INVALID_STATE: no reader item is on;
 * ESP_ERR_INVALID_ARG: seek beyond the last word; ESP_ERR_TIMEOUT: player busy. Works offscreen too
 * (during a session the change shows when the panel comes back). */
esp_err_t player_reader_control(player_reader_action_t action, uint32_t word);
/* Button: pause/resume without waiting (ignored when no reader item is on). */
void player_reader_toggle(void);

#ifdef __cplusplus
}
#endif
