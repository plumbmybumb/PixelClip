/* app_main.c — boot sequence and the mode controller.
 *
 * Boot: NVS -> storage mount -> reader store -> config -> time -> display -> button -> power -> imu -> net
 * -> ble -> sched -> player -> batlog (-> upload mode at once when wifi_always_on).
 * After boot, app_main becomes the controller loop: hardware/network callbacks only post events
 * to a queue, and every mode change (upload mode on/off, power off, low battery) runs here,
 * serialised, in this task (stack CONFIG_ESP_MAIN_TASK_STACK_SIZE = 8 KB).
 */
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "nvs_flash.h"
#include "esp_event.h"
#include "esp_timer.h"
#include "esp_sleep.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
#include "esp_log.h"

#include "display.h"
#include "ui.h"
#include "storage.h"
#include "appcfg.h"
#include "timekeeping.h"
#include "power.h"
#include "button.h"
#include "player.h"
#include "playlist.h"
#include "net.h"
#include "ota.h"
#include "batlog.h"
#include "sched.h"
#include "imu.h"
#include "orient.h"
#include "reader_store.h"
#include "pixelclip_ble.h"
#include "health.h"
#include "bench.h"
#include "esp_app_desc.h"

static const char *TAG = "app";

#define SPLASH_MS        3000    /* "WiFi: PixelClip-XXXX" before a panel-off session (and "Battery low") */
#define SPLASH_LIVE_MS   2000    /* ... before a screen-on session (display_during_upload) */
#define DONE_SPLASH_MS   1000
#define BYE_MS           1000
#define LOW_BAT_BANNER_MS 10000
#define WIFI_MIN_MV      3500
#define SESSION_LOW_MV   3900    /* battery mode: sessions blank the panel below this */
#define DOUBLE_PRESS_MS  400     /* reader: two short presses this close (release to release) = next item */
#define ORACLE_DOUBLE_MS 350     /* oracle (PROTOCOL §5f.3): two taps this close = the previous screen */

typedef enum {
    EV_BUTTON_SHORT,
    EV_BUTTON_LONG,
    EV_BUTTON_HOLD,
    EV_SESSION_END,
    EV_LOW_BATTERY,
    EV_WEAK_BATTERY,
    EV_BUTTON_SINGLE,    /* reader: a short press not followed by a second one within DOUBLE_PRESS_MS */
    EV_BLE_WAKE,         /* BLE doorbell: 0x01 written to `wake` */
    EV_BLE_END,          /* BLE doorbell: 0x02 */
    EV_CLIENT_ON,        /* a station joined the SoftAP */
    EV_CLIENT_OFF,       /* the last station left */
    EV_USB_CHANGED,      /* USB power appeared / disappeared: TX cap, log level */
    EV_SESSION_LOW,      /* on battery, in a screen-on session, Vbat < 3.9 V: blank the panel */
    EV_BENCH_START,      /* CONFIG_PIXELCLIP_BENCH_SLEEP_TEST: start / end an upload session */
    EV_BENCH_END,
} app_event_t;

static QueueHandle_t s_events;
static esp_timer_handle_t s_single_timer;
static bool s_single_pending;
static bool s_single_oracle;    /* the pending single press is an oracle tap (next screen), not the reader's toggle */
static bool s_session_live;     /* the running session keeps the panel playing (display_during_upload) */

static void post(app_event_t ev)
{
    if (xQueueSend(s_events, &ev, 0) != pdTRUE) ESP_LOGW(TAG, "event queue full, dropped %d", ev);
}

static void on_button(button_event_t ev)
{
    post(ev == BUTTON_EVT_SHORT ? EV_BUTTON_SHORT : ev == BUTTON_EVT_LONG ? EV_BUTTON_LONG : EV_BUTTON_HOLD);
}

