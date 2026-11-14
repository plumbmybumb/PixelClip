/* appcfg.c — cJSON-backed configuration with validation and persistence. */
#include "appcfg.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "storage.h"
#include "timekeeping.h"

static const char *TAG = "config";
#define CONFIG_FILE "config.json"
#define CONFIG_MAX_BYTES 4096

static appcfg_t s_cfg;
/* The hotspot passphrase: beside s_cfg, not in it (appcfg.h). Static storage is not part of a core dump
 * (CONFIG_ESP_COREDUMP_CAPTURE_DRAM=n); copies of appcfg_t on task stacks are. */
static char s_ap_password[APPCFG_AP_PASSWORD_MAX];
static SemaphoreHandle_t s_mutex;

/* A config being validated: the public part and the passphrase travel together and are committed together. */
typedef struct {
    appcfg_t c;
    char ap_password[APPCFG_AP_PASSWORD_MAX];
} draft_t;
/* The one draft: static, not on a stack (the callers' stacks are in a core dump), wiped after use. Used by
 * appcfg_init (once, before any other task exists) and by appcfg_merge_json under s_mutex. */
static draft_t s_draft;

/* Overwrite memory that held the passphrase (volatile: the compiler must not drop a "dead" store). */
static void wipe(void *p, size_t n)
{
    volatile uint8_t *b = p;
    while (n--) *b++ = 0;
}

static void set_defaults(draft_t *d)
{
    appcfg_t *c = &d->c;
    memset(d, 0, sizeof *d);
    strlcpy(c->name, "PixelClip", sizeof c->name);
    c->brightness = 230;  /* perceptual level; 160 looked dim on the real panel (gamma 2.2 -> raw 92) */
    c->upload_timeout_s = 120;
    strlcpy(d->ap_password, "pixelclip-2026", sizeof d->ap_password);
    c->low_battery_pct = 8;
    c->default_transition = APPCFG_TRANSITION_FADE;
    c->display_during_upload = true;
    c->wifi_always_on = false;
    c->ble_wake = true;
    c->orientation = APPCFG_ORIENT_AUTO;
}

const char *appcfg_orientation_str(appcfg_orientation_t o)
{
    switch (o) {
    case APPCFG_ORIENT_NORMAL: return "normal";
    case APPCFG_ORIENT_FLIPPED: return "flipped";
    default: return "auto";
    }
}

static bool apply_bool(const cJSON *patch, const char *key, bool *dst, char *msg, size_t msg_len)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(patch, key);
    if (!v) return true;
    if (!cJSON_IsBool(v)) {
        snprintf(msg, msg_len, "%s must be true or false", key);
        return false;
    }
    *dst = cJSON_IsTrue(v);
    return true;
}

static bool valid_password(const char *p)
{
    size_t n = strlen(p);
    if (n < 8 || n > 63) return false;
    for (size_t i = 0; i < n; i++) {
        if (p[i] < 0x20 || p[i] > 0x7E) return false;
    }
    return true;
}

/* Apply `patch` onto `d`; returns false with a message on the first invalid field. `stored` = the document is
 * the clip's own config.json (appcfg_init), not a request: a low_battery_pct above today's maximum, written by
 * a firmware that still accepted 0-50, is clamped instead of throwing the whole stored config away. */
