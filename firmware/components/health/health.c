/* health.c — RTC watchdog that keeps counting in light sleep, liveness, reset accounting (health.h). */
#include "health.h"
#include "health_priv.h"

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_system.h"
#include "esp_rom_sys.h"
#include "esp_heap_caps.h"
#include "nvs.h"
#include "hal/wdt_hal.h"
#include "hal/rwdt_ll.h"
#include "soc/rtc.h"
#include "soc/reset_reasons.h"
#include "sdkconfig.h"

static const char *TAG = "health";

#define NVS_NS        "health"
#define CRUMB_MAGIC   0x5A4E4833u   /* "ZNH3" (v3: + USB hold, light sleeps while USB present) */
#define STAGE1_EXTRA_S 5             /* stage 1 (full RTC reset) fires this long after stage 0 */

#define HTTP_CRUMB_MAX 40
#define LIVENESS_LOOP_MAX   3        /* consecutive liveness resets blamed on HTTPD/TCPIP/BLE before they are relaxed */
#define LIVENESS_LOOP_WINDOW_S 600   /* ... each one within this long after its boot */
#define OPTIONAL_SRCS ((1u << HEALTH_SRC_HTTPD) | (1u << HEALTH_SRC_TCPIP) | (1u << HEALTH_SRC_BLE))

/* Breadcrumbs in RTC slow memory: survive a system reset (RWDT stage 0), panics, software resets and, in
 * practice, the RESET button (RTC memory is not cleared by a reset, only by a power loss). */
typedef struct {
    uint32_t magic;
    uint32_t boot;
    uint32_t up_s;                           /* uptime at the last update */
    uint32_t beat_s[HEALTH_SRC_COUNT];       /* uptime of the last beat per source */
    uint32_t feed_s;                         /* uptime of the last RWDT feed */
    uint32_t starved;                        /* feeds skipped because a required source was silent */
    uint32_t step_s;                         /* uptime when `step` was reached */
    uint8_t step;
    uint8_t session;
    uint8_t player_registered;
    uint8_t starved_mask;                    /* sources silent at the last skipped feed (bit = health_src_t) */
    uint8_t required_mask;                   /* sources required at the last feed */
    uint8_t usb_sof;                         /* last USB state seen by the power task */
    int16_t bat_mv;                          /* last battery reading (power task) */
    uint8_t bat_usb;                         /* ... taken while USB was present */
    uint32_t bat_s;                          /* uptime of that reading */
    uint8_t http_open;                       /* a request had begun and not ended */
    uint8_t loop_count;                      /* consecutive liveness resets blamed on optional sources */
    uint32_t heap_free, heap_min, heap_largest;   /* internal heap at the last feed */
    uint32_t usb_change_s;                   /* uptime of the last USB state change */
    uint32_t http_s;                         /* uptime of the last request start / end */
    uint32_t uploads;                        /* assets / texts stored in this run */
    uint32_t ls_count;                       /* automatic light sleeps entered in this run */
    uint32_t ls_enter_ms, ls_exit_ms;        /* uptime (ms) of the last light-sleep entry / exit */
    char http[HTTP_CRUMB_MAX];               /* "PUT /assets/font-serif-78b80d0a-n" */
    uint8_t usb_hold;                        /* power.c's USB light-sleep hold (POWER_AWAKE_USB) held */
    uint32_t usb_hold_change_s;              /* uptime of the last USB hold change */
    uint32_t ls_usb_count;                   /* light sleeps entered while usb_present (must stay 0) */
} crumbs_t;

static RTC_NOINIT_ATTR crumbs_t s_rtc;
static crumbs_t s_prev;
static bool s_prev_valid;

/* Player item breadcrumb (health_item_note): one short line the player rewrites as often as it likes
 * (the oracle writes it every step). Its own RTC_NOINIT block and magic, so the controller crumbs above keep
 * their layout; `set` is cleared while the text changes, so a crash mid-update loses the line instead of mixing
 * two. Kept across a reset, printed with the previous run. */
#define ITEM_MAGIC    0x5A4E4933u   /* "ZNI3" */
#define ITEM_TEXT_MAX 95
typedef struct {
    uint32_t magic;
    volatile uint32_t set;
    uint32_t at_s;                           /* uptime of the note */
    char text[ITEM_TEXT_MAX + 1];
} item_crumb_t;

static RTC_NOINIT_ATTR item_crumb_t s_item;

