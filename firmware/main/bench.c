/* bench.c — bench harnesses: the light-sleep soak (CONFIG_PIXELCLIP_BENCH_SLEEP_TEST, README "Light sleep on battery")
 * and the stress session (CONFIG_PIXELCLIP_BENCH_STRESS, README "Bench: stress session, watchdog and crash tests").
 *
 * Reproduces the battery hang on the bench: USB normally keeps the chip out of automatic light sleep
 * (power.c's USB hold, README "USB light-sleep inhibit"); the bench build skips that hold (power.c, keyed on
 * CONFIG_PIXELCLIP_BENCH_SLEEP_TEST) and keeps IDF's CONFIG_USJ_NO_AUTO_LS_ON_CONNECTION off, so the clip
 * light-sleeps on USB exactly as on battery, and then cycles WiFi sessions:
 *   - CONFIG_PIXELCLIP_BENCH_FIRST_S after boot an upload session starts, CONFIG_PIXELCLIP_BENCH_SESSION_S later it
 *     ends, and this repeats every CONFIG_PIXELCLIP_BENCH_PERIOD_S;
 *   - a 4x4 px heartbeat dot in the bottom-left corner toggles every second from a priority-1 task, but only
 *     while the player task is alive (a frozen dot = the player is stuck; no dot changes = the chip is);
 *   - every 30 s a "console window" (at 45, 75, 105 ... s, i.e. never in the first 15 s after a session end):
 *     light sleep is held off for up to ~4.5 s so the host can re-enumerate the USB-Serial-JTAG port (it drops
 *     while the chip sleeps), then one status line is printed.
 * With the RTC watchdog a hang becomes a reboot with `reset reason RTCWDT_...`; scripts/sleep_soak.sh
 * counts them.
 */
#include "bench.h"
#include "sdkconfig.h"

#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST || CONFIG_PIXELCLIP_BENCH_STRESS
static bench_post_fn_t s_post;
#endif

#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST

#if CONFIG_USJ_NO_AUTO_LS_ON_CONNECTION
#error "The bench build needs CONFIG_USJ_NO_AUTO_LS_ON_CONNECTION=n: build with sdkconfig.bench (scripts/flash.sh with BENCH=1)"
#endif

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_pm.h"
#include "esp_timer.h"
#include "driver/usb_serial_jtag.h"
#include "display.h"
#include "health.h"
#include "power.h"
#include "net.h"

static const char *TAG = "bench";

#define BOOT_AWAKE_S     15     /* keep the chip awake after boot so the boot log reaches the host */
#define WINDOW_PERIOD_S  30
#define WINDOW_FIRST_S   45     /* windows at 45, 75, 105 ... s: never right after a session end (60 + 120k s) */
#define WINDOW_WAIT_MS   3000   /* max wait for the host to see us again */
#define WINDOW_HOLD_MS   1000   /* stay awake after the line so it drains */
#define DOT              4
#define DOT_X            4
#define DOT_Y            (DISPLAY_H - 4 - DOT)

static esp_pm_lock_handle_t s_awake;
static uint32_t s_sessions;
static uint32_t s_dot_toggles;

static void hold_awake(bool on)
{
    if (!s_awake) return;
    if (on) esp_pm_lock_acquire(s_awake);
    else esp_pm_lock_release(s_awake);
}

static void heartbeat_task(void *arg)
{
    uint16_t px[DOT * DOT];
    uint8_t mask[DOT * DOT];
    for (int i = 0; i < DOT * DOT; i++) {
        px[i] = DISPLAY_RGB565BE(80, 255, 120);
        mask[i] = 1;
    }
    bool lit = false;
    TickType_t last = xTaskGetTickCount();
    for (;;) {
        vTaskDelayUntil(&last, pdMS_TO_TICKS(1000));
        /* Toggle only while the player is alive: a dot that stops blinking = the player is stuck while the
         * chip still runs; no change on the panel at all = the chip itself is stuck. */
        if (!health_alive(HEALTH_SRC_PLAYER, 3 * HEALTH_PLAYER_MAX_WAIT_MS / 2)) continue;
        lit = !lit;
        if (lit) {
            display_overlay_slot_set(1, DOT_X, DOT_Y, DOT, DOT, px, mask);
        } else {
            display_overlay_slot_clear(1);
        }
        s_dot_toggles++;
    }
}

