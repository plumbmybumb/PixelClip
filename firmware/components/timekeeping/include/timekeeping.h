/* timekeeping.h — wall clock set by the phone (POST /time).
 *
 * The board has no RTC chip and no 32 kHz crystal, so system time runs from the ESP32-S3 RTC timer
 * (internal oscillator; minutes/day drift possible). Policy:
 *  - the last sync epoch, tz offset and a boot counter are persisted in NVS;
 *  - `synced` is true only if time was set since the last power-on / deep-sleep wake (software
 *    resets keep the RTC counting, so they keep trust) AND the last sync is < 24 h old.
 *  - a time **anchor** (the device's wall clock, unix seconds) is persisted every
 *    TIMEKEEPING_ANCHOR_PERIOD_S while the time is known (synced or approximate), at the end of an
 *    upload session and on deep-sleep entry. At boot without trust, if an anchor exists the clock is
 *    rebuilt from it: the RTC time when it is plausible (deep-sleep wake / software reset: it kept
 *    counting), else anchor + time since boot (power-on: the device is assumed to have been off for
 *    ~0 s). Such a clock is **approximate**: what is shown may use it, but not the queue or time
 *    windows (those need `synced`).
 *  - `approximate` = the time is known but not synced (rebuilt from the anchor, or a sync older than
 *    24 h). Unknown = neither (no anchor ever saved): the clock reads 1970.
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define TIMEKEEPING_MAX_SYNC_AGE_S (24 * 3600)
#define TIMEKEEPING_ANCHOR_PERIOD_S 60

/* Requires nvs_flash_init(). Increments the persisted boot counter; applies the anchor (see above). */
esp_err_t timekeeping_init(void);

/* Set wall clock (unix seconds) and tz offset; persists both (and the anchor). Clears `approximate`. */
esp_err_t timekeeping_set(int64_t epoch, int32_t tz_offset_s);
esp_err_t timekeeping_set_tz(int32_t tz_offset_s);
int32_t timekeeping_tz(void);

int64_t timekeeping_now(void);        /* unix seconds (may be wrong if !synced) */
int64_t timekeeping_now_us(void);     /* unix microseconds */
bool timekeeping_synced(void);        /* set by the phone, continuously since, < 24 h ago */
bool timekeeping_known(void);         /* synced or approximate: the wall clock is a real date */
bool timekeeping_approximate(void);   /* known && !synced */
/* Seconds the clock has been free-running from its last reference (the anchor it was rebuilt from,
 * or the aged-out sync); -1 when not approximate. */
int64_t timekeeping_anchor_age_s(void);
uint32_t timekeeping_boot_count(void);

/* ---- How the clock was rebuilt at boot, and the RTC run ----
 * The RTC run id is persisted in NVS ("rtc_run") and bumped at every boot whose RTC count was lost (power-on, the
 * RST key on CHIP_PU, an RTC-clearing reset): every boot of one run shares one continuous RTC count, so one exact set
 * corrects the whole run by the same delta. Optional hooks for other projects that reuse this component: this
 * firmware does not call them. */
#define TIMEKEEPING_HOW_NONE   0   /* no clock (1970) */
#define TIMEKEEPING_HOW_RTC    1   /* the RTC kept counting (trusted, or approximate since the anchor) */
#define TIMEKEEPING_HOW_ANCHOR 2   /* the RTC was lost: anchor + uptime */
uint32_t timekeeping_rtc_run(void);
int timekeeping_rebuilt_how(void);                 /* TIMEKEEPING_HOW_* */
const char *timekeeping_rebuilt_how_str(void);     /* "none", "rtc", "anchor" */
int64_t timekeeping_boot_anchor_age_s(void);       /* at boot: seconds since the anchor it was rebuilt from; -1 n/a */
typedef struct {
    bool valid;                 /* timekeeping_set() ran in this boot */
    uint32_t run;               /* the rtc_run it ran in */
    uint32_t prev_run;          /* the rtc_run of the exact set before it (0 = none recorded) */
    bool correction_known;      /* the clock was known before the set */
    int64_t correction_s;       /* new - old clock (seconds the device was behind) */
} timekeeping_set_info_t;
/* The last timekeeping_set() of this boot; false (and *out zeroed) when none. Any task. */
bool timekeeping_last_set(timekeeping_set_info_t *out);

/* Persist the anchor (now + tz) if the time is known. Called at session end and deep-sleep entry. */
esp_err_t timekeeping_save_anchor(void);
/* Periodic: saves the anchor every TIMEKEEPING_ANCHOR_PERIOD_S while the time is known. Returns the
 * milliseconds until it wants to run again (call from a task that can write NVS). */
uint32_t timekeeping_service(void);

#ifdef __cplusplus
}
#endif