/* Reset history: the last 8 boots' reset reason, how long the run before each lasted and its last battery
 * reading. Survives every reset that keeps RTC memory (which is how we know a battery-only reboot was not
 * a power loss). Printed at boot: "recent resets: POWERON after 23 s @3612 mV, ...". */
#define HIST_MAGIC 0x5A4E4834u   /* "ZNH4" */
#define HIST_N 8
typedef struct {
    uint8_t raw;                             /* soc_reset_reason_t */
    uint8_t esp;                             /* esp_reset_reason_t */
    uint8_t bat_usb;
    uint8_t rtc_kept;                        /* the previous run's crumbs were readable */
    uint32_t prev_up_s;
    int16_t prev_bat_mv;
    uint16_t prev_bat_age_s;
} hist_entry_t;
typedef struct {
    uint32_t magic;
    uint32_t n;                              /* entries written (ring index = n % HIST_N) */
    hist_entry_t e[HIST_N];
} hist_t;
static RTC_NOINIT_ATTR hist_t s_hist;
static item_crumb_t s_item_prev;
static bool s_item_prev_valid;

static volatile int64_t s_beat_us[HEALTH_SRC_COUNT];
static volatile bool s_registered[HEALTH_SRC_COUNT];   /* beat at least once */
static volatile bool s_required[HEALTH_SRC_COUNT];     /* enforced by health_feed() */
static bool s_relaxed;                                 /* safety valve: optional sources only logged this boot */
static bool s_wdt_on;
static int64_t s_last_starve_log_us;
static int64_t s_last_heap_us;
static volatile uint8_t s_wedge_src = 0xFF;            /* bench: the next beat of this source blocks forever */

/* Silence limits (ms) per source; 0 = not a liveness source (the controller is the feeder itself). */
static const uint32_t s_limit_ms[HEALTH_SRC_COUNT] = {
    [HEALTH_SRC_CONTROLLER] = 0,
    [HEALTH_SRC_PLAYER] = HEALTH_PLAYER_SILENCE_S * 1000,
    [HEALTH_SRC_POWER] = 15000,
    [HEALTH_SRC_HTTPD] = 30000,
    [HEALTH_SRC_TCPIP] = 15000,
    [HEALTH_SRC_BLE] = 30000,
};
static const char *const s_src_names[HEALTH_SRC_COUNT] = { "controller", "player", "power", "httpd", "tcpip", "ble" };
static health_resets_t s_resets;
static const char *s_reason = "UNKNOWN";

static const char *const s_step_names[HEALTH_STEP_COUNT] = {
    "boot", "idle", "session_start", "session_up", "session_stop", "session_stop:httpd", "session_stop:wifi",
    "session_done", "power_off",
};

static inline uint32_t up_s(void) { return (uint32_t)(esp_timer_get_time() / 1000000); }

/* ------------------------------------------------------------------ RTC watchdog */

void health_wdt_start(uint32_t timeout_s)
{
    const uint32_t hz = rtc_clk_slow_freq_get_hz();   /* RC_FAST/256 here (~68 kHz, nominal) */
    wdt_hal_context_t ctx = RWDT_HAL_CONTEXT_DEFAULT();
    wdt_hal_init(&ctx, WDT_RWDT, 0, false);           /* disables it, clears stages, pause-in-sleep = 1 */
    wdt_hal_write_protect_disable(&ctx);
    wdt_hal_config_stage(&ctx, WDT_STAGE0, timeout_s * hz, WDT_STAGE_ACTION_RESET_SYSTEM);
    wdt_hal_config_stage(&ctx, WDT_STAGE1, (uint32_t)STAGE1_EXTRA_S * hz, WDT_STAGE_ACTION_RESET_RTC);
    wdt_hal_set_flashboot_en(&ctx, false);
    /* Keep counting during light sleep: a chip that sleeps with no wake source must still be reset. The
     * controller wakes every HEALTH_FEED_PERIOD_MS to feed it, so a healthy sleeper never gets near. */
    rwdt_ll_set_pause_in_sleep_en(ctx.rwdt_dev, false);
    wdt_hal_enable(&ctx);
    wdt_hal_feed(&ctx);
    wdt_hal_write_protect_enable(&ctx);
    s_wdt_on = true;
    ESP_LOGI(TAG, "RTC watchdog on: %lu s (system reset) + %d s (RTC reset), counts in light sleep, slow clock ~%lu Hz",
             (unsigned long)timeout_s, STAGE1_EXTRA_S, (unsigned long)hz);
}