static void status_line(void)
{
    health_resets_t r;
    health_get_resets(&r);
    power_battery_t b;
    power_get_battery(&b);
    char perf[96], locks[160];
    power_perf_report(perf, sizeof perf);
    power_pm_locks_summary(locks, sizeof locks);
    uint32_t sleeps = 0, rejects = 0;
    int pct = -1;
    const bool stats = power_pm_sleep_stats(&sleeps, &rejects, &pct);
    ESP_LOGI(TAG, "boot #%lu reset %s up %lld s | sessions %lu (%s) | resets wdt %lu rtc_wdt %lu brownout %lu panic %lu | "
             "light sleeps %ld rejected %ld, %d%% of the time%s | heartbeat %lu | perf %s (errors %lu) | pm locks %s | "
             "battery %d mV%s",
             (unsigned long)r.boots, r.last, (long long)(esp_timer_get_time() / 1000000), (unsigned long)s_sessions,
             net_session_active() ? "in session" : "idle", (unsigned long)r.wdt, (unsigned long)r.rtc_wdt,
             (unsigned long)r.brownout, (unsigned long)r.panic, stats ? (long)sleeps : -1L, stats ? (long)rejects : -1L,
             pct, stats ? "" : " (no PM profiling)", (unsigned long)s_dot_toggles, perf,
             (unsigned long)power_perf_errors(), locks, b.mv, b.usb_present ? " usb" : "");
}

static void bench_task(void *arg)
{
    const int64_t t0 = esp_timer_get_time();
    int64_t next_start = t0 + (int64_t)CONFIG_PIXELCLIP_BENCH_FIRST_S * 1000000;
    int64_t next_end = 0;
    int64_t next_window = t0 + (int64_t)WINDOW_FIRST_S * 1000000;
    bool boot_hold = true;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(500));
        const int64_t now = esp_timer_get_time();
        if (boot_hold && now - t0 >= (int64_t)BOOT_AWAKE_S * 1000000) {
            boot_hold = false;
            ESP_LOGI(TAG, "boot hold over: automatic light sleep from now on (also on USB)");
            hold_awake(false);
        }
        if (next_start && now >= next_start) {
            s_sessions++;
            ESP_LOGI(TAG, "session %lu: start", (unsigned long)s_sessions);
            if (s_post) s_post(true);
            next_end = next_start + (int64_t)CONFIG_PIXELCLIP_BENCH_SESSION_S * 1000000;
            next_start += (int64_t)CONFIG_PIXELCLIP_BENCH_PERIOD_S * 1000000;
        }
        if (next_end && now >= next_end) {
            next_end = 0;
            ESP_LOGI(TAG, "session %lu: end", (unsigned long)s_sessions);
            if (s_post) s_post(false);
        }
        if (now >= next_window) {
            next_window += (int64_t)WINDOW_PERIOD_S * 1000000;
            hold_awake(true);
            for (int ms = 0; ms < WINDOW_WAIT_MS && !usb_serial_jtag_is_connected(); ms += 50) vTaskDelay(pdMS_TO_TICKS(50));
            vTaskDelay(pdMS_TO_TICKS(500));   /* the capture script reopens the port */
            status_line();
            vTaskDelay(pdMS_TO_TICKS(WINDOW_HOLD_MS));
            hold_awake(false);
        }
    }
}

static void sleep_test_start(void)
{
    if (esp_pm_lock_create(ESP_PM_NO_LIGHT_SLEEP, 0, "bench", &s_awake) != ESP_OK) s_awake = NULL;
    hold_awake(true);   /* released after BOOT_AWAKE_S by bench_task */
    ESP_LOGW(TAG, "LIGHT-SLEEP SOAK BUILD: light sleep also on USB, session %d s after boot for %d s, every %d s; "
             "heartbeat dot bottom-left; RTC watchdog %d s", CONFIG_PIXELCLIP_BENCH_FIRST_S, CONFIG_PIXELCLIP_BENCH_SESSION_S,
             CONFIG_PIXELCLIP_BENCH_PERIOD_S, CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S);
    if (xTaskCreate(heartbeat_task, "bench_dot", 2560, NULL, 1, NULL) != pdPASS) ESP_LOGE(TAG, "no heartbeat task");
    if (xTaskCreate(bench_task, "bench", 4096, NULL, 2, NULL) != pdPASS) ESP_LOGE(TAG, "no bench task");
}