static void on_power(power_event_t ev)
{
    switch (ev) {
    case POWER_EVT_LOW_BATTERY: post(EV_LOW_BATTERY); break;
    case POWER_EVT_WEAK_FOR_WIFI: post(EV_WEAK_BATTERY); break;
    case POWER_EVT_USB_CHANGED: post(EV_USB_CHANGED); break;
    case POWER_EVT_SESSION_LOW: post(EV_SESSION_LOW); break;
    }
}

static void on_bench(bool start)
{
    post(start ? EV_BENCH_START : EV_BENCH_END);
}

static void single_press_cb(void *arg)
{
    post(EV_BUTTON_SINGLE);
}

/* Short press. While an oracle item is on screen (PROTOCOL §5f.3) a tap is the next screen and two taps within
 * ORACLE_DOUBLE_MS the previous one (neither advances the playlist); the single tap therefore acts 350 ms after release.
 * While a reader item is on screen (PROTOCOL §5c): one press pauses/resumes, two presses within DOUBLE_PRESS_MS skip to
 * the next item; the single press acts 400 ms after release. Otherwise: next item at once (no delay). */
static void short_press(void)
{
    if (s_single_pending) {
        s_single_pending = false;
        esp_timer_stop(s_single_timer);
        if (s_single_oracle) {
            ESP_LOGI(TAG, "double tap: oracle back");
            if (!player_oracle_back()) player_next();   /* the oracle went away meanwhile */
            return;
        }
        ESP_LOGI(TAG, "double press: next item");
        player_next();
        return;
    }
    if (s_single_timer && player_oracle_showing()) {
        s_single_pending = true;
        s_single_oracle = true;
        if (esp_timer_start_once(s_single_timer, ORACLE_DOUBLE_MS * 1000) != ESP_OK) {
            s_single_pending = false;
            if (!player_oracle_press()) player_next();
        }
        return;
    }
    if (player_oracle_press()) return;   /* no timer: a tap is the next screen at once */
    if (s_single_timer && player_reader_active()) {
        s_single_oracle = false;
        s_single_pending = true;
        if (esp_timer_start_once(s_single_timer, DOUBLE_PRESS_MS * 1000) != ESP_OK) {
            s_single_pending = false;
            player_reader_toggle();
        }
        return;
    }
    player_next();
}

static void on_session_end(net_end_reason_t reason)
{
    post(EV_SESSION_END);
}

static void on_client(bool connected)
{
    post(connected ? EV_CLIENT_ON : EV_CLIENT_OFF);
}

static void batlog_state(batlog_state_t *out)
{
    player_status_t ps;
    player_get_status(&ps);
    out->mode = net_session_active() ? "upload" : (ps.current[0] ? "playing" : "idle");
    out->display_on = display_is_on();
    out->brightness = display_get_brightness();
}

/* Draw a system screen at the configured brightness (player output must be disabled). */
static void system_screen(const char *line1, const char *line2, uint16_t color)
{
    appcfg_t cfg;
    appcfg_get(&cfg);
    display_lock();
    if (!display_is_on()) display_on();
    ui_screen_message(line1, line2, color);
    esp_err_t err = display_flush_full();
    display_unlock();
    if (err != ESP_OK) ESP_LOGE(TAG, "system screen flush: %s", esp_err_to_name(err));
    display_set_brightness(cfg.brightness < 40 ? 40 : cfg.brightness);
}

static bool battery_ok_for_wifi_q(bool quiet)
{
    power_battery_t b;
    power_get_battery(&b);
    if (!b.valid) {
        if (!quiet) ESP_LOGW(TAG, "battery voltage unknown (ADC problem): allowing WiFi");
        return true;
    }
    if (!b.usb_present && b.mv < WIFI_MIN_MV) {
        if (!quiet) ESP_LOGW(TAG, "battery %d mV < %d mV: no WiFi session", b.mv, WIFI_MIN_MV);
        return false;
    }
    return true;
}

static bool battery_ok_for_wifi(void) { return battery_ok_for_wifi_q(false); }

/* ---- BLE doorbell (pixelclip_ble.h): both callbacks run outside the controller task ---- */

