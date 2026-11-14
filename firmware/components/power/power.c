/* power.c — battery ADC, USB presence, PM locks (per-owner accounting), session battery policy, deep sleep. */
#include "power.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_pm.h"
#include "esp_sleep.h"
#include "driver/rtc_io.h"
#include "esp_private/esp_sleep_internal.h"   /* rc_fast_keep_for_deep_sleep() */
#include "soc/rtc.h"
#include "driver/gpio.h"
#include "driver/usb_serial_jtag.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_check.h"
#include "sdkconfig.h"
#include "timekeeping.h"
#include "health.h"
#include "esp_attr.h"
#include "esp_rtc_time.h"   /* esp_rtc_get_time_us(): power_deep_sleep_entry_rtc_us() */

static const char *TAG = "power";

#define BAT_ADC_GPIO    CONFIG_HAIRCLIP_BAT_ADC_GPIO   /* Kconfig: 1 on the Waveshare board, 4 on the LilyGo */
#define BAT_ADC_ATTEN   ADC_ATTEN_DB_12
#define AVG_N           4
#define HARD_FLOOR_MV   3400            /* HARDWARE.md §8: deep-sleep at 3.40 V, before the pack PCM cuts */
#define WIFI_FLOOR_MV   3500
#define MIN_PLAUSIBLE_MV 2500           /* below this the reading is a wiring/ADC fault, not a cell */
#define USB_GUESS_MV    4250            /* above any loaded cell voltage: USB rail present */
#define USB_PROXY_WINDOW 5              /* one-second Vbat reads considered for the VBUS proxy ... */
#define USB_PROXY_NEEDED 3              /* ... of which this many must be >= USB_GUESS_MV */
#define SESSION_LOW_MV  3900            /* on battery: a session blanks the panel below this (averaged) */
#define POWER_TASK_STACK 4096           /* ADC oneshot + logging + health crumbs; was seen at 1 KB free with 3072 */
#define TICK_MS         1000            /* USB presence + session minimum: every second */
#define DUMP_BYTES      2048            /* esp_pm_dump_locks() text (PSRAM, only while parsing it) */
#define USB_HOLD_RELEASE_US (5 * 1000000LL)   /* the USB hold goes once usb_present has been false this long */
#define USB_HOLD_SLACK_US   (2 * 1000000LL)   /* + this much tick jitter before the check calls it a leak */

/* The USB hold (README "USB light-sleep inhibit"): POWER_AWAKE_USB while usb_present, released 5 s after it went
 * false. Not in the light-sleep soak build, which light-sleeps on USB on purpose (README "Light sleep on
 * battery", bench reproduction). */
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST
#define USB_HOLD_ENABLED 0
#else
#define USB_HOLD_ENABLED 1
#endif

static adc_oneshot_unit_handle_t s_adc;
static adc_unit_t s_adc_unit = ADC_UNIT_1;
static adc_channel_t s_adc_chan = ADC_CHANNEL_0;   /* resolved from BAT_ADC_GPIO in power_init() */
static adc_cali_handle_t s_cali;
static esp_pm_lock_handle_t s_perf_lock;
static power_event_cb_t s_cb;
static SemaphoreHandle_t s_mutex;
static int s_samples[AVG_N];
static int s_nsamples, s_sample_pos;
static power_battery_t s_bat;
static bool s_bat_valid;                /* at least one plausible reading */
static volatile uint8_t s_low_pct = 8;
static uint8_t s_vbus_hist;             /* bit i = the read i seconds ago was >= USB_GUESS_MV */
static volatile bool s_session;         /* a WiFi session is running (power_session) */
static volatile bool s_session_restart; /* session ended: restart the moving average */
static volatile int s_session_min_mv;
static volatile int s_perf_held[POWER_PERF_OWNERS];
static volatile uint32_t s_perf_errors;
static portMUX_TYPE s_perf_mux = portMUX_INITIALIZER_UNLOCKED;
static const char *const s_owner_names[POWER_PERF_OWNERS] = { "transient", "scene", "strip", "session", "oracle" };
static esp_pm_lock_handle_t s_awake_lock;
static volatile int s_awake_held[POWER_AWAKE_OWNERS];
static volatile int s_awake_total;                     /* sum of s_awake_held (read by the sleep callback) */
static volatile uint32_t s_awake_violations;
static volatile uint32_t s_light_sleeps;
static void rc_fast_keep_for_deep_sleep(void);
static const char *const s_awake_names[POWER_AWAKE_OWNERS] = { "session", "fastlane", "usb", "poweroff", "panel" };
static volatile bool s_usb_flag;        /* usb_present as the light-sleep callback sees it (set after the hold) */
static volatile uint32_t s_ls_while_usb;   /* light sleeps entered while s_usb_flag (must stay 0) */
static bool s_usb_hold;                 /* POWER_AWAKE_USB taken by usb_hold_set() (power task / init only) */
static int64_t s_usb_gone_us;           /* when usb_present was first seen false with the hold still on, 0 = n/a */

/* LiPo discharge curve (mV -> %) at light load, rescaled so that 0 % is the 3.40 V firmware cutoff
 * (HARDWARE.md §8), not the cell's absolute empty point. The default low_battery_pct of 8 % trips
 * at ~3.66 V (so ~2 x 30 s later the clip is asleep well above 3.40 V even with display-on sag). */
