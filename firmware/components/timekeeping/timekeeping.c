/* timekeeping.c — system time + tz offset, persisted sync metadata and time anchor in NVS. */
#include "timekeeping.h"
#include "timekeeping_rule.h"

#include <sys/time.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "esp_system.h"
#include "esp_rom_sys.h"
#include "soc/reset_reasons.h"
#include "esp_timer.h"
#include "esp_log.h"

static const char *TAG = "time";
#define NVS_NS "time"
#define EPOCH_MIN TK_RULE_EPOCH_MIN         /* 2020-01-01: anything earlier is not a real clock */

static int32_t s_tz;
static int64_t s_last_sync;   /* epoch of the last POST /time */
static bool s_trusted;        /* clock continuity since the last sync */
static bool s_from_anchor;    /* clock rebuilt from the anchor at boot, no sync since */
static int64_t s_anchor_ref;  /* the anchor epoch it was rebuilt from */
static uint32_t s_boots;
static int64_t s_next_save_us; /* esp_timer time of the next periodic anchor save */
static SemaphoreHandle_t s_lock;
static uint32_t s_rtc_run;    /* RTC run id (NVS "rtc_run"): bumped whenever the RTC count was lost (anchor + uptime) */
static uint32_t s_set_run;    /* the rtc_run of the last exact set (NVS "set_run") */
static tk_how_t s_how;        /* how the clock was rebuilt at this boot */
static int64_t s_boot_anchor_age_s = -1;
static timekeeping_set_info_t s_set_info;   /* the last timekeeping_set() of this boot (RAM) */

static void lock(void) { if (s_lock) xSemaphoreTake(s_lock, portMAX_DELAY); }
static void unlock(void) { if (s_lock) xSemaphoreGive(s_lock); }

/* Caller holds the lock. */
static esp_err_t nvs_save(bool anchor)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    err = nvs_set_i32(h, "tz", s_tz);
    if (err == ESP_OK) err = nvs_set_i64(h, "last_sync", s_last_sync);
    if (err == ESP_OK) err = nvs_set_u8(h, "trusted", s_trusted ? 1 : 0);
    if (err == ESP_OK) err = nvs_set_u32(h, "boots", s_boots);
    if (err == ESP_OK) err = nvs_set_u32(h, "rtc_run", s_rtc_run);
    if (err == ESP_OK) err = nvs_set_u32(h, "set_run", s_set_run);
    if (err == ESP_OK && anchor && timekeeping_known()) err = nvs_set_i64(h, "anchor", timekeeping_now());
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

static void set_clock(int64_t epoch_s, int64_t usec)
{
    struct timeval tv = { .tv_sec = (time_t)epoch_s, .tv_usec = (suseconds_t)usec };
    if (settimeofday(&tv, NULL) != 0) ESP_LOGE(TAG, "settimeofday failed");
}

/* The reset's class for the rule (timekeeping_rule.h). ESP_RST_WDT also covers resets that clear the RTC domain (RTC
 * watchdog stage 1 "RTC reset", super watchdog, clock glitch): the RTC timer restarted from 0 there, nothing continued. */
static tk_rst_class_t rst_class(esp_reset_reason_t rr)
{
    const soc_reset_reason_t raw = esp_rom_get_reset_reason(0);
    if (raw == RESET_REASON_SYS_RTC_WDT || raw == RESET_REASON_SYS_SUPER_WDT || raw == RESET_REASON_SYS_CLK_GLITCH) {
        return TK_RST_LOST;
    }
    switch (rr) {
    case ESP_RST_SW:
    case ESP_RST_PANIC:
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT: return TK_RST_KEEPS;
    case ESP_RST_USB:
    case ESP_RST_JTAG: return TK_RST_KEEPS_EXT;
    case ESP_RST_DEEPSLEEP: return TK_RST_DEEPSLEEP;
    default: return TK_RST_LOST;
    }
}

esp_err_t timekeeping_init(void)
{
    if (!s_lock) s_lock = xSemaphoreCreateMutex();
    nvs_handle_t h;
    uint8_t trusted = 0;
    int64_t anchor = 0;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err == ESP_OK) {
        nvs_get_i32(h, "tz", &s_tz);          /* missing keys keep defaults */
        nvs_get_i64(h, "last_sync", &s_last_sync);
        nvs_get_u8(h, "trusted", &trusted);
        nvs_get_u32(h, "boots", &s_boots);
        nvs_get_i64(h, "anchor", &anchor);
        nvs_get_u32(h, "rtc_run", &s_rtc_run);   /* absent on a device older than the key: 0, bumped to 1 below */
        nvs_get_u32(h, "set_run", &s_set_run);
        nvs_close(h);
    } else {
        ESP_LOGE(TAG, "nvs_open: %s", esp_err_to_name(err));
    }
    s_boots++;

    /* The RTC timer keeps counting across software resets, panics and watchdog resets (and, with
     * TIMEKEEPING_KEEP_RTC_MORE, USB / JTAG resets and deep-sleep wakes), but is reset at power-on: the pure rule in
     * timekeeping_rule.c decides trust, how the clock is rebuilt and whether the RTC run broke. */
    esp_reset_reason_t rr = esp_reset_reason();
    const tk_boot_in_t in = {
        .rst = rst_class(rr),
#if CONFIG_TIMEKEEPING_KEEP_RTC_MORE
        .keep_more = true,
#else
        .keep_more = false,
#endif
        .trusted_nvs = trusted != 0,
        .anchor = anchor,
        .sys_now = timekeeping_now(),
        .uptime_us = esp_timer_get_time(),
    };
    tk_boot_out_t out;
    timekeeping_rule_boot(&in, &out);
    s_trusted = out.trusted;
    if (out.set_clock) set_clock(out.set_epoch_s, out.set_usec);
    s_from_anchor = out.from_anchor;
    s_anchor_ref = out.from_anchor ? anchor : 0;
    s_how = out.how;
    s_boot_anchor_age_s = out.anchor_age_s;
    if (out.new_run || s_rtc_run == 0) s_rtc_run++;
    const char *how = out.how == TK_HOW_ANCHOR ? ", approximate (anchor + time since boot)"
                      : out.from_anchor        ? ", approximate (RTC kept counting since the anchor)"
                                               : "";
    lock();
    err = nvs_save(false);
    unlock();
    if (err != ESP_OK) ESP_LOGE(TAG, "nvs save: %s", esp_err_to_name(err));
    s_next_save_us = esp_timer_get_time() + (int64_t)TIMEKEEPING_ANCHOR_PERIOD_S * 1000000;
    ESP_LOGI(TAG, "boot #%lu, reset reason %d, tz %ld, last sync %lld, anchor %lld, clock %s%s",
             (unsigned long)s_boots, (int)rr, (long)s_tz, (long long)s_last_sync, (long long)anchor,
             timekeeping_synced() ? "trusted" : timekeeping_known() ? "NOT synced" : "NOT synced, unknown (no anchor)", how);
    ESP_LOGI(TAG, "clock rebuilt %s, rtc_run %lu%s, anchor age %lld s", timekeeping_how_str(s_how),
             (unsigned long)s_rtc_run, out.new_run ? " (new run)" : "", (long long)s_boot_anchor_age_s);
    return ESP_OK;
}