#endif /* CONFIG_PIXELCLIP_BENCH_SLEEP_TEST */

#if CONFIG_PIXELCLIP_BENCH_STRESS
/* Stress session (README "Bench: stress session, watchdog and crash tests"): the heaviest mix seen before the
 * session hang of 2026-10-14 (screen-on session + water scene + 200 KB atlas uploads + BLE fast lane up), on a
 * timer, with the heap logged after every store. The atlas is generated once into PSRAM at start (a 416x240 raw
 * RGB565 glyph atlas, 199 724 B; one pixel row changes per round so every store writes new content) and stored
 * through the same storage path as PUT /assets (temp file + SHA-256 + validation + rename + index), followed by
 * the same player_upload_active / player_release_files / player_reload_for / net_note_upload as the HTTP handler
 * (the water scene must keep running: `player: reload (upload asset bench-atlas): scene water keeps playing`). */
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "mbedtls/sha256.h"
#include "hca.h"
#include "storage.h"
#include "playlist.h"
#include "player.h"
#include "net.h"
#include "pixelclip_ble.h"

static const char *STAG = "stress";

#define ATLAS_W      416
#define ATLAS_H      240
#define ATLAS_ID     "bench-atlas"
#define ATLAS_CHUNK  4096   /* like the HTTP handler's IO_CHUNK */
#define STRESS_PLAYLIST "{\"version\":1,\"items\":[{\"type\":\"scene\",\"scene\":\"water\",\"duration_ms\":0}]}"

static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void wr32(uint8_t *p, uint32_t v) { wr16(p, (uint16_t)v); wr16(p + 2, (uint16_t)(v >> 16)); }

static uint8_t *atlas_build(size_t *len_out)
{
    const size_t hdr = hca_table_bytes(1), px = (size_t)ATLAS_W * ATLAS_H * 2, total = hdr + px;
    uint8_t *a = heap_caps_calloc(1, total, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!a) return NULL;
    memcpy(a, HCA_MAGIC, 4);
    wr16(a + 4, ATLAS_W);
    wr16(a + 6, ATLAS_H);
    wr16(a + 8, 1);
    a[10] = HCA_PIXFMT_RGB565BE;
    a[11] = HCA_COMP_RAW;
    wr16(a + 14, HCA_FLAG_GLYPH_ATLAS);
    wr32(a + 16, HCA_HEADER_SIZE);
    wr32(a + 20, (uint32_t)total);
    wr32(a + HCA_HEADER_SIZE, (uint32_t)hdr);
    wr32(a + HCA_HEADER_SIZE + 4, (uint32_t)px);
    for (size_t i = 0; i < px; i++) a[hdr + i] = (uint8_t)(i * 31u + (i >> 9));
    *len_out = total;
    return a;
}

