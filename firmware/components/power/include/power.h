/* power.h — battery monitoring, USB presence, CPU frequency / light-sleep policy and deep sleep ("off").
 *
 * Battery: CONFIG_PIXELCLIP_BAT_ADC_GPIO (default GPIO1 = ADC1_CH0; GPIO4 on the LilyGo) behind a 100k/100k divider, curve-fitting calibrated, x2, sampled every
 * CONFIG_PIXELCLIP_BATTERY_SAMPLE_S with a 4-sample moving average. The PL4054 charger has no
 * status line to the MCU, so `usb_present`/`charging` are heuristics, re-evaluated every second:
 *   usb_present = the USB-Serial-JTAG sees SOF packets from a host right now (not sticky: the IDF tick hook
 *                 clears it ~3 ms after the last SOF)
 *                 OR at least 3 of the last 5 one-second Vbat reads are >= 4.25 V (VBUS proxy: only the
 *                 charger holds the BAT node that high; covers a wall charger, which sends no SOF)
 *   charging    = usb_present and the averaged Vbat < 4.15 V
 * so usb_present drops within ~3 s of unplugging (README "Light sleep on battery"). While usb_present is true
 * (and 5 s after) power.c holds POWER_AWAKE_USB: no automatic light sleep on USB (README "USB light-sleep inhibit").
 *
 * CPU: esp_pm DFS between CONFIG_PIXELCLIP_CPU_MIN_MHZ and _MAX_MHZ with automatic light sleep.
 * Code that needs speed brackets itself with power_perf_acquire/release(owner); every owner has its own
 * hold count so a leak can be attributed (power_perf_held(), power_perf_report()).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    POWER_EVT_LOW_BATTERY,   /* pct <= threshold twice in a row, or below the 3.40 V hard floor (no session) */
    POWER_EVT_WEAK_FOR_WIFI, /* below 3.5 V, or a session sagged into the low-battery range: end the session */
    POWER_EVT_USB_CHANGED,   /* usb_present flipped (re-read it with power_get_battery()) */
    POWER_EVT_SESSION_LOW,   /* on battery, in a session, averaged Vbat below 3.9 V: blank the panel */
} power_event_t;

typedef void (*power_event_cb_t)(power_event_t ev);

typedef struct {
    int mv;
    int pct;
    bool charging;
    bool usb_present;
    bool usb_sof;    /* the USB host part of usb_present (SOF seen) */
    bool valid;      /* false until the ADC produced a plausible reading: never act on mv/pct then */
} power_battery_t;

/* Configure esp_pm, take a first battery reading and start the sampling task. */
esp_err_t power_init(power_event_cb_t cb);

/* Low-battery threshold in percent (from config); 0 disables the percentage check. */
void power_set_low_battery_pct(uint8_t pct);

void power_get_battery(power_battery_t *out);
/* A valid reading and no USB power: the battery-mode policies apply. */
bool power_on_battery(void);

/* A WiFi session started / ended (net.c). During a session the minimum Vbat is tracked (logged at the end),
 * and a sag into the low-battery range ends the session (POWER_EVT_WEAK_FOR_WIFI) instead of powering the clip
 * off; after it the moving average restarts from fresh readings (the sagged ones do not count). */
void power_session(bool active);
/* Minimum instantaneous Vbat of the running (or last) session, 0 = none. */
int power_session_min_mv(void);

/* "Run at max CPU frequency" holds, counted per owner (one shared esp_pm lock underneath).
 * TRANSIENT holds are short begin/end pairs inside the player task only: its loop checks that it holds none
 * between iterations. SCENE / STRIP are held while one is on screen, ORACLE while an Oracle shuffles, SESSION for
 * a WiFi session. */
typedef enum {
    POWER_PERF_TRANSIENT,
    POWER_PERF_SCENE,
    POWER_PERF_STRIP,
    POWER_PERF_SESSION,
    POWER_PERF_ORACLE,      /* an Oracle shuffles (12 fps whole-frame decodes, 1.2 s) */
    POWER_PERF_OWNERS,
} power_perf_owner_t;

