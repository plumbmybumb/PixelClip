/* health.h — RTC watchdog that survives light sleep, task liveness, reset-reason accounting and
 * breadcrumbs (README "Light sleep on battery", "Liveness and the RTC watchdog").
 *
 * RTC watchdog (RWDT): clocked by the RTC slow clock, so unlike the task watchdog (timer group, stopped
 * by the light-sleep code) it can keep counting while the chip sleeps. ESP-IDF's wdt_hal_init() sets
 * "pause in sleep" for the RWDT; health_wdt_start() clears it, which is the whole point: a chip that
 * light-sleeps and never wakes is reset after CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S (stage 0: system reset,
 * keeps the RTC clock; stage 1, 5 s later: full RTC reset as a backstop).
 *
 * Feeding = a liveness bitmap. Only the controller loop feeds (it runs at priority 1, the lowest of all
 * application tasks, on CPU0, so CPU starvation alone also stops the feed), and only when every *required*
 * source has checked in within its own silence limit (health_beat()):
 *   PLAYER  30 s  required once it ever beat (the playback loop beats every pass, at least every 5 s)
 *   POWER   15 s  required once it ever beat (the power task ticks every second)
 *   HTTPD   30 s  required while a WiFi session is up: the httpd task runs a queued work item every 5 s
 *                 between requests and beats on every recv/send of a running handler
 *   TCPIP   15 s  required while a WiFi session is up: the lwIP thread runs a posted callback every 5 s
 *   BLE     30 s  required while NimBLE runs and is synced: the host task runs a posted event every 5 s
 * One silent source = no feed = a reset within CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S. Safety valve: after 3
 * consecutive liveness resets blamed on HTTPD / TCPIP / BLE (each within 10 min of boot), those three are only
 * logged, not enforced, for the rest of that boot (a broken radio must not turn into a reboot loop that also
 * takes the player down every minute); PLAYER / POWER / the controller itself stay enforced.
 *
 * Reset accounting: the boot reset reason is logged loudly (`app: ... reset reason RTCWDT_SYS ...`) and
 * counted in NVS (namespace "health"); /status reports the counters. The previous run's breadcrumbs (RTC
 * memory) are logged after EVERY reset that kept RTC memory (watchdog, panic, brownout, but also the RESET
 * button / USB reset of a wedged clip), including which source starved the watchdog, the heap at the last
 * feed, the last HTTP request, the USB state and the last light sleep.
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define HEALTH_FEED_PERIOD_MS    5000    /* the controller wakes at least this often */
#define HEALTH_PLAYER_SILENCE_S  30      /* no player beat for this long: stop feeding */
#define HEALTH_PLAYER_MAX_WAIT_MS 5000   /* the player loop wakes at least this often */
#define HEALTH_PROBE_PERIOD_MS   5000    /* httpd / tcpip / BLE probes are posted this often */

typedef enum {
    HEALTH_SRC_CONTROLLER,
    HEALTH_SRC_PLAYER,
    HEALTH_SRC_POWER,
    HEALTH_SRC_HTTPD,
    HEALTH_SRC_TCPIP,
    HEALTH_SRC_BLE,
    HEALTH_SRC_COUNT,
} health_src_t;

/* Breadcrumb steps (where the controller was last). Stored in RTC memory, reported after a WDT reset. */
typedef enum {
    HEALTH_STEP_BOOT = 0,
    HEALTH_STEP_IDLE,
    HEALTH_STEP_SESSION_START,
    HEALTH_STEP_SESSION_UP,
    HEALTH_STEP_SESSION_STOP,
    HEALTH_STEP_SESSION_STOP_HTTPD,
    HEALTH_STEP_SESSION_STOP_WIFI,
    HEALTH_STEP_SESSION_DONE,
    HEALTH_STEP_POWER_OFF,
    HEALTH_STEP_COUNT,
} health_step_t;

typedef struct {
    uint32_t wdt;        /* every watchdog reset: RTC WDT, timer-group WDT, task / interrupt WDT */
    uint32_t rtc_wdt;    /* ... of which by the RTC watchdog (the light-sleep safety net) */
    uint32_t brownout;
    uint32_t panic;
    uint32_t boots;
    char last[20];       /* reset reason of this boot, e.g. "POWERON", "RTCWDT_SYS", "PANIC" */
} health_resets_t;

/* First thing in app_main (no NVS needed): start the RTC watchdog with a generous boot timeout (a first
 * boot formats the 9.9 MB LittleFS partition), then again with CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S once the
 * controller loop feeds it. Re-arming reconfigures and feeds it. */
#define HEALTH_BOOT_TIMEOUT_S 240
void health_wdt_start(uint32_t timeout_s);
/* Stop it (deep sleep would otherwise be ended by it; OTA / esp_restart reconfigure it themselves). */
void health_wdt_stop(void);

/* After NVS init: log the reset reason (with the previous run's breadcrumbs after a watchdog reset) and
 * count it in NVS. Returns the reason name. */
const char *health_boot_record(void);

/* Safe start (valid after health_boot_record()): true when this boot follows three crashes in a row (panic or
 * any watchdog reset) that each ended a run whose last sign of life was less than 120 s after its boot. The
 * caller (app_main) then starts without the stored playlist, so that stored content which crashes the clip at
 * every boot cannot make it unreachable: the hotspot and the BLE doorbell still come up and the owner sends
 * the playlist again. It never triggers on ordinary resets (power-on, the RESET key, a USB or flashing reset,
 * the restart after an OTA, a deep-sleep wake, a brownout): each of them, and any crash of a run that lived
 * longer, ends the streak. The streak lives in RTC memory, so a power loss ends it as well. */
