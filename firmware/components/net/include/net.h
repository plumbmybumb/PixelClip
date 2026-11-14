/* net.h — upload-mode network session (PROTOCOL §3/§4).
 *
 * The radio is off outside a session: net_session_start() creates the netif and initialises the WiFi
 * driver (first session only, see below), starts a WPA2 SoftAP ("PixelClip-XXXX", channel 6, 1 station, TX
 * capped at CONFIG_HAIRCLIP_WIFI_MAX_TX_DBM on USB / _BATTERY on battery, 802.11g/n HT20 only), mDNS
 * "pixelclip.local" and the HTTP API on port 80. net_session_stop() stops the HTTP server, mDNS and the radio
 * (esp_wifi_stop + WIFI_MODE_NULL). The driver itself stays initialised while the BLE doorbell runs:
 * esp_wifi_deinit() with NimBLE + coexistence active is avoided (README "Light sleep on battery"); it is
 * deinitialised at session end when BLE is off, or by net_wifi_release_if_idle() when BLE is switched off.
 *
 * "Always reachable" (config wifi_always_on): the session has no idle timeout, POST /session/end does
 * not end it, and only a long press, the BLE "end" command or a weak battery stop it — which also
 * suspends always-on for the rest of this boot (net_always_on_suspend()).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    NET_END_IDLE_TIMEOUT,  /* no HTTP request for upload_timeout_s */
    NET_END_CLIENT,        /* POST /session/end (response already sent) */
} net_end_reason_t;

/* Called from a timer context when the session should end; the receiver must call
 * net_session_stop() from its own task (never from the HTTP server task). */
typedef void (*net_end_cb_t)(net_end_reason_t reason);

/* One-time init (esp_netif, SSID / id from the SoftAP MAC). Does not touch the radio. */
esp_err_t net_init(void);

const char *net_ssid(void);       /* "PixelClip-A1B2" */
const char *net_device_id(void);  /* "a1b2" (same two MAC bytes, lower case) */

/* A station joined (connected = true) or the last one left (false). Called from the event-loop task. */
typedef void (*net_client_cb_t)(bool connected);

typedef struct {
    net_end_cb_t on_end;
    net_client_cb_t on_client;   /* optional */
    bool display_on;             /* the panel keeps playing during this session (reported in /status) */
} net_session_opts_t;

esp_err_t net_session_start(const net_session_opts_t *opts);
/* Re-apply the battery/USB TX cap to the running session (USB plugged / unplugged). */
void net_apply_tx_power(void);
/* No session and BLE off: deinitialise the kept WiFi driver (memory back). Safe from any task. */
void net_wifi_release_if_idle(void);
void net_session_stop(void);
/* Controller loop, every pass: liveness probes for the httpd task and the lwIP thread (every 5 s) and the
 * session heap line (every 10 s) while a session is up. */
void net_session_service(void);
/* One heap line ("net: heap <why>: internal ... free (min, largest), psram ... | liveness ..."). Any task. */
void net_log_heap(const char *why);
/* An upload (asset / text; the stress bench too) was stored: counted, heap line "after upload <what>". */
void net_note_upload(const char *what);
bool net_session_active(void);
/* The session is fully up (SoftAP, mDNS and HTTP server started): what the BLE status reports. */
bool net_session_ready(void);

/* Seconds since the last HTTP request, and the configured idle timeout. */
uint32_t net_session_idle_s(void);
uint32_t net_session_timeout_s(void);
/* Reset the idle timer (an HTTP request, or the BLE "wake" command during a session). */
void net_session_touch(void);
bool net_session_display_on(void);
/* The running session switched to panel-off (battery below 3.9 V on battery): /status.session.display_on. */
void net_session_set_display(bool on);
unsigned net_session_clients(void);

/* Always-on: true while the running session (or the next one) is permanent. */
bool net_always_on(void);
/* wifi_always_on changed through PUT /config: true lifts a suspension and makes a running session
 * permanent at once; false gives it the normal idle timeout again. */
void net_always_on_config(bool enabled);
/* Long press / BLE end / weak battery: always-on off for the rest of this boot (the caller then
 * ends the session). */
void net_always_on_suspend(void);

#ifdef __cplusplus
}
#endif