static const struct { int mv, pct; } s_curve[] = {
    {4200, 100}, {4150, 95}, {4110, 90}, {4080, 85}, {4020, 80}, {3980, 75}, {3950, 70},
    {3910, 65}, {3870, 60}, {3850, 55}, {3840, 50}, {3820, 45}, {3800, 40}, {3790, 35},
    {3770, 30}, {3750, 25}, {3730, 20}, {3710, 15}, {3690, 10}, {3610, 5}, {3400, 0},
};

static int mv_to_pct(int mv)
{
    const int n = sizeof s_curve / sizeof s_curve[0];
    if (mv >= s_curve[0].mv) return 100;
    if (mv <= s_curve[n - 1].mv) return 0;
    for (int i = 1; i < n; i++) {
        if (mv >= s_curve[i].mv) {
            int dmv = s_curve[i - 1].mv - s_curve[i].mv;
            int dp = s_curve[i - 1].pct - s_curve[i].pct;
            return s_curve[i].pct + (mv - s_curve[i].mv) * dp / dmv;
        }
    }
    return 0;
}

static int read_battery_mv(void)
{
    if (!s_adc) return 0;
    int sum = 0, ok = 0;
    for (int i = 0; i < 8; i++) {
        int raw, mv;
        if (adc_oneshot_read(s_adc, s_adc_chan, &raw) != ESP_OK) continue;
        if (s_cali) {
            if (adc_cali_raw_to_voltage(s_cali, raw, &mv) != ESP_OK) continue;
        } else {
            mv = raw * 3300 / 4095;
        }
        sum += mv;
        ok++;
    }
    return ok ? (sum / ok) * 2 : 0; /* 100k/100k divider */
}

/* VBUS proxy: at least USB_PROXY_NEEDED of the last USB_PROXY_WINDOW one-second reads were >= 4.25 V. */
static bool vbus_proxy(void)
{
    return __builtin_popcount(s_vbus_hist & ((1u << USB_PROXY_WINDOW) - 1)) >= USB_PROXY_NEEDED;
}

/* A bench hook for other projects that reuse this component (this firmware does not call it): for N seconds the
 * power task behaves as if no cable were there (usb_present false, the usb hold dropped after its 5 s, so the chip
 * naps and the automatic offs run as on a cell), then takes the hold again so the host can find the chip. */
static volatile int64_t s_test_no_usb_until_us;
void power_test_no_usb(uint32_t secs)
{
    s_test_no_usb_until_us = secs ? esp_timer_get_time() + (int64_t)secs * 1000000 : 0;
    ESP_LOGW(TAG, "test: no cable for %lu s", (unsigned long)secs);
}

/* Take / drop the USB hold (power task, or power_init before the power task exists). */
static void usb_hold_set(bool on)
{
#if USB_HOLD_ENABLED
    if (on == s_usb_hold) return;
    if (on) {
        power_awake_acquire(POWER_AWAKE_USB);   /* lock first: the light-sleep callback never sees the flag without it */
        s_usb_hold = true;
        ESP_LOGI(TAG, "USB present: light sleep inhibited (usb hold, until 5 s after USB goes)");
    } else {
        s_usb_hold = false;
        power_awake_release(POWER_AWAKE_USB);
        ESP_LOGI(TAG, "USB gone for 5 s: light sleep allowed (usb hold released)");
    }
    health_note_usb_hold(on);
#endif
}

/* Every second (power task): USB presence and the session minimum. `inst` = an instantaneous read or 0.
 * The USB hold follows usb_present: taken here BEFORE usb_present = true is published (so nothing ever sees USB
 * present without the hold behind it), dropped once usb_present has been false for USB_HOLD_RELEASE_US
 * (debounce: a missed SOF sample or a VBUS-proxy flicker never lets the chip light-sleep on USB). */
static bool update_usb(int inst)
{
    const bool sof = usb_serial_jtag_is_connected();   /* not sticky: cleared ~3 ms after the last SOF */
    health_note_usb(sof);
    if (inst >= MIN_PLAUSIBLE_MV) s_vbus_hist = (uint8_t)((s_vbus_hist << 1) | (inst >= USB_GUESS_MV ? 1 : 0));
    else if (sof) s_vbus_hist = (uint8_t)(s_vbus_hist << 1);   /* no read needed while a host is there */
    bool usb = sof || vbus_proxy();
    const int64_t now_us = esp_timer_get_time();
    if (s_test_no_usb_until_us) {   /* power_test_no_usb(): the cable is not seen until then; then awake for the host */
        if (now_us < s_test_no_usb_until_us) {
            usb = false;
        } else {
            s_test_no_usb_until_us = 0;
            usb_hold_set(true);
            s_usb_gone_us = now_us;   /* the usual 5 s to see the host again, else the hold goes as on a cell */
            ESP_LOGW(TAG, "test: the cable is seen again");
        }
    }
    if (usb) {
        usb_hold_set(true);
        s_usb_gone_us = 0;
    }
    s_usb_flag = usb;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const bool changed = s_bat.usb_present != usb;
    s_bat.usb_present = usb;
    s_bat.usb_sof = sof;
    s_bat.charging = usb && s_bat_valid && s_bat.mv < 4150;
    xSemaphoreGive(s_mutex);
    if (changed) {
        ESP_LOGI(TAG, "USB %s (%s)", usb ? "present" : "gone", sof ? "host SOF" : usb ? "Vbat >= 4.25 V" : "no SOF, Vbat below 4.25 V");
    }
    if (!usb && s_usb_hold) {
        if (!s_usb_gone_us) {
            s_usb_gone_us = now_us;
        } else if (now_us - s_usb_gone_us >= USB_HOLD_RELEASE_US) {
            usb_hold_set(false);
            s_usb_gone_us = 0;
        }
    }
    /* Host SOF edges with their time, also while the VBUS proxy keeps usb_present (README "USB console").
     * The "lost" line never reaches the host; the "back" line does when the console survives the
     * re-enumeration (scripts/serial_capture.py no longer resets the chip when it reopens the port). */
    static bool s_sof_prev;
    static int64_t s_sof_lost_us;
    if (sof != s_sof_prev) {
        const int64_t now = esp_timer_get_time();
        if (!sof) {
            s_sof_lost_us = now;
            ESP_LOGW(TAG, "USB host SOF lost at %lld s (host suspended / detached the port, or cable)", now / 1000000);
        } else if (s_sof_lost_us) {
            ESP_LOGW(TAG, "USB host SOF back at %lld s after %lld s without (lost at %lld s)", now / 1000000,
                     (now - s_sof_lost_us) / 1000000, s_sof_lost_us / 1000000);
        }
        s_sof_prev = sof;
    }
    return changed;
}