static uint8_t ble_cmd(uint8_t cmd)
{
    if (cmd == PIXELCLIP_BLE_CMD_WAKE) {
        if (!net_session_active() && !battery_ok_for_wifi_q(true)) return PIXELCLIP_BLE_RESULT_LOW_BATTERY;
        post(EV_BLE_WAKE);
    } else {
        post(EV_BLE_END);   /* always accepted: ending a session only saves power */
    }
    return PIXELCLIP_BLE_RESULT_ACCEPTED;
}

static void ble_state(pixelclip_ble_state_t *o)
{
    power_battery_t b;
    power_get_battery(&b);
    player_status_t ps;
    player_get_status(&ps);
    o->mv = b.valid && b.mv > 0 ? (uint16_t)b.mv : 0;
    o->pct = b.valid ? (uint8_t)b.pct : 0;
    o->flags = (net_session_ready() ? PIXELCLIP_BLE_FLAG_SESSION_ACTIVE : 0) | (b.usb_present ? PIXELCLIP_BLE_FLAG_USB_PRESENT : 0) |
               (timekeeping_synced() ? PIXELCLIP_BLE_FLAG_CLOCK_OK : 0) |
               (ps.current[0] && display_is_on() ? PIXELCLIP_BLE_FLAG_PLAYING : 0) |
               (!battery_ok_for_wifi_q(true) ? PIXELCLIP_BLE_FLAG_LOW_BATTERY : 0) | (net_always_on() ? PIXELCLIP_BLE_FLAG_ALWAYS_ON : 0);
    if (!ps.current[0]) {
        o->kind = PIXELCLIP_BLE_KIND_NONE;
    } else if (strncmp(ps.current, "scene:", 6) == 0) {
        o->kind = PIXELCLIP_BLE_KIND_SCENE;
    } else if (strncmp(ps.current, "reader:", 7) == 0) {
        o->kind = PIXELCLIP_BLE_KIND_READER;
    } else {
        o->kind = PIXELCLIP_BLE_KIND_ASSET;   /* also "oracle:<id>" (asset-based items; no kind of their own yet) */
    }
}

/* Upload mode. Screen-on (config display_during_upload, default; always for wifi_always_on): the
 * "WiFi: PixelClip-XXXX" splash for 2 s while the SoftAP comes up, then the content plays on with the
 * connection dot (steady = waiting, pulsing = a client is connected). Panel-off (display_during_upload
 * false): splash 3 s, panel asleep for the whole session, the player renders offscreen for /screenshot. */
static void enter_upload_mode(void)
{
    if (!battery_ok_for_wifi()) {
        ESP_LOGW(TAG, "battery too low for WiFi");
        player_set_output(false);
        system_screen("Battery low", "charge me first", DISPLAY_RGB565BE(255, 80, 60));
        vTaskDelay(pdMS_TO_TICKS(SPLASH_MS));
        display_fade_to(0, DISPLAY_FADE_MS);
        player_set_output(true);
        return;
    }
    appcfg_t cfg;
    appcfg_get(&cfg);
    /* An always-on hotspot with the panel off would leave the clip dark for good: always-on sessions
     * are screen-on whatever display_during_upload says. */
    bool live = cfg.display_during_upload || net_always_on();
    /* Battery mode: below 3.9 V on battery a session runs with the panel off (it overrides
     * display_during_upload; always-on keeps its screen, see README "Light sleep on battery"). */
    power_battery_t bat;
    power_get_battery(&bat);
    if (live && !net_always_on() && bat.valid && !bat.usb_present && bat.mv < SESSION_LOW_MV) {
        ESP_LOGW(TAG, "battery %d mV < %d mV on battery: this session runs with the panel off", bat.mv, SESSION_LOW_MV);
        live = false;
    }
    char line[48];
    snprintf(line, sizeof line, "WiFi: %s", net_ssid());
    player_set_output(false);
    system_screen(line, NULL, DISPLAY_RGB565BE(255, 255, 255));
    const net_session_opts_t opts = { .on_end = on_session_end, .on_client = on_client, .display_on = live };
    esp_err_t err;
    if (live) {
        const int64_t t0 = esp_timer_get_time();
        err = net_session_start(&opts);          /* the AP comes up while the splash shows */
        const int64_t left_ms = SPLASH_LIVE_MS - (esp_timer_get_time() - t0) / 1000;
        if (left_ms > 0) vTaskDelay(pdMS_TO_TICKS(left_ms));
        display_fade_to(0, DISPLAY_FADE_MS);
        s_session_live = err == ESP_OK;
        player_set_output(true);                 /* the content plays on, live */
        if (err == ESP_OK) player_set_badge(net_session_clients() ? PLAYER_BADGE_PULSE : PLAYER_BADGE_STEADY);
    } else {
        vTaskDelay(pdMS_TO_TICKS(SPLASH_MS));
        display_off();                 /* panel power down for the whole session */
        player_refresh_offscreen();    /* framebuffer = current item, for GET /screenshot */
        s_session_live = false;
        err = net_session_start(&opts);
        if (err != ESP_OK) {
            display_on();
            player_set_output(true);
        }
    }
    if (err != ESP_OK) ESP_LOGE(TAG, "upload mode failed: %s", esp_err_to_name(err));
    pixelclip_ble_status_changed();
}