void health_wdt_stop(void)
{
    if (!s_wdt_on) return;
    wdt_hal_context_t ctx = RWDT_HAL_CONTEXT_DEFAULT();
    wdt_hal_write_protect_disable(&ctx);
    wdt_hal_feed(&ctx);
    wdt_hal_disable(&ctx);
    wdt_hal_write_protect_enable(&ctx);
    s_wdt_on = false;
    ESP_LOGI(TAG, "RTC watchdog off");
}

static void wdt_feed(void)
{
    if (!s_wdt_on) return;
    wdt_hal_context_t ctx = RWDT_HAL_CONTEXT_DEFAULT();
    wdt_hal_write_protect_disable(&ctx);
    wdt_hal_feed(&ctx);
    wdt_hal_write_protect_enable(&ctx);
}

/* ------------------------------------------------------------------ liveness */

bool health_alive(health_src_t src, uint32_t max_age_ms)
{
    if (src >= HEALTH_SRC_COUNT || !s_registered[src]) return false;
    return esp_timer_get_time() - s_beat_us[src] <= (int64_t)max_age_ms * 1000;
}

static void bench_block_if_wedged(health_src_t src)
{
    if (s_wedge_src != (uint8_t)src) return;
    ESP_LOGE(TAG, "bench wedge: %s task blocks forever now (expect an RTCWDT reset)", s_src_names[src]);
    for (;;) vTaskDelay(pdMS_TO_TICKS(1000));
}

void health_beat(health_src_t src)
{
    if (src >= HEALTH_SRC_COUNT) return;
    bench_block_if_wedged(src);
    const int64_t now = esp_timer_get_time();
    if (s_beat_us[src] < now) s_beat_us[src] = now;   /* never shorten a health_grace() */
    if (!s_registered[src]) {
        s_registered[src] = true;
        /* PLAYER and POWER are required from their first beat (a failed init must not cause a reboot loop). */
        if (src == HEALTH_SRC_PLAYER || src == HEALTH_SRC_POWER) s_required[src] = true;
    }
    s_rtc.beat_s[src] = (uint32_t)(now / 1000000);
    s_rtc.up_s = s_rtc.beat_s[src];
    if (src == HEALTH_SRC_PLAYER) s_rtc.player_registered = 1;
}

void health_require(health_src_t src, bool required)
{
    if (src >= HEALTH_SRC_COUNT || src == HEALTH_SRC_CONTROLLER) return;
    if (required) {
        const int64_t now = esp_timer_get_time();
        if (s_beat_us[src] < now) s_beat_us[src] = now;   /* arming counts as a beat */
        s_registered[src] = true;
    }
    s_required[src] = required;
}

void health_grace(health_src_t src, uint32_t ms)
{
    if (src >= HEALTH_SRC_COUNT) return;
    const int64_t until = esp_timer_get_time() + (int64_t)ms * 1000 - (int64_t)s_limit_ms[src] * 1000;
    if (s_beat_us[src] < until) s_beat_us[src] = until;
}

/* Bit mask of required sources that are silent now. */
static uint8_t silent_mask(int64_t now, uint8_t *required_out)
{
    uint8_t silent = 0, req = 0;
    for (int i = 0; i < HEALTH_SRC_COUNT; i++) {
        if (!s_required[i] || !s_limit_ms[i]) continue;
        req |= (uint8_t)(1u << i);
        if (now - s_beat_us[i] > (int64_t)s_limit_ms[i] * 1000) silent |= (uint8_t)(1u << i);
    }
    *required_out = req;
    return silent;
}

void health_liveness_report(char *buf, size_t len)
{
    const int64_t now = esp_timer_get_time();
    size_t n = 0;
    if (len) buf[0] = '\0';
    for (int i = 1; i < HEALTH_SRC_COUNT && n < len; i++) {
        int w;
        if (!s_registered[i]) {
            w = snprintf(buf + n, len - n, "%s%s=-", n ? " " : "", s_src_names[i]);
        } else {
            const int64_t age = now - s_beat_us[i];
            w = snprintf(buf + n, len - n, "%s%s=%llds%s", n ? " " : "", s_src_names[i],
                         (long long)(age > 0 ? age / 1000000 : 0), s_required[i] ? "" : "(off)");
        }
        if (w < 0) break;
        n += (size_t)w;
    }
}

