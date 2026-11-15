/* ota.h — streaming firmware update into the inactive OTA slot, with SHA-256 verification and
 * rollback support (the new image must mark itself valid; see ota_schedule_mark_valid()). */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ota_session ota_session_t;

/* ESP_ERR_INVALID_SIZE if `size` does not fit the slot. */
esp_err_t ota_begin(size_t size, ota_session_t **out);
esp_err_t ota_write(ota_session_t *s, const void *data, size_t len);
/* Verifies length + SHA-256 + image, then sets the boot partition. ESP_ERR_INVALID_CRC on hash
 * mismatch, ESP_ERR_OTA_VALIDATE_FAILED on a bad image. Frees `s` in every case. */
esp_err_t ota_finish(ota_session_t *s, const uint8_t expected_sha[32]);
void ota_abort(ota_session_t *s);

/* Reboot after `ms` (from an esp_timer, so an HTTP response can go out first). */
void ota_restart_in(uint32_t ms);

/* If the running image is pending verification, mark it valid after `delay_s` of uptime. */
void ota_schedule_mark_valid(uint32_t delay_s);

/* The button permission for POST /ota (PROTOCOL §4 "Firmware update", security audit WIFI-2): the state machine
 * of ota_gate.h on the uptime clock, safe from any task (the httpd task asks and checks, the controller task
 * presses and clears). */
typedef struct {
    bool allowed;
    bool asking;
    uint32_t seconds_left;   /* of the current asking or allowed window, 0 when idle */
    uint32_t ms_left;
} ota_permission_t;

void ota_permission_get(ota_permission_t *out);
/* Start or restart the asking window (unless allowed); `out` (may be NULL) gets the state afterwards. The
 * listener runs after it, on the caller's task. */
void ota_permission_ask(ota_permission_t *out);
/* A short press: true if it was used up to allow updates. */
bool ota_permission_press(void);
/* Back to idle: the WiFi session ended, or an image was accepted. */
void ota_permission_clear(void);
/* Called after every ask (the controller shows the prompt). Set once at boot, before any session. */
void ota_permission_set_listener(void (*cb)(void));

#ifdef __cplusplus
}
#endif