void power_perf_acquire(power_perf_owner_t owner);
void power_perf_release(power_perf_owner_t owner);
int power_perf_held(power_perf_owner_t owner);
/* "transient=0 scene=1 strip=0 session=0 oracle=0" */
void power_perf_report(char *buf, size_t len);
/* Number of accounting errors so far (a release without a matching acquire). */
uint32_t power_perf_errors(void);

/* esp_pm locks currently held, other than the calling core's "rtos" lock, as "perf/CPU_FREQ_MAX x1, ..."
 * ("none" when nothing holds the chip awake). Returns how many, -1 on error. Controller task only. */
int power_pm_locks_summary(char *buf, size_t len);

/* CONFIG_PM_PROFILING only (the bench build): light sleeps entered / rejected since boot and the share of
 * time spent in light sleep. False when profiling is off. */
bool power_pm_sleep_stats(uint32_t *sleeps, uint32_t *rejects, int *sleep_pct);

/* "Stay awake" holds: an ESP_PM_NO_LIGHT_SLEEP lock, counted per owner (README "Session light-sleep inhibit").
 * SESSION is held for the whole WiFi session and 10 s after it (net.c), FASTLANE while a BLE fast-lane worker
 * runs (pixelclip_ble.c), USB by power.c itself (README "USB light-sleep inhibit"): acquired in the same power-task
 * tick in which usb_present becomes true (before it is published), released once usb_present has stayed false
 * for 5 s; never in the light-sleep soak build (CONFIG_PIXELCLIP_BENCH_SLEEP_TEST light-sleeps on USB on purpose).
 * A light-sleep entry while any of them is held is an assertion failure: counted (power_awake_violations(),
 * logged by the session heap line) and fatal in the bench builds. */
typedef enum {
    POWER_AWAKE_SESSION,
    POWER_AWAKE_FASTLANE,
    POWER_AWAKE_USB,          /* power.c only: never acquire / release it from elsewhere */
    POWER_AWAKE_POWEROFF,     /* the power-off choreography (bye screen, fade, panel off): no nap mid-sequence */
    POWER_AWAKE_PANEL,        /* the panel is on: no automatic light sleep at all (every battery freeze of 2026-10-16/17
                               * was a nap corrupting the panel's command interface; the panel dominates the budget anyway) */
    POWER_AWAKE_OWNERS,
} power_awake_owner_t;

void power_awake_acquire(power_awake_owner_t owner);
void power_awake_release(power_awake_owner_t owner);
int power_awake_held(power_awake_owner_t owner);
/* Automatic light sleeps entered while an awake hold was held (must stay 0), and entered in all. */
uint32_t power_awake_violations(void);
uint32_t power_light_sleeps(void);
/* Automatic light sleeps entered while usb_present was true (must stay 0: the USB hold forbids them; each one
 * disables the USB-Serial-JTAG pad and the host sees the port vanish). */
uint32_t power_light_sleeps_while_usb(void);
/* The USB hold (POWER_AWAKE_USB) is held right now. */
bool power_usb_hold(void);
/* A bench hook: for `secs` seconds the cable is not seen (the chip behaves as on a cell), then the hold is retaken. */
void power_test_no_usb(uint32_t secs);

/* Legacy names: a TRANSIENT hold. */
static inline void power_perf_begin(void) { power_perf_acquire(POWER_PERF_TRANSIENT); }
static inline void power_perf_end(void) { power_perf_release(POWER_PERF_TRANSIENT); }

/* Enter deep sleep; wakes (= reboots) on GPIO0 low. Caller must have turned the display off, stopped the
 * RTC watchdog and waited for the button to be released. Never returns. */
void power_deep_sleep(void) __attribute__((noreturn));