/* Averaged sample (every CONFIG_HAIRCLIP_BATTERY_SAMPLE_S). */
static void sample(int mv)
{
    if (mv < MIN_PLAUSIBLE_MV) {
        /* Never act on garbage: a failed/implausible read must not trigger the low-battery
         * shutdown (that would put the clip to sleep a minute after every boot). */
        ESP_LOGE(TAG, "battery ADC read failed or implausible (%d mV)", mv);
        return;
    }
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    s_bat_valid = true;
    s_samples[s_sample_pos] = mv;
    s_sample_pos = (s_sample_pos + 1) % AVG_N;
    if (s_nsamples < AVG_N) s_nsamples++;
    int sum = 0;
    for (int i = 0; i < s_nsamples; i++) sum += s_samples[i];
    s_bat.mv = sum / s_nsamples;
    s_bat.pct = mv_to_pct(s_bat.mv);
    s_bat.charging = s_bat.usb_present && s_bat.mv < 4150;
    xSemaphoreGive(s_mutex);
}

static void restart_average(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    s_nsamples = 0;
    s_sample_pos = 0;
    xSemaphoreGive(s_mutex);
}

/* Every second after update_usb(): the USB hold must match usb_present (README "USB light-sleep inhibit").
 * Logged once per episode in production, fatal in the bench builds. */
static void usb_hold_check(void)
{
    static bool s_reported;
    const int held = s_awake_held[POWER_AWAKE_USB];
    const bool usb = s_usb_flag;
    const char *bad = NULL;
#if USB_HOLD_ENABLED
    const int64_t gone_for = s_usb_gone_us ? esp_timer_get_time() - s_usb_gone_us : 0;
    if (held != (s_usb_hold ? 1 : 0) || held > 1) bad = "hold count does not match the hold flag";
    else if (usb && !held) bad = "usb_present without the usb hold";
    else if (!usb && held && (!s_usb_gone_us || gone_for > USB_HOLD_RELEASE_US + USB_HOLD_SLACK_US)) bad = "usb hold kept more than 5 s after usb_present went false";
    else if (s_ls_while_usb) bad = "light sleep entered while usb_present";
#else
    if (held) bad = "usb hold taken in the light-sleep soak build";
#endif
    if (!bad) {
        if (!s_ls_while_usb) s_reported = false;
        return;
    }
    if (s_reported) return;
    s_reported = true;
    ESP_LOGE(TAG, "ASSERTION: %s (usb_present %d, usb hold %d, light sleeps %lu, while usb %lu)", bad, usb, held,
             (unsigned long)s_light_sleeps, (unsigned long)s_ls_while_usb);
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST || CONFIG_PIXELCLIP_BENCH_STRESS
    abort();
#endif
}