void health_feed(void)
{
    const int64_t now = esp_timer_get_time();
    health_beat(HEALTH_SRC_CONTROLLER);
    /* Heap crumbs every 5 s at most (largest-block needs a heap walk). */
    if (now - s_last_heap_us >= 5000000) {
        s_last_heap_us = now;
        s_rtc.heap_free = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
        s_rtc.heap_min = (uint32_t)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
        s_rtc.heap_largest = (uint32_t)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
    }
    /* A boot that lived this long ends a reboot loop: the safety-valve counter starts again. */
    if (s_rtc.loop_count && now > (int64_t)LIVENESS_LOOP_WINDOW_S * 1000000) s_rtc.loop_count = 0;
    uint8_t required = 0;
    uint8_t silent = silent_mask(now, &required);
    s_rtc.required_mask = required;
    if (s_relaxed && (silent & OPTIONAL_SRCS)) {
        if (now - s_last_starve_log_us > 30000000) {
            s_last_starve_log_us = now;
            ESP_LOGE(TAG, "liveness: silent 0x%02x, NOT enforced for httpd/tcpip/ble this boot (%d liveness resets in a row)",
                     (unsigned)silent, LIVENESS_LOOP_MAX);
        }
        silent &= (uint8_t)~OPTIONAL_SRCS;
    }
    if (silent) {
        s_rtc.starved++;
        s_rtc.starved_mask = silent;
        if (now - s_last_starve_log_us > 5000000) {
            s_last_starve_log_us = now;
            char who[64] = "";
            size_t n = 0;
            for (int i = 0; i < HEALTH_SRC_COUNT; i++) {
                if (!(silent & (1u << i))) continue;
                int w = snprintf(who + n, sizeof who - n, "%s%s %llds", n ? ", " : "", s_src_names[i],
                                 (long long)((now - s_beat_us[i]) / 1000000));
                if (w < 0 || (size_t)w >= sizeof who - n) break;
                n += (size_t)w;
            }
            ESP_LOGE(TAG, "liveness: silent: %s: NOT feeding the RTC watchdog (reset within %d s)", who,
                     CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S);
        }
        return;
    }
    wdt_feed();
    s_rtc.feed_s = (uint32_t)(now / 1000000);
}

/* ------------------------------------------------------------------ breadcrumb inputs */

void health_note_http(const char *method, const char *uri, bool begin)
{
    s_rtc.http_s = up_s();
    s_rtc.http_open = begin;
    if (!begin) return;
    size_t n = 0;
    for (const char *p = method; p && *p && n + 1 < sizeof s_rtc.http; p++) s_rtc.http[n++] = *p;
    if (n + 1 < sizeof s_rtc.http) s_rtc.http[n++] = ' ';
    for (const char *p = uri; p && *p && *p != '?' && n + 1 < sizeof s_rtc.http; p++) s_rtc.http[n++] = *p;
    s_rtc.http[n] = '\0';
}

void health_note_battery(int mv, bool usb)
{
    s_rtc.bat_mv = mv > INT16_MAX ? INT16_MAX : (int16_t)mv;
    s_rtc.bat_usb = usb;
    s_rtc.bat_s = up_s();
}

void health_note_usb(bool sof)
{
    if (s_rtc.usb_sof != (uint8_t)sof) s_rtc.usb_change_s = up_s();
    s_rtc.usb_sof = sof;
}

void health_note_upload(void) { s_rtc.uploads++; }

void health_note_usb_hold(bool held)
{
    if (s_rtc.usb_hold != (uint8_t)held) s_rtc.usb_hold_change_s = up_s();
    s_rtc.usb_hold = held;
}

void IRAM_ATTR health_ls_enter(bool usb_present)
{
    s_rtc.ls_count++;
    if (usb_present) s_rtc.ls_usb_count++;
    s_rtc.ls_enter_ms = (uint32_t)(esp_timer_get_time() / 1000);
}

void IRAM_ATTR health_ls_exit(void)
{
    s_rtc.ls_exit_ms = (uint32_t)(esp_timer_get_time() / 1000);
}

void health_step(health_step_t step)
{
    if (step < HEALTH_STEP_COUNT) s_rtc.step = (uint8_t)step;
    s_rtc.step_s = s_rtc.up_s = up_s();
    health_feed();
}

void health_session(bool active) { s_rtc.session = active; }

/* ------------------------------------------------------------------ item breadcrumb */

static void crumb_copy(char *dst, size_t cap, const char *src)
{
    size_t i = 0;
    if (src) {
        for (; i + 1 < cap && src[i]; i++) dst[i] = src[i];
    }
    dst[i] = '\0';
}