bool health_safe_start(void);

/* Reason of this boot, e.g. "RTCWDT_SYS" (valid after health_boot_record()). */
const char *health_reset_name(void);
void health_get_resets(health_resets_t *out);

/* Liveness. Cheap (a store + an RTC-memory breadcrumb); safe from any task (not from an ISR). */
void health_beat(health_src_t src);
/* Arm (required = true, with a fresh beat) or disarm a source that is only enforced in some states
 * (HTTPD / TCPIP during a session, BLE while NimBLE runs). PLAYER and POWER arm themselves at their first beat. */
void health_require(health_src_t src, bool required);
/* A known long operation in the source's own task (e.g. the OTA partition erase in the httpd task): it counts
 * as alive for `ms` from now even without beats. */
void health_grace(health_src_t src, uint32_t ms);
/* Controller: feed the RWDT when every required source is alive (see the table above). */
void health_feed(void);
/* True when `src` beat within `max_age_ms` (false if it never beat). */
bool health_alive(health_src_t src, uint32_t max_age_ms);
/* "player=1s power=0s httpd=3s(req) tcpip=-(off) ble=2s(req)" for logs. */
void health_liveness_report(char *buf, size_t len);

/* Breadcrumb inputs (RTC memory; cheap, any task). */
void health_note_http(const char *method, const char *uri, bool begin);   /* request start / end */
void health_note_usb(bool sof);
void health_note_battery(int mv, bool usb);                               /* every battery reading (power task) */                                           /* USB host SOF seen now */
void health_note_usb_hold(bool held);                                     /* power.c's USB light-sleep hold */
void health_note_upload(void);                                            /* an upload was stored */
/* Light-sleep entry / exit (power.c's esp_pm callbacks; IRAM, called with interrupts disabled). `usb_present`:
 * the entry happened while usb_present was true (counted separately; must never happen with the USB hold). */
void health_ls_enter(bool usb_present);
void health_ls_exit(void);

/* Breadcrumb + progress: also feeds the watchdog (health_feed), so a long but progressing controller
 * operation (session start / stop) never trips it. */
void health_step(health_step_t step);

/* Session bookkeeping for the breadcrumbs. */
void health_session(bool active);

/* One short line about the current item, rewritten freely (RTC memory; printed at the next boot as
 * "previous run: last item note at N s: ..."). ≤ 95 chars kept. */
void health_item_note(const char *text);
/* The previous run, from its RTC breadcrumbs ("-" / 0 when none survived): its last step, when it was
 * reached and when the controller last updated the crumbs (uptime seconds). */
/* How many of the most recent boots (newest first, consecutive) followed a run shorter than max_run_s on
 * battery that ended in a power-on type reset with RTC memory kept: a reboot loop on a failing supply. */
unsigned health_short_battery_runs(uint32_t max_run_s);
const char *health_prev_step_name(void);
uint32_t health_prev_step_s(void);
uint32_t health_prev_last_update_s(void);

/* Bench builds only (CONFIG_PIXELCLIP_BENCH_ROUTES, README "Bench: stress session, watchdog and crash tests"): deliberate
 * faults that prove the safety nets end to end. Both act ~300 ms later from their own task, so the HTTP / fast-lane
 * response still goes out. ESP_ERR_INVALID_ARG for an unknown name, ESP_ERR_NOT_SUPPORTED in production builds.
 *   crash: "abort" | "assert" | "null" (store to NULL) | "stack" (stack overflow)  -> panic + core dump + reboot
 *   wedge: "sleep"   light sleep with every wake source disabled  -> RTCWDT_SYS (the RWDT counts in light sleep)
 *          "suspend" vTaskSuspendAll() + spin on CPU0 (controller starves) -> RTCWDT_SYS
 *          "irqoff"  interrupts off + spin on CPU0                  -> interrupt watchdog panic + core dump
 *          "player" | "power" | "httpd" | "tcpip" | "ble" | "controller": the next beat of that source blocks its
 *                    task forever                                   -> liveness: RTCWDT_SYS, crumbs name the source */
esp_err_t health_bench_crash(const char *kind);
esp_err_t health_bench_wedge(const char *mode);

/* Core dump in flash (README "Crash diagnostics (core dump)"). A panic writes an ELF core dump to the
 * `coredump` partition; health_boot_record() logs its summary at every boot while it is there
 * ("health: coredump: task ... crashed at PC ..."). Firmware whose partition table has no `coredump`
 * partition (a clip updated over OTA from an older layout) behaves as if there were never a dump. */
/* Size in bytes of the valid stored image (raw flash image: header + ELF + SHA-256), 0 when there is none. */
size_t health_coredump_size(void);
/* Read `len` bytes at `off` of the stored image (off + len <= health_coredump_size()). */
esp_err_t health_coredump_read(size_t off, void *buf, size_t len);
/* Erase it: ESP_OK, or ESP_ERR_NOT_FOUND when there was none (or no partition). */
esp_err_t health_coredump_erase(void);

#ifdef __cplusplus
}
#endif