/* After every session (README "Light sleep on battery"): re-apply the light-sleep pin exclusions, check the
 * session's own perf hold is gone and log which esp_pm locks still keep the chip awake. */
static void after_session_checks(void)
{
    display_sleep_pins_apply();
    imu_sleep_pins_apply();
    char perf[96], locks[192];
    power_perf_report(perf, sizeof perf);
    const int held = power_pm_locks_summary(locks, sizeof locks);
    ESP_LOGI(TAG, "after session: perf holds %s; awake holds session=%d (until 10 s after) fastlane=%d usb=%d "
             "(light sleeps %lu, while usb %lu); esp_pm locks held: %s", perf, power_awake_held(POWER_AWAKE_SESSION),
             power_awake_held(POWER_AWAKE_FASTLANE), power_awake_held(POWER_AWAKE_USB),
             (unsigned long)power_light_sleeps(), (unsigned long)power_light_sleeps_while_usb(), held < 0 ? "?" : locks);
    pixelclip_ble_fast_lane_holds_ok("after the session");
    if (power_perf_held(POWER_PERF_SESSION) != 0 || power_perf_errors() != 0) {
        ESP_LOGE(TAG, "PM LOCK ACCOUNTING after session: session=%d, errors=%lu", power_perf_held(POWER_PERF_SESSION),
                 (unsigned long)power_perf_errors());
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST
        abort();
#endif
    }
}

/* Battery dropped below SESSION_LOW_MV during a screen-on session: continue it with the panel off. */
static void blank_session(void)
{
    if (!net_session_active() || !s_session_live || net_always_on()) return;
    ESP_LOGW(TAG, "battery below %d mV on battery: panel off for the rest of the session", SESSION_LOW_MV);
    player_set_badge(PLAYER_BADGE_OFF);
    player_set_output(false);
    display_fade_to(0, DISPLAY_FADE_MS);
    display_off();
    player_refresh_offscreen();
    s_session_live = false;
    net_session_set_display(false);
    pixelclip_ble_status_changed();
}

/* USB power came or went: TX cap of a running session, console verbosity. */
static void usb_changed(void)
{
    power_battery_t b;
    power_get_battery(&b);
    net_apply_tx_power();
#if !CONFIG_PIXELCLIP_BENCH_SLEEP_TEST
    /* Nobody reads the console on battery: keep only warnings (less formatting work between sleeps; the
     * USB-Serial-JTAG console drops output without a host anyway, it never blocks for long). */
    esp_log_level_set("*", b.usb_present ? CONFIG_LOG_DEFAULT_LEVEL : ESP_LOG_WARN);
#endif
    pixelclip_ble_status_changed();
}