esp_err_t timekeeping_set(int64_t epoch, int32_t tz_offset_s)
{
    lock();
    const bool was_known = timekeeping_known();
    const int64_t old_now = timekeeping_now();
    set_clock(epoch, 0);
    s_set_info.valid = true;
    s_set_info.run = s_rtc_run;
    s_set_info.prev_run = s_set_run;
    s_set_info.correction_known = was_known;
    s_set_info.correction_s = was_known ? epoch - old_now : 0;
    s_set_run = s_rtc_run;
    s_tz = tz_offset_s;
    s_last_sync = epoch;
    s_trusted = true;
    s_from_anchor = false;
    s_anchor_ref = 0;
    esp_err_t err = nvs_save(true);
    s_next_save_us = esp_timer_get_time() + (int64_t)TIMEKEEPING_ANCHOR_PERIOD_S * 1000000;
    unlock();
    ESP_LOGI(TAG, "time set: %lld tz %ld (rtc_run %lu, correction %s%lld s)", (long long)epoch, (long)tz_offset_s,
             (unsigned long)s_rtc_run, was_known ? "" : "unknown, ", (long long)s_set_info.correction_s);
    return err;
}

esp_err_t timekeeping_set_tz(int32_t tz_offset_s)
{
    lock();
    s_tz = tz_offset_s;
    esp_err_t err = nvs_save(false);
    unlock();
    return err;
}

int32_t timekeeping_tz(void) { return s_tz; }
uint32_t timekeeping_boot_count(void) { return s_boots; }

int64_t timekeeping_now_us(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000000 + tv.tv_usec;
}

int64_t timekeeping_now(void)
{
    return timekeeping_now_us() / 1000000;
}

bool timekeeping_synced(void)
{
    if (!s_trusted) return false;
    int64_t age = timekeeping_now() - s_last_sync;
    return age >= 0 && age < TIMEKEEPING_MAX_SYNC_AGE_S;
}

bool timekeeping_known(void)
{
    return (s_trusted || s_from_anchor) && timekeeping_now() >= EPOCH_MIN;
}

bool timekeeping_approximate(void)
{
    return timekeeping_known() && !timekeeping_synced();
}

int64_t timekeeping_anchor_age_s(void)
{
    if (!timekeeping_approximate()) return -1;
    const int64_t ref = s_trusted ? s_last_sync : s_anchor_ref;
    const int64_t age = timekeeping_now() - ref;
    return age > 0 ? age : 0;
}

esp_err_t timekeeping_save_anchor(void)
{
    if (!timekeeping_known()) return ESP_ERR_INVALID_STATE;
    lock();
    esp_err_t err = nvs_save(true);
    s_next_save_us = esp_timer_get_time() + (int64_t)TIMEKEEPING_ANCHOR_PERIOD_S * 1000000;
    unlock();
    if (err != ESP_OK) ESP_LOGE(TAG, "anchor save: %s", esp_err_to_name(err));
    else ESP_LOGD(TAG, "anchor saved: %lld", (long long)timekeeping_now());
    return err;
}

uint32_t timekeeping_service(void)
{
    const int64_t now = esp_timer_get_time();
    if (now >= s_next_save_us) {
        if (timekeeping_known()) {
            timekeeping_save_anchor();
        } else {
            s_next_save_us = now + (int64_t)TIMEKEEPING_ANCHOR_PERIOD_S * 1000000;
        }
    }
    const int64_t left = s_next_save_us - esp_timer_get_time();
    return left <= 0 ? 0 : (uint32_t)((left + 999) / 1000);
}

uint32_t timekeeping_rtc_run(void) { return s_rtc_run; }
int timekeeping_rebuilt_how(void) { return (int)s_how; }
const char *timekeeping_rebuilt_how_str(void) { return timekeeping_how_str(s_how); }
int64_t timekeeping_boot_anchor_age_s(void) { return s_boot_anchor_age_s; }

bool timekeeping_last_set(timekeeping_set_info_t *out)
{
    lock();
    const timekeeping_set_info_t i = s_set_info;
    unlock();
    if (out) *out = i;
    return i.valid;
}
