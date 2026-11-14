/* orient.c — PROTOCOL §4 "Orientation": the 180° flip, automatic from gravity or forced by config.
 *
 * Threads: on_sample() runs in the IMU task (10 Hz in the background, 50 Hz while a scene holds the IMU);
 * orient_set_mode() in the HTTP / BLE handler task; orient_apply() in the player task, which is the only
 * caller of display_set_flipped() once the player runs (so a flip always lands between two frames).
 * s_mode and s_want change together under s_mux, so a mode change never races a detector decision. */
#include "orient.h"
#include "orient_priv.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "display.h"
#include "imu.h"

static const char *TAG = "orientation";

#define FLIP_G        0.5f        /* |gy| beyond this is decisive (PROTOCOL: -0.5 / +0.5) */
#define HOLD_US       1000000     /* ... continuously for 1 s */
#define GAP_US        500000      /* a sampling gap longer than this restarts the 1 s */
#define BOOT_SAMPLES  4           /* boot reading: 4 samples at 50 Hz after the 30 ms enable delay (~0.11 s) */
#define BOOT_WAIT_MS  150

static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
static volatile appcfg_orientation_t s_mode = APPCFG_ORIENT_AUTO;
static volatile bool s_want;              /* what the panel should show (true = flipped) */
static volatile bool s_post_pending;      /* s_want changed but the player queue was full: retry */

/* Detector state: IMU task only. */
static int s_cond;                        /* -1: gy < -0.5, +1: gy > +0.5, 0: in between */
static int64_t s_cond_since_us, s_last_us;

/* gy as "-0.83" without float formatting (the IMU task's stack is small). */
static void fmt_g(char *buf, size_t len, float g)
{
    const int c = (int)lroundf(g * 100.0f);
    snprintf(buf, len, "%s%d.%02d", c < 0 ? "-" : "", abs(c) / 100, abs(c) % 100);
}

/* Hand s_want to the player (between frames), or apply it here when there is no player task. The IMU task
 * never blocks on the player (wait 0: a full queue is retried at the next sample); a config change waits. */
static void request(uint32_t wait_ms)
{
    const int r = player_orient_post(wait_ms);
    s_post_pending = r == 0;
    if (r < 0) orient_apply(s_want);   /* no player task yet (boot): nothing is showing, so no scene exemption */
}

static void on_sample(const float lp[3])
{
    const int64_t now = esp_timer_get_time();
    const float gy = lp[1];
    const int cond = gy < -FLIP_G ? -1 : gy > FLIP_G ? 1 : 0;
    if (s_mode != APPCFG_ORIENT_AUTO || cond != s_cond || now - s_last_us > GAP_US) {
        s_cond = s_mode == APPCFG_ORIENT_AUTO ? cond : 0;
        s_cond_since_us = now;
    }
    s_last_us = now;
    if (s_cond != 0 && now - s_cond_since_us >= HOLD_US) {
        const bool flip = s_cond < 0;
        bool changed = false;
        portENTER_CRITICAL(&s_mux);
        if (s_mode == APPCFG_ORIENT_AUTO && s_want != flip) {
            s_want = flip;
            changed = true;
        }
        portEXIT_CRITICAL(&s_mux);
        if (changed) {
            char g[16];
            fmt_g(g, sizeof g, gy);
            ESP_LOGI(TAG, "%s (gy=%s)", flip ? "flipped" : "normal", g);
            request(0);
            return;
        }
    }
    if (s_post_pending) request(0);
}

void orient_apply(bool flipped)
{
    display_set_flipped(flipped);
}

void orient_init(appcfg_orientation_t mode)
{
    s_mode = mode;
    s_want = mode == APPCFG_ORIENT_FLIPPED;
    if (imu_present()) {
        imu_set_sample_cb(on_sample);
        if (mode == APPCFG_ORIENT_AUTO) {
            /* A short 50 Hz burst for the boot decision, then the 10 Hz background takes over. */
            const uint32_t n0 = imu_sample_count();
            imu_set_background(true);
            imu_keepalive(300);
            for (int i = 0; i < BOOT_WAIT_MS / 10 && imu_sample_count() < n0 + BOOT_SAMPLES; i++) {
                vTaskDelay(pdMS_TO_TICKS(10));
            }
            float g[3];
            if (imu_sample_count() >= n0 + BOOT_SAMPLES && imu_get_gravity_lp(g) && g[1] < -FLIP_G) {
                char gs[16];
                fmt_g(gs, sizeof gs, g[1]);
                portENTER_CRITICAL(&s_mux);
                if (s_mode == APPCFG_ORIENT_AUTO) s_want = true;
                portEXIT_CRITICAL(&s_mux);
                ESP_LOGI(TAG, "flipped (gy=%s, at boot)", gs);
            }
        }
    }
    if (s_want) display_set_flipped(true);
    ESP_LOGI(TAG, "mode %s%s, %s", appcfg_orientation_str(mode),
             mode == APPCFG_ORIENT_AUTO && !imu_present() ? " (no IMU: stays normal)" : "",
             s_want ? "flipped" : "normal");
}

void orient_set_mode(appcfg_orientation_t mode)
{
    portENTER_CRITICAL(&s_mux);
    const appcfg_orientation_t old = s_mode;
    const bool was = s_want;
    s_mode = mode;
    if (mode != APPCFG_ORIENT_AUTO) s_want = mode == APPCFG_ORIENT_FLIPPED;
    const bool want = s_want;
    portEXIT_CRITICAL(&s_mux);
    if (imu_present()) imu_set_background(mode == APPCFG_ORIENT_AUTO);
    if (mode == old) return;
    if (want != was) {
        ESP_LOGI(TAG, "%s (forced)", want ? "flipped" : "normal");
    } else {
        ESP_LOGI(TAG, "mode %s (stays %s)", appcfg_orientation_str(mode), want ? "flipped" : "normal");
    }
    request(1000);
}

appcfg_orientation_t orient_mode(void) { return s_mode; }

bool orient_flipped(void) { return s_want; }