/* `ack`: show the "Done" card (always after a panel-off session; after a screen-on session only when
 * the user ended it with the button, the content otherwise just loses its connection dot). */
static void leave_upload_mode(bool ack)
{
    if (!net_session_active()) return;
    net_session_stop();
    after_session_checks();
    timekeeping_save_anchor();     /* the session may have synced the clock: keep it across a power-off */
    player_set_badge(PLAYER_BADGE_OFF);
    if (!s_session_live || ack) {
        player_set_output(false);
        system_screen("Done", NULL, DISPLAY_RGB565BE(120, 255, 160));
        vTaskDelay(pdMS_TO_TICKS(DONE_SPLASH_MS));
        display_fade_to(0, DISPLAY_FADE_MS);
        player_set_output(true);       /* restarts the current item and fades in */
    }
    s_session_live = false;
    pixelclip_ble_status_changed();
}

/* display_on()/display_off() → the panel hold on automatic light sleep (see the call in app_main()). */
static void panel_power_changed(bool on)
{
    static bool held;
    if (on && !held) { power_awake_acquire(POWER_AWAKE_PANEL); held = true; }
    if (!on && held) { power_awake_release(POWER_AWAKE_PANEL); held = false; }
}

static void power_off(const char *line1, const char *line2, uint32_t show_ms) __attribute__((noreturn));
static void power_off(const char *line1, const char *line2, uint32_t show_ms)
{
    health_step(HEALTH_STEP_POWER_OFF);
    power_awake_acquire(POWER_AWAKE_POWEROFF);   /* no light sleep between the bye screen and the panel-off command */
    /* The RTC watchdog stays armed until power_deep_sleep() stops it. Nobody feeds it while we are in here (the
     * controller loop is us), and the whole choreography is well under its 40 s, so a hang anywhere below ends
     * in a reset instead of a lit "bye" screen forever (2026-10-17, on battery). */
    if (net_session_active()) net_session_stop();
    player_set_badge(PLAYER_BADGE_OFF);
    pixelclip_ble_set_enabled(false);   /* radio off before deep sleep */
    player_set_output(false);
    system_screen(line1, line2, DISPLAY_RGB565BE(255, 255, 255));
    vTaskDelay(pdMS_TO_TICKS(show_ms));
    display_fade_to(0, DISPLAY_FADE_MS);
    display_off();
    button_wait_release(30000);    /* ext0 wakes on low level: never sleep while held */
    power_deep_sleep();
}