void health_item_note(const char *text)
{
    s_item.set = 0;
    __asm__ __volatile__("" ::: "memory");
    s_item.magic = ITEM_MAGIC;
    s_item.at_s = (uint32_t)(esp_timer_get_time() / 1000000);
    crumb_copy(s_item.text, sizeof s_item.text, text);
    __asm__ __volatile__("" ::: "memory");
    s_item.set = 1;
}

/* ------------------------------------------------------------------ reset accounting */

static const char *raw_name(soc_reset_reason_t raw)
{
    switch ((int)raw) {
    case 0x01: return "POWERON";
    case 0x03: return "SW_SYS";
    case 0x05: return "DEEPSLEEP";
    case 0x07: return "TG0WDT_SYS";
    case 0x08: return "TG1WDT_SYS";
    case 0x09: return "RTCWDT_SYS";      /* RWDT stage 0 (system reset): our light-sleep safety net */
    case 0x0B: return "TG0WDT_CPU";
    case 0x0C: return "SW_CPU";
    case 0x0D: return "RTCWDT_CPU";
    case 0x0F: return "BROWNOUT";        /* the ROM calls it RTCWDT_BROWN_OUT_RESET: not a watchdog */
    case 0x10: return "RTCWDT_RTC";      /* RWDT stage 1 (full RTC reset) */
    case 0x11: return "TG1WDT_CPU";
    case 0x12: return "SUPER_WDT";
    case 0x13: return "CLK_GLITCH";
    case 0x14: return "EFUSE_CRC";
    case 0x15: return "USB_UART";
    case 0x16: return "USB_JTAG";
    case 0x17: return "PWR_GLITCH";
    default:   return "UNKNOWN";
    }
}

static bool raw_is_rtc_wdt(soc_reset_reason_t raw) { return raw == 0x09 || raw == 0x0D || raw == 0x10; }

static void nvs_bump(nvs_handle_t h, const char *key, uint32_t *val, bool bump)
{
    uint32_t v = 0;
    nvs_get_u32(h, key, &v);
    if (bump) {
        v++;
        nvs_set_u32(h, key, v);
    }
    *val = v;
}