/* Deep sleep with a chosen wake (an optional hook for other projects that reuse this component, e.g. a board whose
 * BOOT key is gone; this firmware does not call it). Every wake source is cleared first; then, per argument:
 *  - ext1_mask != 0: ext1 ANY_LOW on those RTC GPIOs, each with its RTC pull-up on and pull-down off, and the
 *    RTC_PERIPH power domain kept on through the sleep (it holds the pull-ups);
 *  - ext0_gpio >= 0: ext0 on that GPIO low (the PixelClip's BOOT wake, as power_deep_sleep()); -1 = none;
 *  - hold_low_gpio >= 0: that output driven low and held through the sleep (gpio_hold_en + the deep-sleep hold;
 *    released by power_release_hold() at the next boot), e.g. a panel power enable that would float; -1 = none.
 * No mask and no ext0 sleeps with no wake at all (only a reset ends it). Saves the anchor, stops the RTC watchdog.
 * Never returns. */
void power_deep_sleep_wake(uint64_t ext1_mask, int ext0_gpio, int hold_low_gpio) __attribute__((noreturn));
/* As power_deep_sleep_wake() with two more choices (an optional hook, e.g. for a deep Off that a touch did not wake;
 * this firmware does not call it):
 *  - ext1_high: ext1 ANY_HIGH instead of ANY_LOW, each mask GPIO with its RTC pull-down on and pull-up off (a pull-up
 *    would hold the line high and end the sleep at once);
 *  - hold_gpio / hold_high: that output driven HIGH (hold_high) or LOW and held through the sleep, e.g. a panel power
 *    enable kept up so a touch controller on that rail stays powered; -1 = none.
 * Logs the chosen hold level and wake edge. power_deep_sleep_wake(m, e, g) == power_deep_sleep_wake_ex(m, false, e, g,
 * false). Never returns. */
void power_deep_sleep_wake_ex(uint64_t ext1_mask, bool ext1_high, int ext0_gpio, int hold_gpio, bool hold_high)
    __attribute__((noreturn));
/* An optional hook (bench tests in other projects that reuse this component; this firmware does not arm it): the next
 * power_deep_sleep_wake() / _wake_ex() also arms an RTC timer wake after secs seconds (0 = none, the default), next to
 * its other sources; logged as " timer N s" on its "entering deep sleep" line. power_deep_sleep() honours it too (to
 * compare the two entry paths). */
void power_deep_sleep_arm_timer(uint32_t secs);
/* An optional hook (key wake tests in other projects that reuse this component): the RTC time (esp_rtc_get_time_us())
 * taken by power_deep_sleep() / _wake() / _wake_ex() right before esp_deep_sleep_start(), kept in RTC_NOINIT memory
 * (it survives the deep sleep and core resets; garbage after a power-on: the caller validates it with its own record).
 * With a timer armed, the wake is about this time + the timer. */
int64_t power_deep_sleep_entry_rtc_us(void);
/* Optional hooks for other projects that reuse this component (this firmware calls none of these):
 *  - power_deep_sleep_ext0_level(): the level the next _wake_ex()'s ext0 wakes on, 0 (the default: a press of an
 *    active-low key) or 1 (its release: a key still down at the Off wakes the chip when it is let go);
 *  - power_deep_sleep_gpio0_phantom(): the next _wake_ex() drives GPIO0 low through the sleep (RTC output, held)
 *    instead of only pulling it up, so a test can play a key press without a finger (debug only);
 *  - power_deep_sleep_set_entry_cb(): cb (may be NULL) runs in _wake_ex() right before the RTC entry stamp and
 *    esp_deep_sleep_start(), after the pads are set up and the log drained, with what was armed (a flight recorder). */
void power_deep_sleep_ext0_level(int level);
void power_deep_sleep_gpio0_phantom(bool low);
typedef struct {
    uint64_t ext1_mask;
    int ext0_gpio;          /* -1 none */
    int ext0_level;
    uint32_t timer_s;       /* 0 none */
    bool gpio0_phantom;     /* GPIO0 driven low through the sleep */
} power_deep_entry_t;
typedef void (*power_deep_entry_cb_t)(const power_deep_entry_t *e);
void power_deep_sleep_set_entry_cb(power_deep_entry_cb_t cb);
/* After a wake: release a pad hold power_deep_sleep_wake() left on gpio (no-op when none). Call before driving it. */
void power_release_hold(int gpio);

#ifdef __cplusplus
}
#endif