static bool apply(draft_t *d, const cJSON *patch, bool stored, int32_t *tz_out, bool *tz_set, char *msg, size_t msg_len)
{
    appcfg_t *c = &d->c;
    const cJSON *v;
    if ((v = cJSON_GetObjectItemCaseSensitive(patch, "name"))) {
        if (!cJSON_IsString(v) || strlen(v->valuestring) < 1 || strlen(v->valuestring) >= sizeof c->name) {
            snprintf(msg, msg_len, "name must be a 1-64 byte string");
            return false;
        }
        strlcpy(c->name, v->valuestring, sizeof c->name);
    }
    if ((v = cJSON_GetObjectItemCaseSensitive(patch, "brightness"))) {
        if (!cJSON_IsNumber(v) || v->valuedouble < 0 || v->valuedouble > 255) {
            snprintf(msg, msg_len, "brightness must be 0-255");
            return false;
        }
        c->brightness = (uint8_t)v->valueint;
    }
    if ((v = cJSON_GetObjectItemCaseSensitive(patch, "upload_timeout_s"))) {
        if (!cJSON_IsNumber(v) || v->valuedouble < 30 || v->valuedouble > 1800) {
            snprintf(msg, msg_len, "upload_timeout_s must be 30-1800");
            return false;
        }
        c->upload_timeout_s = (uint16_t)v->valueint;
    }
    if ((v = cJSON_GetObjectItemCaseSensitive(patch, "ap_password"))) {
        if (!cJSON_IsString(v) || !valid_password(v->valuestring)) {
            snprintf(msg, msg_len, "ap_password must be 8-63 printable ASCII characters");
            return false;
        }
        strlcpy(d->ap_password, v->valuestring, sizeof d->ap_password);
    }
    if ((v = cJSON_GetObjectItemCaseSensitive(patch, "low_battery_pct"))) {
        /* 0-20 (was 0-50; security audit BLE-4): at 50 one request turned the clip off below half charge, and
         * kept turning it off after every wake. The 3.40 V floor in power.c does not depend on this value. */
        const double max = stored ? 50 : APPCFG_LOW_BATTERY_PCT_MAX;
        if (!cJSON_IsNumber(v) || v->valuedouble < 0 || v->valuedouble > max) {
            snprintf(msg, msg_len, "low_battery_pct must be 0-%d", APPCFG_LOW_BATTERY_PCT_MAX);
            return false;
        }
        c->low_battery_pct = v->valueint > APPCFG_LOW_BATTERY_PCT_MAX ? APPCFG_LOW_BATTERY_PCT_MAX : (uint8_t)v->valueint;
    }
    if ((v = cJSON_GetObjectItemCaseSensitive(patch, "default_transition"))) {
        if (cJSON_IsString(v) && strcmp(v->valuestring, "cut") == 0) {
            c->default_transition = APPCFG_TRANSITION_CUT;
        } else if (cJSON_IsString(v) && strcmp(v->valuestring, "fade") == 0) {
            c->default_transition = APPCFG_TRANSITION_FADE;
        } else {
            snprintf(msg, msg_len, "default_transition must be \"cut\" or \"fade\"");
            return false;
        }
    }
    if ((v = cJSON_GetObjectItemCaseSensitive(patch, "tz_offset_s"))) {
        if (!cJSON_IsNumber(v) || v->valuedouble < -14 * 3600 || v->valuedouble > 14 * 3600) {
            snprintf(msg, msg_len, "tz_offset_s must be within +/-50400");
            return false;
        }
        *tz_out = (int32_t)v->valueint;
        *tz_set = true;
    }
    if ((v = cJSON_GetObjectItemCaseSensitive(patch, "orientation"))) {
        static const appcfg_orientation_t all[] = { APPCFG_ORIENT_AUTO, APPCFG_ORIENT_NORMAL, APPCFG_ORIENT_FLIPPED };
        size_t i = 0;
        while (i < 3 && !(cJSON_IsString(v) && strcmp(v->valuestring, appcfg_orientation_str(all[i])) == 0)) i++;
        if (i == 3) {
            snprintf(msg, msg_len, "orientation must be \"auto\", \"normal\" or \"flipped\"");
            return false;
        }
        c->orientation = all[i];
    }
    if (!apply_bool(patch, "display_during_upload", &c->display_during_upload, msg, msg_len)) return false;
    if (!apply_bool(patch, "wifi_always_on", &c->wifi_always_on, msg, msg_len)) return false;
    if (!apply_bool(patch, "ble_wake", &c->ble_wake, msg, msg_len)) return false;
    return true;
}

/* `with_secret`: only the copy written to config.json carries the passphrase; the API view never does. */
static cJSON *to_json_locked(bool with_secret)
{
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "name", s_cfg.name);
    cJSON_AddNumberToObject(o, "brightness", s_cfg.brightness);
    cJSON_AddNumberToObject(o, "upload_timeout_s", s_cfg.upload_timeout_s);
    if (with_secret) cJSON_AddStringToObject(o, "ap_password", s_ap_password);
    cJSON_AddNumberToObject(o, "low_battery_pct", s_cfg.low_battery_pct);
    cJSON_AddStringToObject(o, "default_transition",
                            s_cfg.default_transition == APPCFG_TRANSITION_CUT ? "cut" : "fade");
    cJSON_AddNumberToObject(o, "tz_offset_s", timekeeping_tz());
    cJSON_AddBoolToObject(o, "display_during_upload", s_cfg.display_during_upload);
    cJSON_AddBoolToObject(o, "wifi_always_on", s_cfg.wifi_always_on);
    cJSON_AddBoolToObject(o, "ble_wake", s_cfg.ble_wake);
    cJSON_AddStringToObject(o, "orientation", appcfg_orientation_str(s_cfg.orientation));
    return o;
}