const char *health_boot_record(void)
{
    const soc_reset_reason_t raw = esp_rom_get_reset_reason(0);
    const esp_reset_reason_t rr = esp_reset_reason();
    switch (rr) {
    case ESP_RST_PANIC: s_reason = "PANIC"; break;
    case ESP_RST_TASK_WDT: s_reason = "TASK_WDT"; break;
    case ESP_RST_INT_WDT: s_reason = "INT_WDT"; break;
    case ESP_RST_BROWNOUT: s_reason = "BROWNOUT"; break;
    case ESP_RST_SW: s_reason = "SW"; break;
    default: s_reason = raw_name(raw); break;
    }
    const bool rtc_wdt = raw_is_rtc_wdt(raw);
    const bool wdt = rtc_wdt || rr == ESP_RST_TASK_WDT || rr == ESP_RST_INT_WDT || rr == ESP_RST_WDT;
    const bool brownout = rr == ESP_RST_BROWNOUT || raw == 0x0F;
    const bool panic = rr == ESP_RST_PANIC;

    if (s_rtc.magic == CRUMB_MAGIC) {
        s_prev = s_rtc;
        s_prev.http[HTTP_CRUMB_MAX - 1] = '\0';
        s_prev_valid = true;
    }
    bool hist_from_flash = false;
    if (s_hist.magic != HIST_MAGIC) {
        /* RTC memory gone (a real power loss): continue the history from its flash mirror. */
        memset(&s_hist, 0, sizeof s_hist);
        nvs_handle_t hh;
        if (nvs_open(NVS_NS, NVS_READONLY, &hh) == ESP_OK) {
            hist_t saved;
            size_t len = sizeof saved;
            if (nvs_get_blob(hh, "hist", &saved, &len) == ESP_OK && len == sizeof saved && saved.magic == HIST_MAGIC) {
                s_hist = saved;
                hist_from_flash = true;
            }
            nvs_close(hh);
        }
        s_hist.magic = HIST_MAGIC;
    }
    {
        hist_entry_t *h = &s_hist.e[s_hist.n % HIST_N];
        h->raw = (uint8_t)raw;
        h->esp = (uint8_t)rr;
        h->rtc_kept = s_prev_valid;
        h->prev_up_s = s_prev_valid ? s_prev.up_s : 0;
        h->prev_bat_mv = s_prev_valid ? s_prev.bat_mv : 0;
        h->bat_usb = s_prev_valid ? s_prev.bat_usb : 0;
        const uint32_t age = s_prev_valid && s_prev.up_s >= s_prev.bat_s ? s_prev.up_s - s_prev.bat_s : 0;
        h->prev_bat_age_s = age > UINT16_MAX ? UINT16_MAX : (uint16_t)age;
        s_hist.n++;
    }
    memset(&s_rtc, 0, sizeof s_rtc);
    s_rtc.magic = CRUMB_MAGIC;
    if (s_item.magic == ITEM_MAGIC && s_item.set == 1) {
        s_item_prev = s_item;
        s_item_prev.text[ITEM_TEXT_MAX] = '\0';
        s_item_prev_valid = true;
    }
    memset(&s_item, 0, sizeof s_item);
    s_item.magic = ITEM_MAGIC;

    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_bump(h, "boots", &s_resets.boots, true);
        nvs_bump(h, "wdt", &s_resets.wdt, wdt);
        nvs_bump(h, "rtc_wdt", &s_resets.rtc_wdt, rtc_wdt);
        nvs_bump(h, "brownout", &s_resets.brownout, brownout);
        nvs_bump(h, "panic", &s_resets.panic, panic);
        nvs_set_blob(h, "hist", &s_hist, sizeof s_hist);   /* the reset history's flash mirror (survives power loss) */
        nvs_commit(h);
        nvs_close(h);
    } else {
        ESP_LOGE(TAG, "nvs_open(%s) failed: reset counters not persisted", NVS_NS);
    }
    strlcpy(s_resets.last, s_reason, sizeof s_resets.last);
    s_rtc.boot = s_resets.boots;

    /* Safety valve (health.h): count consecutive liveness resets blamed on the optional sources. */
    const bool liveness_reset = rtc_wdt && s_prev_valid && s_prev.starved_mask != 0;
    if (liveness_reset && (s_prev.starved_mask & OPTIONAL_SRCS) && !(s_prev.starved_mask & ~OPTIONAL_SRCS)) {
        s_rtc.loop_count = (uint8_t)(s_prev.loop_count + 1);
    }
    if (s_rtc.loop_count >= LIVENESS_LOOP_MAX) {
        s_relaxed = true;
        ESP_LOGE(TAG, "%u liveness resets in a row blamed on httpd/tcpip/ble: those are only logged this boot",
                 (unsigned)s_rtc.loop_count);
    }

    if (wdt || brownout || panic) {
        ESP_LOGW(TAG, "*** boot #%lu after a %s reset (rom 0x%02x): watchdog %lu (rtc %lu), brownout %lu, panic %lu so far ***",
                 (unsigned long)s_resets.boots, s_reason, (unsigned)raw, (unsigned long)s_resets.wdt,
                 (unsigned long)s_resets.rtc_wdt, (unsigned long)s_resets.brownout, (unsigned long)s_resets.panic);
    }
    /* The previous run's crumbs after EVERY reset that kept RTC memory: a clip found wedged and reset by hand
     * (RESET button = POWERON here, USB reset) did not reboot itself, and these lines are then the only trace. */
    if (s_prev_valid) {
        const crumbs_t *p = &s_prev;
        char silent[64] = "", beats[96] = "";
        size_t n = 0, m = 0;
        for (int i = 0; i < HEALTH_SRC_COUNT; i++) {
            if (p->starved_mask & (1u << i)) {
                int w = snprintf(silent + n, sizeof silent - n, "%s%s", n ? "+" : "", s_src_names[i]);
                if (w > 0 && (size_t)w < sizeof silent - n) n += (size_t)w;
            }
            int w = snprintf(beats + m, sizeof beats - m, "%s%s %lu%s", m ? ", " : "", s_src_names[i],
                             (unsigned long)p->beat_s[i], (p->required_mask & (1u << i)) ? "" : "(off)");
            if (w > 0 && (size_t)w < sizeof beats - m) m += (size_t)w;
        }
        const bool asleep = p->ls_count && p->ls_enter_ms > p->ls_exit_ms;
        ESP_LOGW(TAG, "previous run (boot #%lu, %s): last update at %lu s; beats (s): %s; last RWDT feed %lu s, "
                 "%lu feed(s) skipped%s%s; step %s since %lu s, %s",
                 (unsigned long)p->boot, (wdt || brownout || panic) ? "ended by this reset" : "RTC memory kept: reset by hand / USB",
                 (unsigned long)p->up_s, beats, (unsigned long)p->feed_s, (unsigned long)p->starved,
                 n ? ", silent: " : "", silent, p->step < HEALTH_STEP_COUNT ? s_step_names[p->step] : "?",
                 (unsigned long)p->step_s, p->session ? "in a WiFi session" : "no session");
        ESP_LOGW(TAG, "previous run: internal heap %lu B free (min %lu, largest %lu) at the last feed; %lu upload(s); "
                 "last HTTP %s \"%s\" at %lu s; USB %s since %lu s; usb hold %s since %lu s; %lu light sleep(s) "
                 "(%lu while USB present%s), last entered %lu ms, left %lu ms%s",
                 (unsigned long)p->heap_free, (unsigned long)p->heap_min, (unsigned long)p->heap_largest,
                 (unsigned long)p->uploads, p->http_open ? "OPEN (handler never returned)" : "done",
                 p->http[0] ? p->http : "-", (unsigned long)p->http_s, p->usb_sof ? "host (SOF)" : "no SOF",
                 (unsigned long)p->usb_change_s, p->usb_hold ? "on" : "off", (unsigned long)p->usb_hold_change_s,
                 (unsigned long)p->ls_count, (unsigned long)p->ls_usb_count,
                 p->ls_usb_count ? ": USB HOLD BROKEN" : "", (unsigned long)p->ls_enter_ms,
                 (unsigned long)p->ls_exit_ms, asleep ? " -> DIED IN LIGHT SLEEP" : "");
    }
    if (s_item_prev_valid) {
        ESP_LOGW(TAG, "previous run: last item note at %lu s: %s", (unsigned long)s_item_prev.at_s, s_item_prev.text);
    }
    if (s_prev_valid) {
        ESP_LOGW(TAG, "previous run: last battery reading %d mV%s at %lu s", (int)s_prev.bat_mv,
                 s_prev.bat_usb ? " (usb)" : " (battery)", (unsigned long)s_prev.bat_s);
    }
    {
        char line[HIST_N * 44 + 1];
        int n = 0;
        const uint32_t cnt = s_hist.n < HIST_N ? s_hist.n : HIST_N;
        for (uint32_t i = 0; i < cnt; i++) {   /* newest first */
            const hist_entry_t *h = &s_hist.e[(s_hist.n - 1 - i) % HIST_N];
            n += snprintf(line + n, sizeof line - n, "%s%s after %lus @%d mV%s%s", i ? ", " : "", raw_name((soc_reset_reason_t)h->raw),
                          (unsigned long)h->prev_up_s, (int)h->prev_bat_mv, h->bat_usb ? "u" : "b", h->rtc_kept ? "" : " (RTC lost)");
            if (n >= (int)sizeof line - 1) break;
        }
        ESP_LOGW(TAG, "recent resets (newest first, battery: u = on USB, b = on battery%s): %s",
                 hist_from_flash ? "; RTC memory was lost, history continued from flash" : "", line);
    }
    health_coredump_boot_report();
    return s_reason;
}