static void controller_loop(void)
{
    int64_t next_probe_us = 0;
    for (;;) {
        app_event_t ev;
        /* The time anchor is saved every minute from here (NVS write: needs a roomy stack). */
        const uint32_t anchor_ms = timekeeping_service();
        /* Liveness probes (health.h): the NimBLE host task while BLE runs; during a session the httpd task and
         * the lwIP thread plus the 10 s session heap line (net_session_service). */
        const int64_t now_us = esp_timer_get_time();
        if (now_us >= next_probe_us) {
            next_probe_us = now_us + (int64_t)HEALTH_PROBE_PERIOD_MS * 1000;
            pixelclip_ble_probe();
        }
        net_session_service();
        /* Wake at least every HEALTH_FEED_PERIOD_MS: the RTC watchdog keeps counting in light sleep. This task
         * runs at priority 1 (the lowest application priority) on CPU0: starving it also stops the feed. */
        health_feed();
        const uint32_t wait_ms = anchor_ms == 0 ? 1 : anchor_ms < HEALTH_FEED_PERIOD_MS ? anchor_ms : HEALTH_FEED_PERIOD_MS;
        if (xQueueReceive(s_events, &ev, pdMS_TO_TICKS(wait_ms)) != pdTRUE) continue;
        switch (ev) {
        case EV_BUTTON_SHORT:
            if (!net_session_active() || s_session_live) short_press();
            break;
        case EV_BUTTON_SINGLE:
            if (s_single_pending) {
                s_single_pending = false;
                if (net_session_active() && !s_session_live) break;
                if (s_single_oracle) {
                    if (!player_oracle_press()) player_next();   /* a single tap: the next screen */
                } else {
                    player_reader_toggle();
                }
            }
            break;
        case EV_BUTTON_LONG:
            if (net_session_active()) {
                net_always_on_suspend();   /* "always reachable" off until the next boot */
                leave_upload_mode(true);
            } else {
                enter_upload_mode();
            }
            break;
        case EV_BLE_WAKE:
            if (net_session_active()) {
                net_session_touch();       /* already up: just keep it alive */
                pixelclip_ble_status_changed();
            } else {
                ESP_LOGI(TAG, "BLE wake: entering upload mode");
                enter_upload_mode();
            }
            break;
        case EV_BLE_END:
            if (net_session_active()) {
                ESP_LOGI(TAG, "BLE: ending the session");
                net_always_on_suspend();
                leave_upload_mode(false);
            }
            break;
        case EV_CLIENT_ON:
        case EV_CLIENT_OFF:
            if (net_session_active() && s_session_live) {
                player_set_badge(ev == EV_CLIENT_ON ? PLAYER_BADGE_PULSE : PLAYER_BADGE_STEADY);
            }
            break;
        case EV_SESSION_END:
            leave_upload_mode(false);
            break;
        case EV_WEAK_BATTERY:
            if (net_session_active()) {
                ESP_LOGW(TAG, "battery below %d mV, ending WiFi session", WIFI_MIN_MV);
                net_always_on_suspend();
                leave_upload_mode(false);
            }
            break;
        case EV_USB_CHANGED:
            usb_changed();
            break;
        case EV_SESSION_LOW:
            blank_session();
            break;
        case EV_BENCH_START:
            if (!net_session_active()) enter_upload_mode();
            break;
        case EV_BENCH_END:
            if (net_session_active()) leave_upload_mode(false);
            break;
        case EV_BUTTON_HOLD:
            power_off("bye", NULL, BYE_MS);
            break;
        case EV_LOW_BATTERY:
            power_off("Battery low", "charge me", LOW_BAT_BANNER_MS);
            break;
        }
    }
}

/* ---- boot diagnostics: stack high-water marks + heap, every 10 s for the first 60 s ---- */

static int64_t s_boot_ms;
static uint32_t s_boot_no;             /* NVS boot counter, for the summary line */
static int s_boot_failures;

static void diag_task(void *arg)
{
    static const char *names[] = { "main", "player", "imu", "button", "power", "batlog", "httpd",
                                   "esp_timer", "sys_evt", "tiT", "wifi", "mdns", "nimble_host", "btController", "diag" };
    for (int round = 0; round < 6; round++) {
        vTaskDelay(pdMS_TO_TICKS(10000));
        /* One greppable line with the bring-up facts. Repeated because on USB-Serial-JTAG the
         * first second of output after a reset is often lost while the host re-enumerates. */
        size_t total = 0, used = 0;
        storage_usage(&total, &used);
        power_battery_t bat;
        power_get_battery(&bat);
        ESP_LOGI(TAG, "summary: boot %lld ms, full flush %lu us, littlefs %s %u/%u KB (%u assets), "
                 "battery %d mV%s%s, ssid %s, failed steps %d; wake cause %d, reset %s, boot #%lu, "
                 "previous run: step %s at %lu s, last crumb %lu s",
                 (long long)s_boot_ms, (unsigned long)display_last_full_flush_us(),
                 total ? "mounted" : "NOT MOUNTED", (unsigned)(used / 1024), (unsigned)(total / 1024),
                 (unsigned)storage_asset_count(), bat.mv, bat.valid ? "" : " (invalid)",
                 bat.usb_present ? " usb" : "", net_ssid(), s_boot_failures,
                 (int)esp_sleep_get_wakeup_cause(), health_reset_name(), (unsigned long)s_boot_no,
                 health_prev_step_name(), (unsigned long)health_prev_step_s(), (unsigned long)health_prev_last_update_s());
        char line[256] = "";
        int n = 0;
        for (size_t i = 0; i < sizeof names / sizeof names[0] && n < (int)sizeof line - 24; i++) {
            TaskHandle_t t = xTaskGetHandle(names[i]);
            if (t) n += snprintf(line + n, sizeof line - n, " %s=%u", names[i], (unsigned)uxTaskGetStackHighWaterMark(t));
        }
        ESP_LOGI(TAG, "stack free (B):%s", line);
        /* psram largest: a scrolling strip needs width x 240 x 2 B + 512 KB in ONE block. */
        ESP_LOGI(TAG, "heap: internal %u free (min %u, largest %u), psram %u free (largest %u)",
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA),
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
    }
    vTaskDelete(NULL);
}

