/* pixelclip_ble.h — BLE wake "doorbell" and fast lane (NimBLE peripheral). Contract: pixelclip_ble_uuids.h.
 *
 * Connectable legacy advertising at ~1.0-1.3 s, one GATT service (wake / status / info / req / rsp), no
 * pairing. The fast lane (PROTOCOL §3b) reassembles `req` frames (pixelclip_frame.h), hands the request to the
 * registered API handler on a short-lived worker task and notifies the response on `rsp` in MTU-3 chunks.
 * The controller sleeps between advertising events (CONFIG_BT_CTRL_MODEM_SLEEP, main XTAL as the low
 * power clock), so automatic light sleep keeps working; WiFi/BLE coexistence is the ESP32-S3
 * software coexistence (CONFIG_ESP_COEX_SW_COEXIST_ENABLE).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"
#include "pixelclip_ble_uuids.h"

#ifdef __cplusplus
extern "C" {
#endif

/* What the app reports in the `status` characteristic. */
typedef struct {
    uint16_t mv;
    uint8_t pct;
    uint8_t flags;     /* PIXELCLIP_BLE_FLAG_* */
    uint8_t kind;      /* PIXELCLIP_BLE_KIND_* */
} pixelclip_ble_state_t;

/* A valid `wake` write (PIXELCLIP_BLE_CMD_*). Runs in the NimBLE host task: must not block. Returns a
 * PIXELCLIP_BLE_RESULT_* (ACCEPTED or LOW_BATTERY). */
typedef uint8_t (*pixelclip_ble_cmd_cb_t)(uint8_t cmd);
/* Fill the current state (called from the host task and the 2 s notify timer). */
typedef void (*pixelclip_ble_state_cb_t)(pixelclip_ble_state_t *out);

/* Fast-lane request handler (registered by the HTTP API, components/net). `req` is the reassembled payload
 * "METHOD SP path LF [body]", NUL-terminated at req[req_len] and modifiable in place. Write the response
 * "STATUS SP LF [body]" into rsp (at most rsp_cap bytes) and return its length. Runs on the fast-lane
 * worker task (never the NimBLE host task); may block. */
typedef size_t (*pixelclip_ble_api_fn_t)(char *req, size_t req_len, char *rsp, size_t rsp_cap);
void pixelclip_ble_set_api_handler(pixelclip_ble_api_fn_t fn);

/* Remember the name ("PixelClip-XXXX"), the info string parts and the callbacks. Does not start the radio. */
esp_err_t pixelclip_ble_init(const char *name, const char *device_id, const char *fw_version,
                        pixelclip_ble_cmd_cb_t on_cmd, pixelclip_ble_state_cb_t on_state);
/* Start (NimBLE host + controller, advertising) or stop (full deinit, radio off) the doorbell.
 * Blocking; safe from any task except the NimBLE host task. */
esp_err_t pixelclip_ble_set_enabled(bool enabled);
bool pixelclip_ble_enabled(void);
bool pixelclip_ble_connected(void);
const char *pixelclip_ble_name(void);
/* Liveness (health.h, source BLE): arms / disarms the source with the stack state and posts a ping event the
 * NimBLE host task answers. Controller task, every HEALTH_PROBE_PERIOD_MS. */
void pixelclip_ble_probe(void);
/* Notify a subscribed central if the packed status changed. Safe from any task. */
void pixelclip_ble_status_changed(void);

/* Fast-lane awake holds (power.h POWER_AWAKE_FASTLANE) still counted while no request is in flight: 0 when
 * healthy (each worker releases its hold before it frees the lane). pixelclip_ble_fast_lane_holds_ok() logs
 * `E ble: ASSERTION: N fast-lane awake hold(s) still held <when> ...` when not (abort in the bench builds). */
int pixelclip_ble_fast_lane_leaked_holds(void);
bool pixelclip_ble_fast_lane_holds_ok(const char *when);

#ifdef __cplusplus
}
#endif