const char *health_reset_name(void) { return s_reason; }

unsigned health_short_battery_runs(uint32_t max_run_s)
{
    /* Newest first: consecutive entries whose previous run was short, on battery, and ended in an uncounted
     * (power-on type) reset with RTC memory kept. The current boot's own entry is the newest one. */
    unsigned streak = 0;
    const uint32_t cnt = s_hist.n < HIST_N ? s_hist.n : HIST_N;
    for (uint32_t i = 0; i < cnt; i++) {
        const hist_entry_t *h = &s_hist.e[(s_hist.n - 1 - i) % HIST_N];
        const bool poweron = h->raw == 0x01;
        if (!(h->rtc_kept && poweron && !h->bat_usb && h->prev_up_s > 0 && h->prev_up_s < max_run_s)) break;
        streak++;
    }
    return streak;
}

const char *health_prev_step_name(void)
{
    return s_prev_valid && s_prev.step < HEALTH_STEP_COUNT ? s_step_names[s_prev.step] : "-";
}

uint32_t health_prev_step_s(void) { return s_prev_valid ? s_prev.step_s : 0; }
uint32_t health_prev_last_update_s(void) { return s_prev_valid ? s_prev.up_s : 0; }

void health_get_resets(health_resets_t *out) { *out = s_resets; }

/* ------------------------------------------------------------------ bench faults (health.h) */

#if CONFIG_PIXELCLIP_BENCH_ROUTES
#include "esp_sleep.h"
#include <assert.h>