/* A failed subsystem is logged and skipped: the clip keeps booting with what works (a dead panel
 * still allows WiFi uploads, a broken filesystem still shows the idle screen, ...). */
static void boot_step(const char *what, esp_err_t err)
{
    if (err == ESP_OK) return;
    s_boot_failures++;
    ESP_LOGE(TAG, "BOOT STEP FAILED: %s: %s (continuing)", what, esp_err_to_name(err));
}

static esp_err_t init_nvs(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND || err == ESP_ERR_NVS_CORRUPT_KEY_PART) {
        ESP_LOGW(TAG, "NVS: %s, erasing", esp_err_to_name(err));
        err = nvs_flash_erase();
        if (err == ESP_OK) err = nvs_flash_init();
    }
    return err;
}

/* The few config values app_main needs. Read in a function of their own: app_main never returns, so anything
 * in its frame is in every core dump (security audit WIFI-10). appcfg_t itself no longer holds the hotspot
 * passphrase (appcfg.h); this keeps the rest of the config off that frame as well. */
typedef struct {
    uint8_t low_battery_pct, brightness;
    appcfg_orientation_t orientation;
    bool ble_wake;
} boot_cfg_t;

static __attribute__((noinline)) boot_cfg_t boot_cfg(void)
{
    appcfg_t cfg;
    appcfg_get(&cfg);
    return (boot_cfg_t){ cfg.low_battery_pct, cfg.brightness, cfg.orientation, cfg.ble_wake };
}