static void power_task(void *arg)
{
    int low_count = 0;
    uint32_t tick = 0;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(TICK_MS));
        tick++;
        health_beat(HEALTH_SRC_POWER);   /* liveness: the power task (USB presence, battery) ticks every second */
        const bool in_session = s_session;
        int inst = 0;
        /* One ADC read per second only when it matters: no host SOF (VBUS proxy) or a session (minimum). */
        if (!usb_serial_jtag_is_connected() || in_session) inst = read_battery_mv();
        if (in_session && inst >= MIN_PLAUSIBLE_MV && (s_session_min_mv == 0 || inst < s_session_min_mv)) {
            s_session_min_mv = inst;
        }
        if (inst >= MIN_PLAUSIBLE_MV) health_note_battery(inst, usb_serial_jtag_is_connected());   /* RTC crumb: the reading just before a reset */
        if (update_usb(inst) && s_cb) s_cb(POWER_EVT_USB_CHANGED);
        usb_hold_check();
        if (s_session_restart) {
            /* The session's readings sagged under WiFi TX: start the average again from the rested cell,
             * so no post-session decision (low battery = deep sleep) is taken on them. */
            s_session_restart = false;
            restart_average();
            low_count = 0;
            sample(inst >= MIN_PLAUSIBLE_MV ? inst : read_battery_mv());
            continue;
        }
        if (tick % CONFIG_HAIRCLIP_BATTERY_SAMPLE_S != 0) continue;

        sample(inst >= MIN_PLAUSIBLE_MV ? inst : read_battery_mv());
        power_battery_t b;
        power_get_battery(&b);
        ESP_LOGI(TAG, "battery %d mV (%d%%)%s%s%s", b.mv, b.pct, b.usb_present ? " usb" : "",
                 b.valid ? "" : " [no valid reading]", in_session ? " [session]" : "");
        if (b.valid) health_note_battery(b.mv, b.usb_present);
        if (b.usb_present || !b.valid) {
            low_count = 0;
            continue;
        }
        bool low = (s_low_pct > 0 && b.pct <= s_low_pct) || b.mv < HARD_FLOOR_MV;
        if (in_session) {
            /* Brief sags under WiFi TX must not shut the clip down: in a session "low" only ends the
             * session; the average restarts afterwards and decides on rested readings. */
            if (low || b.mv < WIFI_FLOOR_MV) {
                ESP_LOGW(TAG, "battery %d mV in a session (min %d mV): ending the session, not powering off", b.mv,
                         s_session_min_mv);
                if (s_cb) s_cb(POWER_EVT_WEAK_FOR_WIFI);
            } else if (b.mv < SESSION_LOW_MV && s_cb) {
                s_cb(POWER_EVT_SESSION_LOW);
            }
            low_count = 0;
            continue;
        }
        if (b.mv < WIFI_FLOOR_MV && s_cb) s_cb(POWER_EVT_WEAK_FOR_WIFI);
        low_count = low ? low_count + 1 : 0;
        if (low_count >= 2 && s_cb) s_cb(POWER_EVT_LOW_BATTERY);
    }
}

/* esp_pm light-sleep callbacks (CONFIG_PM_LIGHT_SLEEP_CALLBACKS): run in the idle task with the PM switch lock
 * held, so IRAM and non-blocking. They record the entry / exit in the RTC breadcrumbs (a clip that dies in light
 * sleep says so at the next boot) and count entries made while an awake hold was held, and while usb_present was
 * true (both must never happen: the NO_LIGHT_SLEEP lock forbids them). */
#if CONFIG_PM_LIGHT_SLEEP_CALLBACKS
static esp_err_t IRAM_ATTR ls_enter_cb(int64_t sleep_time_us, void *arg)
{
    s_light_sleeps++;
    if (s_awake_total > 0) s_awake_violations++;
    const bool usb = s_usb_flag;
    if (usb) s_ls_while_usb++;
    health_ls_enter(usb);
    return ESP_OK;
}

static esp_err_t IRAM_ATTR ls_exit_cb(int64_t slept_us, void *arg)
{
    health_ls_exit();
    return ESP_OK;
}
#endif

esp_err_t power_init(power_event_cb_t cb)
{
    s_cb = cb;
    s_mutex = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_mutex, ESP_ERR_NO_MEM, TAG, "no mem");

    /* PM and ADC failures are logged and survived: the clip then simply runs at full speed or
     * without battery monitoring instead of refusing to boot. */
    esp_err_t err = esp_pm_lock_create(ESP_PM_CPU_FREQ_MAX, 0, "perf", &s_perf_lock);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "pm lock: %s", esp_err_to_name(err));
        s_perf_lock = NULL;
    }
    err = esp_pm_lock_create(ESP_PM_NO_LIGHT_SLEEP, 0, "awake", &s_awake_lock);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "awake lock: %s", esp_err_to_name(err));
        s_awake_lock = NULL;
    }
    err = adc_oneshot_io_to_channel(BAT_ADC_GPIO, &s_adc_unit, &s_adc_chan);
    if (err == ESP_OK && s_adc_unit != ADC_UNIT_1) err = ESP_ERR_NOT_SUPPORTED;   /* ADC2 conflicts with WiFi */
    adc_oneshot_unit_init_cfg_t unit = { .unit_id = s_adc_unit };
    adc_oneshot_chan_cfg_t ch = { .bitwidth = ADC_BITWIDTH_12, .atten = BAT_ADC_ATTEN };
    if (err == ESP_OK) err = adc_oneshot_new_unit(&unit, &s_adc);
    if (err == ESP_OK) err = adc_oneshot_config_channel(s_adc, s_adc_chan, &ch);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "battery ADC unavailable: %s (no battery monitoring)", esp_err_to_name(err));
        if (s_adc) adc_oneshot_del_unit(s_adc);
        s_adc = NULL;
    } else {
        /* ESP32-S3: curve fitting is the eFuse-backed scheme (same as the Waveshare ADC demo). */
        adc_cali_curve_fitting_config_t cali = {
            .unit_id = s_adc_unit, .chan = s_adc_chan, .atten = BAT_ADC_ATTEN, .bitwidth = ADC_BITWIDTH_12,
        };
        err = adc_cali_create_scheme_curve_fitting(&cali, &s_cali);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "ADC calibration unavailable (%s), using raw scale", esp_err_to_name(err));
            s_cali = NULL;
        }
    }
    const int mv0 = read_battery_mv();
    if (mv0 >= USB_GUESS_MV) s_vbus_hist = (1u << USB_PROXY_WINDOW) - 1;   /* first guess from one read */
    sample(mv0);
    update_usb(0);
    ESP_LOGI(TAG, "battery %d mV (%d%%)%s%s", s_bat.mv, s_bat.pct,
             s_bat.usb_present ? (s_bat.usb_sof ? ", USB present (host)" : ", USB present (Vbat >= 4.25 V)") : "",
             s_bat_valid ? "" : " [no valid reading]");

    /* Light sleep is enabled only now: the first USB evaluation above has already taken the USB hold if a host
     * or charger is there, so a USB-powered clip never light-sleeps, not even between here and the first tick. */
    esp_pm_config_t pm = {
        .max_freq_mhz = CONFIG_HAIRCLIP_CPU_MAX_MHZ,
        .min_freq_mhz = CONFIG_HAIRCLIP_CPU_MIN_MHZ,
#if CONFIG_HAIRCLIP_AUTO_LIGHT_SLEEP
        .light_sleep_enable = true,
#else
        .light_sleep_enable = false,
#endif
    };
    rc_fast_keep_for_deep_sleep();   /* 2026-11-12: before the first nap too (see the function) */
    err = esp_pm_configure(&pm);
    if (err == ESP_OK) {
        /* Light sleep is additionally blocked while usb_present (the USB hold, taken above before light sleep
         * was enabled), so the USB console survives on the bench (README "USB light-sleep inhibit"). */
        ESP_LOGI(TAG, "PM: %d..%d MHz, auto light sleep %s", pm.min_freq_mhz, pm.max_freq_mhz,
                 pm.light_sleep_enable ? "on" : "off");
#if CONFIG_PM_LIGHT_SLEEP_CALLBACKS
        esp_pm_sleep_cbs_register_config_t cbs = { .enter_cb = ls_enter_cb, .exit_cb = ls_exit_cb };
        if (esp_pm_light_sleep_register_cbs(&cbs) != ESP_OK) ESP_LOGW(TAG, "light-sleep callbacks not registered");
#endif
    } else {
        ESP_LOGE(TAG, "esp_pm_configure: %s (running without DFS / light sleep)", esp_err_to_name(err));
    }

    BaseType_t ok = xTaskCreate(power_task, "power", POWER_TASK_STACK, NULL, 2, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "task");
    return ESP_OK;
}