typedef struct {
    bool crash;
    char what[16];
} fault_t;

static volatile int s_sink;

static int __attribute__((noinline)) recurse(int depth)
{
    volatile uint8_t pad[256];
    pad[0] = (uint8_t)depth;
    vTaskDelay(1);   /* a context switch per level: FreeRTOS's stack check sees the overflow at once */
    if (s_sink == 0x7FFFFFFF) return depth;   /* never true; keeps the compiler from calling this infinite */
    return recurse(depth + 1) + pad[0];   /* not a tail call: every level keeps its 256 B */
}

static void fault_task(void *arg)
{
    fault_t f = *(fault_t *)arg;
    free(arg);
    vTaskDelay(pdMS_TO_TICKS(300));   /* let the response go out */
    ESP_LOGE(TAG, "bench: %s \"%s\" now", f.crash ? "crash" : "wedge", f.what);
    vTaskDelay(pdMS_TO_TICKS(50));
    if (f.crash) {
        if (strcmp(f.what, "abort") == 0) abort();
        if (strcmp(f.what, "assert") == 0) assert(s_sink == 0x5A5A5A5A);
        if (strcmp(f.what, "null") == 0) *(volatile int *)(uintptr_t)s_sink = 1;   /* s_sink == 0: store to NULL */
        if (strcmp(f.what, "stack") == 0) s_sink = recurse(0);
    } else if (strcmp(f.what, "sleep") == 0) {
        /* Light sleep with no wake source at all: only an RTC watchdog that counts in light sleep ends it. */
        esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);
        ESP_LOGE(TAG, "bench: light sleep with every wake source disabled; expect RTCWDT_SYS within %d s",
                 CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S);
        vTaskDelay(pdMS_TO_TICKS(50));
        for (;;) {
            esp_err_t err = esp_light_sleep_start();
            ESP_LOGE(TAG, "bench: esp_light_sleep_start returned %s (woke up?!): sleeping again", esp_err_to_name(err));
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    } else if (strcmp(f.what, "suspend") == 0) {
        vTaskSuspendAll();          /* this core's scheduler stops: the controller (CPU0, priority 1) never runs */
        for (;;) s_sink++;
    } else if (strcmp(f.what, "irqoff") == 0) {
        portDISABLE_INTERRUPTS();   /* the interrupt watchdog (level 4) still fires: panic + core dump */
        for (;;) s_sink++;
    }
    vTaskDelete(NULL);
}

static esp_err_t start_fault(bool crash, const char *what, bool pin_cpu0)
{
    fault_t *f = calloc(1, sizeof *f);
    if (!f) return ESP_ERR_NO_MEM;
    f->crash = crash;
    strlcpy(f->what, what, sizeof f->what);
    /* 4 KB: the "stack" crash needs a stack it can overflow quickly, the others need little. */
    if (xTaskCreatePinnedToCore(fault_task, "bench_fault", 4096, f, configMAX_PRIORITIES - 2, NULL,
                                pin_cpu0 ? 0 : tskNO_AFFINITY) != pdPASS) {
        free(f);
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

esp_err_t health_bench_crash(const char *kind)
{
    static const char *const kinds[] = { "abort", "assert", "null", "stack" };
    for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++) {
        if (kind && strcmp(kind, kinds[i]) == 0) return start_fault(true, kind, false);
    }
    return ESP_ERR_INVALID_ARG;
}

esp_err_t health_bench_wedge(const char *mode)
{
    if (!mode) return ESP_ERR_INVALID_ARG;
    if (strcmp(mode, "sleep") == 0 || strcmp(mode, "suspend") == 0 || strcmp(mode, "irqoff") == 0) {
        return start_fault(false, mode, true);
    }
    for (int i = 0; i < HEALTH_SRC_COUNT; i++) {
        if (strcmp(mode, s_src_names[i]) == 0) {
            ESP_LOGE(TAG, "bench: the next %s beat blocks its task forever (silence limit %lu s, then the RTC watchdog)",
                     s_src_names[i], (unsigned long)(s_limit_ms[i] / 1000));
            s_wedge_src = (uint8_t)i;
            return ESP_OK;
        }
    }
    return ESP_ERR_INVALID_ARG;
}

#else

esp_err_t health_bench_crash(const char *kind) { return ESP_ERR_NOT_SUPPORTED; }
esp_err_t health_bench_wedge(const char *mode) { return ESP_ERR_NOT_SUPPORTED; }

#endif