void app_main(void)
{
    const int64_t t0 = esp_timer_get_time();
    health_wdt_start(HEALTH_BOOT_TIMEOUT_S);   /* first: an RTC watchdog that also counts in light sleep (health.h) */

    /* The queue and the default event loop are prerequisites for everything below; without them
     * nothing can work, so these two stay fatal. */
    s_events = xQueueCreate(8, sizeof(app_event_t));
    if (!s_events) abort();
    const esp_timer_create_args_t single = { .callback = single_press_cb, .name = "btn_single" };
    if (esp_timer_create(&single, &s_single_timer) != ESP_OK) s_single_timer = NULL;   /* then: no double press */
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    boot_step("nvs", init_nvs());               /* time/tz trust and WiFi PHY data degrade without it */
    /* Reset reason by name (RTCWDT_SYS / RTCWDT_RTC = the light-sleep safety net fired), counted in NVS. */
    const char *reason = health_boot_record();
    health_resets_t resets;
    health_get_resets(&resets);
    s_boot_no = resets.boots;
    ESP_LOGI(TAG, "PixelClip firmware booting (wake cause %d, reset reason %s (esp %d), boot #%lu)",
             (int)esp_sleep_get_wakeup_cause(), reason, (int)esp_reset_reason(), (unsigned long)resets.boots);
    /* Storage must be mounted before config (config lives in /config.json). LittleFS formats the
     * partition itself if it cannot be mounted. */
    boot_step("storage", storage_init());
    boot_step("reader", reader_store_init());   /* /texts, /fonts (PROTOCOL §5c) */
    boot_step("config", appcfg_init());
    boot_step("time", timekeeping_init());
    const esp_err_t display_err = display_init();
    boot_step("display", display_err);          /* headless on failure: framebuffer still valid */
    boot_step("button", button_init(on_button));
    boot_step("power", power_init(on_power));
    /* Light sleep only while the panel is off (README "Light sleep on battery", 2026-10-17): the hold follows the
     * panel from here on; the panel is already on after display_init(). */
    display_set_power_cb(panel_power_changed);
    if (display_is_on()) panel_power_changed(true);
    const boot_cfg_t cfg = boot_cfg();
    power_set_low_battery_pct(cfg.low_battery_pct);
    boot_step("imu", imu_init());               /* optional: scenes fall back to fixed gravity */
    orient_init(cfg.orientation);               /* 180° flip (PROTOCOL §4 "Orientation"), before the splash */
    boot_step("net", net_init());
    /* BLE doorbell (same "PixelClip-XXXX" name as the SSID). Off when ble_wake is false: then the stack is
     * never initialised (no RAM, no radio). */
    if (pixelclip_ble_init(net_ssid(), net_device_id(), esp_app_get_description()->version, ble_cmd, ble_state) == ESP_OK &&
        cfg.ble_wake) {
        boot_step("ble", pixelclip_ble_set_enabled(true));
    } else if (!cfg.ble_wake) {
        ESP_LOGI(TAG, "BLE doorbell disabled (ble_wake false)");
    }
    /* Safe start (health.h): after three crashes in a row shortly after boot the stored playlist is set aside,
     * so content that crashes the clip at every boot cannot keep it unreachable: it comes up idle, the hotspot
     * and the BLE doorbell work, and the owner sends the playlist again. Assets, texts and fonts stay. */
    if (health_safe_start()) {
        const bool had = playlist_set_aside();
        ESP_LOGE(TAG, "safe start: %s", had ? "stored playlist set aside as playlist.bad.json: send it again from the app"
                                            : "there was no stored playlist");
    }
    boot_step("sched", sched_init());           /* queue done-set; before the player loads the queue */
    /* Embedded boot splash (main/assets/splash.hca at build time), before the player owns the panel. */
    if (display_err == ESP_OK) ui_show_embedded_splash(cfg.brightness);
    boot_step("player", player_init());
    boot_step("batlog", batlog_init(batlog_state));
    ota_schedule_mark_valid(30);
    s_boot_ms = (esp_timer_get_time() - t0) / 1000;
    if (xTaskCreate(diag_task, "diag", 3584, NULL, 1, NULL) != pdPASS) ESP_LOGW(TAG, "no diag task");

    ESP_LOGI(TAG, "boot complete in %lld ms (full-frame flush %lu us, %d failed step(s))",
             (long long)s_boot_ms, (unsigned long)display_last_full_flush_us(), s_boot_failures);
    if (net_always_on()) {
        ESP_LOGI(TAG, "wifi_always_on: starting the hotspot now");
        enter_upload_mode();
    }
    usb_changed();        /* console level + BLE flag for the USB state found at boot */
    {
        /* Boot-loop guard (2026-10-17): a failing supply made the clip restart every ~30 s on battery all night
         * until the pack was flat. Five short battery runs in a row ending in power-on resets: say so and sleep
         * (BOOT wakes it; USB clears the pattern because runs on USB do not count). */
        const unsigned loops = health_short_battery_runs(60);
        if (loops >= 5 && power_on_battery()) {
            ESP_LOGE(TAG, "boot loop on battery: %u short runs in a row ended in power-on resets: powering off", loops);
            power_off("Battery trouble", "check the plug", 4000);
        } else if (loops >= 2) {
            ESP_LOGW(TAG, "%u short battery run(s) in a row ended in power-on resets", loops);
        }
    }
    bench_start(on_bench); /* CONFIG_PIXELCLIP_BENCH_SLEEP_TEST only */
    health_wdt_start(CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S);   /* from now on fed by the controller loop */
    health_step(HEALTH_STEP_IDLE);
    controller_loop();
}