void power_set_low_battery_pct(uint8_t pct) { s_low_pct = pct; }

void power_get_battery(power_battery_t *out)
{
    if (!s_mutex) {             /* power_init() never ran */
        *out = (power_battery_t){ 0 };
        return;
    }
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    *out = s_bat;
    out->valid = s_bat_valid;
    xSemaphoreGive(s_mutex);
}

bool power_on_battery(void)
{
    power_battery_t b;
    power_get_battery(&b);
    return b.valid && !b.usb_present;
}

void power_session(bool active)
{
    if (active) {
        s_session_min_mv = 0;
        s_session = true;
        return;
    }
    if (!s_session) return;
    s_session = false;
    s_session_restart = true;
    ESP_LOGI(TAG, "session battery minimum: %d mV%s", s_session_min_mv,
             s_session_min_mv ? "" : " (no reading: USB host present or session < 1 s)");
}

int power_session_min_mv(void) { return s_session_min_mv; }

void power_perf_acquire(power_perf_owner_t owner)
{
    if (owner >= POWER_PERF_OWNERS) return;
    portENTER_CRITICAL(&s_perf_mux);
    s_perf_held[owner]++;
    portEXIT_CRITICAL(&s_perf_mux);
    if (!s_perf_lock) return;
    esp_err_t err = esp_pm_lock_acquire(s_perf_lock);
    if (err != ESP_OK) ESP_LOGE(TAG, "perf acquire: %s", esp_err_to_name(err));
}

void power_perf_release(power_perf_owner_t owner)
{
    if (owner >= POWER_PERF_OWNERS) return;
    bool ok = true;
    portENTER_CRITICAL(&s_perf_mux);
    if (s_perf_held[owner] > 0) {
        s_perf_held[owner]--;
    } else {
        ok = false;
        s_perf_errors++;
    }
    portEXIT_CRITICAL(&s_perf_mux);
    if (!ok) {
        /* Never release the shared lock for a hold that does not exist: that would cut another owner's. */
        ESP_LOGE(TAG, "PM LOCK ACCOUNTING: release of '%s' without an acquire (ignored)", s_owner_names[owner]);
        return;
    }
    if (!s_perf_lock) return;
    esp_err_t err = esp_pm_lock_release(s_perf_lock);
    if (err != ESP_OK) ESP_LOGE(TAG, "perf release: %s", esp_err_to_name(err));
}

void power_awake_acquire(power_awake_owner_t owner)
{
    if (owner >= POWER_AWAKE_OWNERS) return;
    /* Lock first, count second (and the reverse on release): the light-sleep callback never sees a count
     * without the lock behind it, so every violation it counts is real. */
    if (s_awake_lock) {
        esp_err_t err = esp_pm_lock_acquire(s_awake_lock);
        if (err != ESP_OK) ESP_LOGE(TAG, "awake acquire: %s", esp_err_to_name(err));
    }
    portENTER_CRITICAL(&s_perf_mux);
    s_awake_held[owner]++;
    s_awake_total++;
    portEXIT_CRITICAL(&s_perf_mux);
}

void power_awake_release(power_awake_owner_t owner)
{
    if (owner >= POWER_AWAKE_OWNERS) return;
    bool ok = true;
    portENTER_CRITICAL(&s_perf_mux);
    if (s_awake_held[owner] > 0) {
        s_awake_held[owner]--;
        s_awake_total--;
    } else {
        ok = false;
        s_perf_errors++;
    }
    portEXIT_CRITICAL(&s_perf_mux);
    if (!ok) {
        ESP_LOGE(TAG, "PM LOCK ACCOUNTING: awake release of '%s' without an acquire (ignored)", s_awake_names[owner]);
        return;
    }
    if (s_awake_lock) {
        esp_err_t err = esp_pm_lock_release(s_awake_lock);
        if (err != ESP_OK) ESP_LOGE(TAG, "awake release: %s", esp_err_to_name(err));
    }
}