static bool store_round(uint8_t *atlas, size_t len, uint32_t round, int64_t *ms_out)
{
    const size_t hdr = hca_table_bytes(1);
    memset(atlas + hdr + (size_t)(round % ATLAS_H) * ATLAS_W * 2, (int)(round & 0xFF), ATLAS_W * 2);
    uint8_t sha[32];
    mbedtls_sha256(atlas, len, sha, 0);
    const int64_t t0 = esp_timer_get_time();
    storage_writer_t *w = NULL;
    storage_status_t st = storage_asset_write_begin(ATLAS_ID, len, &w);
    player_upload_active(true);
    for (size_t off = 0; st == STORAGE_OK && off < len; off += ATLAS_CHUNK) {
        const size_t n = len - off < ATLAS_CHUNK ? len - off : ATLAS_CHUNK;
        st = storage_asset_write(w, atlas + off, n);
        vTaskDelay(1);   /* a WiFi upload arrives in TCP segments, not in one burst */
    }
    player_upload_active(false);
    if (st != STORAGE_OK) {
        if (w) storage_asset_write_abort(w);
        ESP_LOGE(STAG, "round %lu: write failed: %s", (unsigned long)round, storage_status_str(st));
        return false;
    }
    const bool held = player_release_files(ATLAS_ID, NULL);
    asset_info_t info;
    st = storage_asset_write_finish(w, sha, &info);
    if (st != STORAGE_OK) {
        if (held) player_reload_for(PLAYER_RELOAD_ASSET, ATLAS_ID, false);
        ESP_LOGE(STAG, "round %lu: finish failed: %s", (unsigned long)round, storage_status_str(st));
        return false;
    }
    player_reload_for(PLAYER_RELOAD_ASSET, ATLAS_ID, false);
    *ms_out = (esp_timer_get_time() - t0) / 1000;
    return true;
}

static void stress_task(void *arg)
{
    size_t len = 0;
    uint8_t *atlas = atlas_build(&len);
    if (!atlas) {
        ESP_LOGE(STAG, "no PSRAM for the %d x %d atlas: stress test off", ATLAS_W, ATLAS_H);
        vTaskDelete(NULL);
    }
    vTaskDelay(pdMS_TO_TICKS(CONFIG_PIXELCLIP_BENCH_STRESS_FIRST_S * 1000));
    if (playlist_store(STRESS_PLAYLIST, strlen(STRESS_PLAYLIST)) == ESP_OK) player_reload_playlist();
    else ESP_LOGE(STAG, "playlist store failed");
    uint32_t round = 0, ok = 0, failed = 0;
    for (;;) {
        if (!net_session_active() && s_post) {
            ESP_LOGI(STAG, "opening a session");
            s_post(true);
            vTaskDelay(pdMS_TO_TICKS(4000));   /* splash + SoftAP + mDNS + httpd */
        }
        round++;
        net_session_touch();   /* keep the idle timer away (no HTTP client needed) */
        int64_t ms = 0;
        if (store_round(atlas, len, round, &ms)) ok++;
        else failed++;
        char why[48];
        snprintf(why, sizeof why, "stress round %lu (%lld ms)", (unsigned long)round, (long long)ms);
        net_note_upload(why);
        ESP_LOGI(STAG, "round %lu: %u B stored in %lld ms | ok %lu failed %lu | session %s, BLE %s%s", (unsigned long)round,
                 (unsigned)len, (long long)ms, (unsigned long)ok, (unsigned long)failed,
                 net_session_active() ? "up" : "DOWN", pixelclip_ble_enabled() ? "on" : "off",
                 pixelclip_ble_connected() ? " (central connected)" : "");
        vTaskDelay(pdMS_TO_TICKS(CONFIG_PIXELCLIP_BENCH_STRESS_PERIOD_S * 1000));
    }
}

static void stress_start(void)
{
    ESP_LOGW(STAG, "STRESS BUILD: session + water scene + %d x %d atlas (%u B) every %d s from %d s; /bench/crash, "
             "/bench/wedge enabled; RTC watchdog %d s", ATLAS_W, ATLAS_H, (unsigned)(hca_table_bytes(1) + ATLAS_W * ATLAS_H * 2),
             CONFIG_PIXELCLIP_BENCH_STRESS_PERIOD_S, CONFIG_PIXELCLIP_BENCH_STRESS_FIRST_S, CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S);
    /* 6 KB internal stack: storage writes flash (no PSRAM stack), SHA-256 of the atlas, logging. */
    if (xTaskCreate(stress_task, "stress", 6144, NULL, 3, NULL) != pdPASS) ESP_LOGE(STAG, "no stress task");
}
#endif /* CONFIG_PIXELCLIP_BENCH_STRESS */

void bench_start(bench_post_fn_t post)
{
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST || CONFIG_PIXELCLIP_BENCH_STRESS
    s_post = post;
#else
    (void)post;
#endif
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST
    sleep_test_start();
#endif
#if CONFIG_PIXELCLIP_BENCH_STRESS
    stress_start();
#endif
}
