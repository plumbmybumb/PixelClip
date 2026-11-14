/* timekeeping_rule.h — the boot-time clock decision of timekeeping_init(), pure (no ESP-IDF, so it can be
 * host-tested).
 *
 * Inputs: the class of the reset, the persisted trust bit and anchor, the RTC-backed system time and the uptime.
 * Output: whether the clock stays trusted, how it was rebuilt (kept by the RTC, or anchor + uptime), whether that
 * starts a new RTC run (`rtc_run`, see timekeeping.h) and the anchor age.
 *
 * `keep_more` (Kconfig TIMEKEEPING_KEEP_RTC_MORE, default n: this firmware keeps its old rule) adds ESP_RST_USB and
 * ESP_RST_JTAG to the resets that keep trust, and a deep-sleep wake when the sleep (RTC now - the anchor saved at
 * sleep entry) was shorter than TK_RULE_DEEPSLEEP_TRUST_S; a longer sleep turns the clock approximate (RC drift)
 * but stays in the same RTC run, so the next exact set re-dates it. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TK_RULE_EPOCH_MIN          1577836800LL      /* 2020-01-01: anything earlier is not a real clock */
#define TK_RULE_EPOCH_MAX          4102444800LL      /* 2100-01-01 */
#define TK_RULE_ANCHOR_SLACK_S     60                /* TIMEKEEPING_ANCHOR_PERIOD_S: the RTC may sit this far before it */
#define TK_RULE_ANCHOR_MAX_GAP_S   (400LL * 86400)   /* RTC time this far past the anchor is not plausible */
#define TK_RULE_DEEPSLEEP_TRUST_S  (1LL * 3600)      /* keep_more: a deep sleep shorter than this keeps trust (RC
                                                       * drift 1 to 5 %: at most 3 min; core review 2026-11-07) */

typedef enum {
    TK_RST_KEEPS = 0,     /* software reset, panic, task / int / other watchdogs that keep the RTC domain */
    TK_RST_KEEPS_EXT,     /* ESP_RST_USB, ESP_RST_JTAG: core resets, the RTC keeps counting */
    TK_RST_DEEPSLEEP,     /* deep-sleep wake: the RTC kept counting on the RC slow clock */
    TK_RST_LOST,          /* power-on (also the RST key on CHIP_PU), brownout, RTC-clearing watchdogs, unknown */
} tk_rst_class_t;

typedef enum {
    TK_HOW_NONE = 0,      /* no clock: no trust and no anchor (reads 1970) */
    TK_HOW_RTC = 1,       /* the RTC time was kept (trusted, or approximate but counting since the anchor) */
    TK_HOW_ANCHOR = 2,    /* the RTC was lost: the clock was rebuilt as anchor + uptime (the off time is lost) */
} tk_how_t;

typedef struct {
    tk_rst_class_t rst;
    bool keep_more;       /* Kconfig TIMEKEEPING_KEEP_RTC_MORE */
    bool trusted_nvs;     /* the persisted trust bit (a sync happened and nothing broke continuity since) */
    int64_t anchor;       /* the persisted anchor epoch (0 = none) */
    int64_t sys_now;      /* the RTC-backed system time at boot (unix seconds) */
    int64_t uptime_us;    /* esp_timer at the decision */
} tk_boot_in_t;

typedef struct {
    bool trusted;         /* the clock keeps its trust (synced while the last sync is < 24 h old) */
    bool from_anchor;     /* approximate: rebuilt from the anchor (either way) */
    bool set_clock;       /* settimeofday(set_epoch_s, set_usec) */
    int64_t set_epoch_s;
    int64_t set_usec;
    tk_how_t how;
    bool new_run;         /* the RTC run broke: bump rtc_run */
    int64_t anchor_age_s; /* seconds since the anchor the clock was rebuilt from; -1 when trusted or no clock */
} tk_boot_out_t;

void timekeeping_rule_boot(const tk_boot_in_t *in, tk_boot_out_t *out);
/* "none", "rtc", "anchor" */
const char *timekeeping_how_str(tk_how_t how);

#ifdef __cplusplus
}
#endif