int power_awake_held(power_awake_owner_t owner) { return owner < POWER_AWAKE_OWNERS ? s_awake_held[owner] : 0; }
uint32_t power_awake_violations(void) { return s_awake_violations; }
uint32_t power_light_sleeps(void) { return s_light_sleeps; }
uint32_t power_light_sleeps_while_usb(void) { return s_ls_while_usb; }
bool power_usb_hold(void) { return s_awake_held[POWER_AWAKE_USB] > 0; }

int power_perf_held(power_perf_owner_t owner) { return owner < POWER_PERF_OWNERS ? s_perf_held[owner] : 0; }

uint32_t power_perf_errors(void) { return s_perf_errors; }

void power_perf_report(char *buf, size_t len)
{
    size_t n = 0;
    if (len) buf[0] = '\0';
    for (int i = 0; i < POWER_PERF_OWNERS && n < len; i++) {
        int w = snprintf(buf + n, len - n, "%s%s=%d", i ? " " : "", s_owner_names[i], s_perf_held[i]);
        if (w < 0) break;
        n += (size_t)w;
    }
}

int power_pm_locks_summary(char *buf, size_t len)
{
    if (!len) return -1;
    buf[0] = '\0';
    char *dump = heap_caps_malloc(DUMP_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);   /* only while it runs */
    if (!dump) return -1;
    FILE *f = fmemopen(dump, DUMP_BYTES - 1, "w");
    if (!f) {
        free(dump);
        return -1;
    }
    esp_pm_dump_locks(f);
    const long used = ftell(f);
    fclose(f);
    dump[used > 0 && used < DUMP_BYTES ? used : DUMP_BYTES - 1] = '\0';
    /* Lines: "<name 15> <type 14>  <arg 5>  <active 8>" after a "Lock stats:" and a header line. */
    int held = 0;
    size_t n = 0;
    char *save = NULL;
    for (char *line = strtok_r(dump, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char name[20], type[20];
        int arg, active;
        if (sscanf(line, "%19s %19s %d %d", name, type, &arg, &active) != 4 || active <= 0) continue;
        if (strncmp(name, "rtos", 4) == 0) continue;   /* the running task's own core lock */
        held++;
        int w = snprintf(buf + n, len - n, "%s%s/%s x%d", n ? ", " : "", name, type, active);
        if (w < 0 || (size_t)w >= len - n) break;
        n += (size_t)w;
    }
    free(dump);
    if (!held) snprintf(buf, len, "none");
    return held;
}

bool power_pm_sleep_stats(uint32_t *sleeps, uint32_t *rejects, int *sleep_pct)
{
#if CONFIG_PM_PROFILING
    char *dump = heap_caps_malloc(DUMP_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!dump) return false;
    FILE *f = fmemopen(dump, DUMP_BYTES - 1, "w");
    if (!f) {
        free(dump);
        return false;
    }
    esp_pm_dump_locks(f);
    const long used = ftell(f);
    fclose(f);
    dump[used > 0 && used < DUMP_BYTES ? used : DUMP_BYTES - 1] = '\0';
    bool ok = false;
    char *save = NULL;
    for (char *line = strtok_r(dump, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        long a, b;
        int pct;
        long long t;
        char m[8];
        if (sscanf(line, "light_sleep_counts:%ld light_sleep_reject_counts:%ld", &a, &b) == 2) {
            *sleeps = (uint32_t)a;
            *rejects = (uint32_t)b;
            ok = true;
        } else if (strncmp(line, "SLEEP", 5) == 0 && sscanf(line, "SLEEP %*d %7s %lld %d", m, &t, &pct) == 3) {
            *sleep_pct = pct;
        }
    }
    free(dump);
    return ok;
#else
    return false;
#endif
}

static uint32_t s_deep_timer_s;   /* power_deep_sleep_arm_timer(): 0 = none (always, in this firmware) */
static RTC_NOINIT_ATTR int64_t s_deep_entry_rtc_us;   /* power_deep_sleep_entry_rtc_us() */

int64_t power_deep_sleep_entry_rtc_us(void) { return s_deep_entry_rtc_us; }

/* ESP-IDF 5.5 and the RC_FAST/256 slow clock (CONFIG_RTC_CLK_SRC_INT_8MD256): the "keep RC_FAST on in deep sleep"
 * reference is taken only when the slow-clock source CHANGES to RC_FAST_D256 (rtc_clk.c). The select register lives
 * in the RTC domain and survives SW, panic, WDT, USB-serial and JTAG resets, so after any of those the app finds the
 * source already set, takes no reference, and esp_deep_sleep_start() powers RC_FAST down: the RTC then has no clock
 * and neither the timer nor ext0/ext1 can ever wake the chip (seen 2026-11-07 on two boards; every test had followed
 * a USB reset). Take the reference ourselves when it is missing. */
/* 2026-11-12: the same holds for LIGHT sleep (get_sleep_flags() in sleep_modes.c uses the one reference for both):
 * after a USB-serial or software reset every automatic nap powered RC_FAST down, and the first nap never ended: no
 * timer, no key, no touch, the RTC watchdog paused in sleep, the chip dark until RST. Seen on a board reusing this
 * component after each flash, once the cable was pulled and the panel went dark (the first naps of the boot), and on
 * the bench with power_test_no_usb(); a boot after RST or power-on was never affected, which is why it looked
 * random. So the reference is also taken in power_init(), before light sleep is enabled; the two deep-sleep entries keep their call. */
static void rc_fast_keep_for_deep_sleep(void)
{
#if SOC_RTC_SLOW_CLK_SUPPORT_RC_FAST_D256
    if (rtc_clk_slow_src_get() != SOC_RTC_SLOW_CLK_SRC_RC_FAST_D256) return;
    int32_t *cnt = esp_sleep_sub_mode_dump_config(NULL);
    if (cnt && cnt[ESP_SLEEP_RTC_USE_RC_FAST_MODE] == 0) {
        esp_sleep_sub_mode_config(ESP_SLEEP_RTC_USE_RC_FAST_MODE, true);
        ESP_LOGI(TAG, "RC_FAST kept on in sleep (slow clock is RC_FAST/256, reference was 0)");
    }
#endif
}

/* 2026-11-12: no esp_pm nap from here to esp_deep_sleep_start(). The entries below clear esp_pm's timer trigger
 * (esp_sleep_disable_wakeup_source), but the 50 ms log drain and the entry callback (an NVS write) come after it, the
 * idle task naps once more in them, and every nap arms that timer again. Seen on a board reusing this component on
 * battery: after each auto off the chip woke at once by "timer (4)" with no timer armed and ran another hour. On USB
 * the usb hold already keeps this lock, which is why no test on a cable showed it. Never released: the chip does not come back from these functions. */
static void deep_sleep_no_nap(void)
{
    if (!s_awake_lock) return;
    const esp_err_t err = esp_pm_lock_acquire(s_awake_lock);
    if (err != ESP_OK) ESP_LOGE(TAG, "deep sleep: awake lock: %s", esp_err_to_name(err));
}

void power_deep_sleep(void)
{
    ESP_LOGI(TAG, "entering deep sleep, wake on BOOT (GPIO0)%s", s_deep_timer_s ? " + RTC timer" : "");
    deep_sleep_no_nap();
    health_wdt_stop();           /* last: it keeps counting in deep sleep and would end it; until here a hang in the
                                  * power-off choreography is still caught (2026-10-17: "stuck on bye" on battery) */
    timekeeping_save_anchor();   /* the RTC keeps counting in deep sleep; the anchor covers a power loss */
    /* Automatic light sleep (esp_pm) arms an RTC timer wake-up before every nap and leaves that trigger set
     * in esp_sleep's configuration; esp_deep_sleep_start() would inherit it and the clip would wake a few
     * milliseconds after powering off (seen on battery: "wake cause 4 (timer), reset DEEPSLEEP, previous run:
     * step power_off"). Only the BOOT button may wake a powered-off clip. */
    esp_err_t err = esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);
    /* power_deep_sleep_arm_timer(): this path plus a timer (an optional hook; this firmware never arms it) */
    if (s_deep_timer_s && err == ESP_OK) err = esp_sleep_enable_timer_wakeup((uint64_t)s_deep_timer_s * 1000000ULL);
    if (err == ESP_OK) err = rtc_gpio_pullup_en(GPIO_NUM_0);
    if (err == ESP_OK) err = rtc_gpio_pulldown_dis(GPIO_NUM_0);
    if (err == ESP_OK) err = esp_sleep_enable_ext0_wakeup(GPIO_NUM_0, 0);
    if (err != ESP_OK) ESP_LOGE(TAG, "wake config: %s", esp_err_to_name(err));
    rc_fast_keep_for_deep_sleep();
    vTaskDelay(pdMS_TO_TICKS(50)); /* let the log drain */
    s_deep_entry_rtc_us = (int64_t)esp_rtc_get_time_us();
    esp_deep_sleep_start();
}

void power_deep_sleep_wake(uint64_t ext1_mask, int ext0_gpio, int hold_low_gpio)
{
    power_deep_sleep_wake_ex(ext1_mask, false, ext0_gpio, hold_low_gpio, false);
}

void power_deep_sleep_arm_timer(uint32_t secs) { s_deep_timer_s = secs; }

static int s_deep_ext0_level;              /* power_deep_sleep_ext0_level(): 0 (default) or 1 */
static bool s_deep_gpio0_phantom;          /* power_deep_sleep_gpio0_phantom() */
static power_deep_entry_cb_t s_deep_entry_cb;

void power_deep_sleep_ext0_level(int level) { s_deep_ext0_level = level ? 1 : 0; }
void power_deep_sleep_gpio0_phantom(bool low) { s_deep_gpio0_phantom = low; }
void power_deep_sleep_set_entry_cb(power_deep_entry_cb_t cb) { s_deep_entry_cb = cb; }

void power_deep_sleep_wake_ex(uint64_t ext1_mask, bool ext1_high, int ext0_gpio, int hold_gpio, bool hold_high)
{
    char timer[24] = "";
    if (s_deep_timer_s) snprintf(timer, sizeof timer, " timer %lu s", (unsigned long)s_deep_timer_s);
    ESP_LOGI(TAG, "entering deep sleep, wake mask 0x%llx ext1 %s ext0 %d hold %s %d%s", (unsigned long long)ext1_mask,
             ext1_high ? "ANY_HIGH" : "ANY_LOW", ext0_gpio, hold_gpio < 0 ? "none" : hold_high ? "high" : "low", hold_gpio,
             timer);
    deep_sleep_no_nap();
    health_wdt_stop();           /* as power_deep_sleep(): the RTC watchdog would end the sleep */
    timekeeping_save_anchor();   /* the RTC keeps counting in deep sleep; the anchor covers a power loss */
    esp_err_t err = esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);   /* esp_pm's timer, see above */
    if (s_deep_timer_s && err == ESP_OK) err = esp_sleep_enable_timer_wakeup((uint64_t)s_deep_timer_s * 1000000ULL);
    /* GPIO0 is the boot-mode strapping pin. The wall board has lost its BOOT switch and pad, so nothing holds the
     * pin high while the digital pads are off in deep sleep; the old BOOT-wake path (power_deep_sleep) always
     * armed the RTC pull-up here, and that path woke every time, this one never did (2026-11-07). Keep the pin
     * pulled up by the RTC domain through the sleep so the wake-up reset samples a normal boot. */
    if (err == ESP_OK) err = rtc_gpio_init(GPIO_NUM_0);                       /* route the pad to the RTC domain */
    if (err == ESP_OK) err = rtc_gpio_set_direction(GPIO_NUM_0, RTC_GPIO_MODE_INPUT_ONLY);
    if (err == ESP_OK) err = rtc_gpio_pullup_en(GPIO_NUM_0);
    if (err == ESP_OK) err = rtc_gpio_pulldown_dis(GPIO_NUM_0);
    if (s_deep_gpio0_phantom) {   /* a played press (debug): the pad driven low, the input still enabled */
        if (err == ESP_OK) err = rtc_gpio_set_level(GPIO_NUM_0, 0);
        if (err == ESP_OK) err = rtc_gpio_set_direction(GPIO_NUM_0, RTC_GPIO_MODE_INPUT_OUTPUT);
        ESP_LOGW(TAG, "GPIO0 driven LOW through the sleep (phantom key press)");
    }
    if (err == ESP_OK) err = rtc_gpio_hold_en(GPIO_NUM_0);                    /* kept through the wake-up reset */
    gpio_deep_sleep_hold_en();
    ESP_LOGI(TAG, "GPIO0 (boot strap, no switch on the board) held high through the sleep: %s", esp_err_to_name(err));
    if (hold_gpio >= 0) {
        gpio_set_direction((gpio_num_t)hold_gpio, GPIO_MODE_OUTPUT);
        gpio_set_level((gpio_num_t)hold_gpio, hold_high ? 1 : 0);
        if (err == ESP_OK) err = gpio_hold_en((gpio_num_t)hold_gpio);
        gpio_deep_sleep_hold_en();
    }
    if (ext1_mask) {
        for (int g = 0; g < 64; g++) {
            if (!(ext1_mask & (1ULL << g))) continue;
            if (ext1_high) {
                if (err == ESP_OK) err = rtc_gpio_pullup_dis((gpio_num_t)g);
                if (err == ESP_OK) err = rtc_gpio_pulldown_en((gpio_num_t)g);
            } else {
                if (err == ESP_OK) err = rtc_gpio_pullup_en((gpio_num_t)g);
                if (err == ESP_OK) err = rtc_gpio_pulldown_dis((gpio_num_t)g);
            }
        }
        if (err == ESP_OK) err = esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
        if (err == ESP_OK)
            err = esp_sleep_enable_ext1_wakeup_io(ext1_mask, ext1_high ? ESP_EXT1_WAKEUP_ANY_HIGH : ESP_EXT1_WAKEUP_ANY_LOW);
    }
    if (ext0_gpio >= 0) {
        if (err == ESP_OK) err = rtc_gpio_pullup_en((gpio_num_t)ext0_gpio);
        if (err == ESP_OK) err = rtc_gpio_pulldown_dis((gpio_num_t)ext0_gpio);
        if (err == ESP_OK) err = esp_sleep_enable_ext0_wakeup((gpio_num_t)ext0_gpio, s_deep_ext0_level);
        if (s_deep_ext0_level) ESP_LOGI(TAG, "ext0 GPIO%d wakes on HIGH (the key's release)", ext0_gpio);
    }
    if (err != ESP_OK) ESP_LOGE(TAG, "wake config: %s", esp_err_to_name(err));
    rc_fast_keep_for_deep_sleep();
    vTaskDelay(pdMS_TO_TICKS(50)); /* let the log drain */
    if (s_deep_entry_cb) {
        const power_deep_entry_t e = {
            .ext1_mask = ext1_mask,
            .ext0_gpio = ext0_gpio,
            .ext0_level = s_deep_ext0_level,
            .timer_s = s_deep_timer_s,
            .gpio0_phantom = s_deep_gpio0_phantom,
        };
        s_deep_entry_cb(&e);
    }
    s_deep_entry_rtc_us = (int64_t)esp_rtc_get_time_us();
    esp_deep_sleep_start();
}

void power_release_hold(int gpio)
{
    rtc_gpio_hold_dis(GPIO_NUM_0);     /* the boot-strap hold of power_deep_sleep_wake_ex() */
    rtc_gpio_deinit(GPIO_NUM_0);
    if (gpio < 0) return;
    gpio_hold_dis((gpio_num_t)gpio);
    gpio_deep_sleep_hold_dis();
}
