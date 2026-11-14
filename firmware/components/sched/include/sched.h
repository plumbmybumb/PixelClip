/* sched.h — "tonight" scheduling (PROTOCOL §4 "Scheduling"): time-of-day windows on playlist items
 * and the one-shot queue[] of the playlist document.
 *
 * This component only knows ids, times and done-state; the content of each queue entry (asset,
 * scene, ...) lives in the player's parsed playlist at the same index. The player task calls
 * sched_poll() once per second (only while the panel shows content) and plays whatever it returns.
 *
 * Done-state (fired or skipped ids) is persisted in /queue-done.json (LittleFS, FIFO, at most
 * SCHED_DONE_MAX ids) so an entry never fires twice, across reboots too. Loading a new queue
 * forgets the done-state of ids that are not in it (PUT /playlist semantics).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SCHED_ID_MAX        40      /* queue entry id: 1..40 printable ASCII characters (0x20..0x7E) */
#define SCHED_QUEUE_MAX     64      /* entries per playlist document */
#define SCHED_DONE_MAX      128     /* remembered fired/skipped ids (FIFO) */
#define SCHED_LATE_MAX_S    600     /* an entry discovered more than 10 min late is skipped */
#define SCHED_DEFAULT_MS    60000   /* queue entry without duration_ms */
#define SCHED_NO_WINDOW     (-1)

/* ---- time-of-day windows ------------------------------------------------------------------- */

/* "HH:MM" (00:00..23:59, two digits each, also "24:00" = end of day) -> minutes since local
 * midnight. False if malformed. */
bool sched_parse_hhmm(const char *s, int16_t *minutes);

/* Is local time `now` (unix s, tz offset s) inside [from, until)? from/until in minutes or
 * SCHED_NO_WINDOW. Both absent = always active. Missing `from` = 00:00, missing `until` = 24:00.
 * from > until crosses midnight (e.g. 21:30..01:00). */
bool sched_window_contains(int16_t from, int16_t until, int64_t now, int32_t tz_offset_s);

static inline bool sched_has_window(int16_t from, int16_t until)
{
    return from != SCHED_NO_WINDOW || until != SCHED_NO_WINDOW;
}

/* ---- queue ------------------------------------------------------------------------------------ */

typedef struct {
    char id[SCHED_ID_MAX + 1];
    int64_t at;                     /* unix seconds */
} sched_slot_t;

/* Load the persisted done-set (needs storage). Never fatal: a missing/corrupt file = empty set. */
esp_err_t sched_init(void);

bool sched_id_valid(const char *id);

/* Replace the queue (slots sorted by `at`, as the playlist parser delivers them). Done ids not in
 * `slots` are forgotten (and the file rewritten if that changed anything). n <= SCHED_QUEUE_MAX. */
void sched_load(const sched_slot_t *slots, size_t n);

/* One scheduler tick. Entries with now - at > SCHED_LATE_MAX_S are marked done (skipped). Returns
 * the index of the earliest entry with at <= now <= at + SCHED_LATE_MAX_S that is not done (and
 * marks it done = fired), or -1. Nothing happens while the clock is not synced. */
int sched_poll(int64_t now, bool clock_synced);

/* Mark one entry done (e.g. it could not be played). */
void sched_mark_done(size_t idx, const char *why);

/* Index of the entry with this id in the current queue, or -1. */
int sched_find(const char *id);

/* The queue entry currently on screen (idx -1 = none); only for status reporting. */
void sched_set_active(int idx);

typedef struct {
    int pending;                    /* entries not yet fired/skipped */
    int done;                       /* entries of the current queue already fired/skipped */
    int64_t next_at;                /* `at` of the earliest pending entry, 0 = none */
    char active[SCHED_ID_MAX + 1];  /* id of the entry on screen, "" = none */
} sched_status_t;
void sched_get_status(sched_status_t *out);

#ifdef __cplusplus
}
#endif