static esp_err_t save_locked(void)
{
    cJSON *o = to_json_locked(true);
    cJSON_DeleteItemFromObject(o, "tz_offset_s"); /* lives in NVS (timekeeping) */
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!s) return ESP_ERR_NO_MEM;
    const size_t n = strlen(s);
    esp_err_t err = storage_write_file(CONFIG_FILE, s, n);
    wipe(s, n);   /* the printed document holds the passphrase */
    cJSON_free(s);
    return err;
}

esp_err_t appcfg_init(void)
{
    s_mutex = xSemaphoreCreateMutex();
    if (!s_mutex) return ESP_ERR_NO_MEM;
    draft_t *d = &s_draft;
    set_defaults(d);
    s_cfg = d->c;
    memcpy(s_ap_password, d->ap_password, sizeof s_ap_password);
    char *buf = NULL;
    size_t len = 0;
    esp_err_t err = storage_read_file(CONFIG_FILE, &buf, &len, CONFIG_MAX_BYTES);
    if (err == ESP_OK) {
        cJSON *j = cJSON_ParseWithLength(buf, len);
        char msg[96];
        int32_t tz;
        bool tz_set = false;
        if (j && apply(d, j, true, &tz, &tz_set, msg, sizeof msg)) {
            s_cfg = d->c;
            memcpy(s_ap_password, d->ap_password, sizeof s_ap_password);
        } else {
            ESP_LOGW(TAG, "config.json invalid, using defaults");
        }
        cJSON_Delete(j);
        wipe(buf, len);   /* the file text holds the passphrase */
        free(buf);
    } else if (err != ESP_ERR_NOT_FOUND) {
        ESP_LOGE(TAG, "read config: %s", esp_err_to_name(err));
    }
    ESP_LOGI(TAG, "name \"%s\", brightness %u, upload timeout %u s, low battery %u%%, screen during upload %s, "
             "wifi always on %s, ble wake %s, orientation %s", s_cfg.name, s_cfg.brightness, s_cfg.upload_timeout_s, s_cfg.low_battery_pct,
             s_cfg.display_during_upload ? "on" : "off", s_cfg.wifi_always_on ? "yes" : "no", s_cfg.ble_wake ? "on" : "off",
             appcfg_orientation_str(s_cfg.orientation));
    wipe(d, sizeof *d);
    return ESP_OK;
}

void appcfg_get(appcfg_t *out)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    *out = s_cfg;
    xSemaphoreGive(s_mutex);
}

void appcfg_get_ap_password(char *out, size_t out_len)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    strlcpy(out, s_ap_password, out_len);
    xSemaphoreGive(s_mutex);
}

cJSON *appcfg_to_json(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    cJSON *o = to_json_locked(false);
    xSemaphoreGive(s_mutex);
    return o;
}

esp_err_t appcfg_merge_json(const cJSON *patch, char *msg, size_t msg_len)
{
    if (!cJSON_IsObject(patch)) {
        snprintf(msg, msg_len, "body must be a JSON object");
        return ESP_ERR_INVALID_ARG;
    }
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    draft_t *d = &s_draft;   /* not on the caller's stack: the httpd task or the fast-lane worker */
    d->c = s_cfg;
    memcpy(d->ap_password, s_ap_password, sizeof d->ap_password);
    int32_t tz = 0;
    bool tz_set = false;
    esp_err_t err = ESP_OK;
    if (!apply(d, patch, false, &tz, &tz_set, msg, msg_len)) {
        err = ESP_ERR_INVALID_ARG;
    } else {
        s_cfg = d->c;
        memcpy(s_ap_password, d->ap_password, sizeof s_ap_password);
        err = save_locked();
        if (err != ESP_OK) snprintf(msg, msg_len, "could not persist config");
    }
    wipe(d, sizeof *d);
    xSemaphoreGive(s_mutex);
    if (err == ESP_OK && tz_set) err = timekeeping_set_tz(tz);
    return err;
}
