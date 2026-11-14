/* appcfg.h — user configuration (PROTOCOL §4 "Config JSON"), persisted to /config.json.
 * `tz_offset_s` is owned by timekeeping (NVS) and only mirrored in the JSON view. */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"
#include "cJSON.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { APPCFG_TRANSITION_CUT = 0, APPCFG_TRANSITION_FADE = 1 } appcfg_transition_t;

/* PROTOCOL §4 "Orientation": auto = 180° flip from gravity, normal / flipped = forced. */
typedef enum { APPCFG_ORIENT_AUTO = 0, APPCFG_ORIENT_NORMAL = 1, APPCFG_ORIENT_FLIPPED = 2 } appcfg_orientation_t;

/* The hotspot passphrase (`ap_password`, 8..63 printable ASCII) is deliberately NOT a member: copies of this
 * struct live on task stacks (app_main's never returns), and task stacks are what a core dump captures. It
 * stays in appcfg.c's static storage and is only handed out by appcfg_get_ap_password(). */
#define APPCFG_AP_PASSWORD_MAX 64   /* buffer size: 63 characters + NUL */
#define APPCFG_LOW_BATTERY_PCT_MAX 20

typedef struct {
    char name[65];              /* UTF-8, 1..64 bytes */
    uint8_t brightness;         /* 0..255 */
    uint16_t upload_timeout_s;  /* 30..1800 */
    uint8_t low_battery_pct;    /* 0..APPCFG_LOW_BATTERY_PCT_MAX (a stored higher value is clamped at load) */
    appcfg_transition_t default_transition;
    bool display_during_upload; /* panel keeps playing during upload sessions (default true) */
    bool wifi_always_on;        /* SoftAP permanently up, no idle timeout (default false) */
    bool ble_wake;              /* BLE "doorbell" advertising + GATT wake service (default true) */
    appcfg_orientation_t orientation; /* default auto */
} appcfg_t;

/* Load defaults, then /config.json if present (needs storage mounted). */
esp_err_t appcfg_init(void);
void appcfg_get(appcfg_t *out);

/* The hotspot passphrase, for the one caller that configures the SoftAP (net.c). `out` must hold
 * APPCFG_AP_PASSWORD_MAX bytes; the caller wipes its copy as soon as the driver has it. */
void appcfg_get_ap_password(char *out, size_t out_len);

/* The config as the API shows it (GET /config, the PUT /config answer; caller deletes). It never contains
 * `ap_password`: the passphrase is write-only on every transport (security audit WIFI-1 / BLE-2). */
cJSON *appcfg_to_json(void);

/* Validate and merge a partial config object, then persist. On validation failure returns
 * ESP_ERR_INVALID_ARG and writes a human message into `msg`. Unknown keys are ignored. */
esp_err_t appcfg_merge_json(const cJSON *patch, char *msg, size_t msg_len);

/* "auto" | "normal" | "flipped" */
const char *appcfg_orientation_str(appcfg_orientation_t o);

#ifdef __cplusplus
}
#endif
