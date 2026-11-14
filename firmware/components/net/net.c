/* net.c — SoftAP + mDNS + HTTP server lifecycle for upload mode.
 *
 * WiFi driver lifecycle (README "Light sleep on battery"): the driver is initialised at the first session and
 * then only stopped (esp_wifi_stop + WIFI_MODE_NULL) at session end while the BLE doorbell runs, because
 * esp_wifi_deinit() with NimBLE + software coexistence active is the prime suspect of the battery hang
 * (the clip light-slept after a session and never woke). It is fully deinitialised only when BLE is off. */
#include "net.h"
#include "net_priv.h"

#include <string.h>
#include <strings.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_check.h"
#include "mdns.h"
#include "lwip/tcpip.h"
#include "player.h"
#include "appcfg.h"
#include "power.h"
#include "health.h"
#include "pixelclip_ble.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"

static const char *TAG = "net";

#define HOSTNAME        "pixelclip"
#define HTTPD_STACK     10240  /* upload/OTA handlers: cJSON, mbedTLS SHA, LittleFS + esp_ota calls; buffers on heap */
#define END_DELAY_MS    300    /* let the /session/end response flush before teardown */
#define AWAKE_AFTER_MS  10000  /* light sleep stays inhibited this long after a session (README) */
#define HEAP_LOG_US     10000000   /* session heap line every 10 s */

static char s_ssid[33];
static char s_id[8];
static bool s_active;
static bool s_inited;
static esp_netif_t *s_netif;
static httpd_handle_t s_httpd;
static esp_timer_handle_t s_idle_timer, s_end_timer;
static esp_event_handler_instance_t s_wifi_evt;
static net_end_cb_t s_on_end;
static net_client_cb_t s_on_client;
static volatile int64_t s_last_req_us;
static volatile uint32_t s_timeout_s;
static volatile bool s_always_on;          /* running session is permanent */
static bool s_always_on_suspended;         /* long press / BLE end / weak battery: off until reboot */
static bool s_display_on;
static volatile unsigned s_clients;
static volatile bool s_ready;              /* SoftAP + mDNS + HTTP server all up */
static bool s_wifi_inited;                 /* driver + netif + event handler exist (kept while BLE runs) */
static SemaphoreHandle_t s_wifi_lock;      /* driver init / release (controller vs. a config handler) */
static esp_timer_handle_t s_awake_timer;   /* releases the session's awake hold AWAKE_AFTER_MS after the end */
static bool s_awake;                       /* POWER_AWAKE_SESSION held by us */
static int64_t s_next_probe_us, s_next_heap_us;
static volatile uint32_t s_uploads;        /* stored uploads in this session */

const char *net_ssid(void) { return s_ssid; }
const char *net_device_id(void) { return s_id; }
bool net_session_active(void) { return s_active; }
uint32_t net_session_timeout_s(void) { return s_timeout_s; }
bool net_session_display_on(void) { return s_active && s_display_on; }
void net_session_set_display(bool on) { if (s_active) s_display_on = on; }
bool net_session_ready(void) { return s_active && s_ready; }
unsigned net_session_clients(void) { return s_active ? s_clients : 0; }
void net_session_touch(void) { if (s_active) net_touch(); }

bool net_always_on(void)
{
    if (s_active) return s_always_on;
    appcfg_t cfg;
    appcfg_get(&cfg);
    return cfg.wifi_always_on && !s_always_on_suspended;
}

uint32_t net_session_idle_s(void)
{
    if (!s_active) return 0;
    return (uint32_t)((esp_timer_get_time() - s_last_req_us) / 1000000);
}

static void idle_cb(void *arg)
{
    ESP_LOGI(TAG, "idle timeout (%lu s)", (unsigned long)s_timeout_s);
    if (s_on_end) s_on_end(NET_END_IDLE_TIMEOUT);
}

static void end_cb(void *arg)
{
    if (s_on_end) s_on_end(NET_END_CLIENT);
}

/* (Re)arm the idle timer for timeout_s after the last HTTP request (s_last_req_us). */
static void rearm_idle(void)
{
    if (!s_idle_timer) return;
    esp_timer_stop(s_idle_timer); /* ESP_ERR_INVALID_STATE if not running: fine */
    if (s_always_on) return;      /* permanent session: no idle timeout */
    const int64_t left = (int64_t)s_timeout_s * 1000000 - (esp_timer_get_time() - s_last_req_us);
    esp_err_t err = esp_timer_start_once(s_idle_timer, left > 1000 ? (uint64_t)left : 1000);
    if (err != ESP_OK) ESP_LOGE(TAG, "idle timer: %s", esp_err_to_name(err));
}

void net_touch(void)
{
    s_last_req_us = esp_timer_get_time();
    rearm_idle();
}

/* Called from PUT /config. Over HTTP the request has just touched the timer, so this equals a fresh
 * timeout; over the BLE fast lane the idle time so far keeps counting (fast-lane requests never extend a
 * WiFi session). */
void net_set_timeout_s(uint32_t s)
{
    s_timeout_s = s;
    if (s_active) rearm_idle();
}

void net_always_on_config(bool enabled)
{
    if (enabled) s_always_on_suspended = false;
    if (!s_active || s_always_on == enabled) return;
    s_always_on = enabled;
    ESP_LOGI(TAG, "always-on %s for this session", enabled ? "enabled" : "disabled (idle timeout again)");
    rearm_idle();   /* stops the idle timer, or re-arms it (from the last HTTP request) */
}

void net_always_on_suspend(void)
{
    appcfg_t cfg;
    appcfg_get(&cfg);
    if (cfg.wifi_always_on && !s_always_on_suspended) ESP_LOGI(TAG, "always-on suspended until reboot");
    s_always_on_suspended = true;
    s_always_on = false;
}

void net_request_end_soon(void)
{
    esp_timer_stop(s_end_timer);
    esp_err_t err = esp_timer_start_once(s_end_timer, END_DELAY_MS * 1000);
    if (err != ESP_OK) ESP_LOGE(TAG, "end timer: %s", esp_err_to_name(err));
}

static void awake_cb(void *arg)
{
    /* esp_timer task. The controller may have started a new session meanwhile: it stopped this timer first,
     * but a callback already running is not cancelled, hence the check. */
    if (s_active || !s_awake) return;
    s_awake = false;
    power_awake_release(POWER_AWAKE_SESSION);
    ESP_LOGI(TAG, "session: light sleep allowed again (%d s after the session); awake holds session=%d fastlane=%d usb=%d",
             AWAKE_AFTER_MS / 1000, power_awake_held(POWER_AWAKE_SESSION), power_awake_held(POWER_AWAKE_FASTLANE),
             power_awake_held(POWER_AWAKE_USB));
    /* Baseline after a session: no session hold, and no fast-lane hold unless a request is in flight. */
    if (power_awake_held(POWER_AWAKE_SESSION) != 0) {
        ESP_LOGE(TAG, "ASSERTION: %d session awake hold(s) left after the session", power_awake_held(POWER_AWAKE_SESSION));
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST || CONFIG_PIXELCLIP_BENCH_STRESS
        abort();
#endif
    }
    pixelclip_ble_fast_lane_holds_ok("after the session");
}

void net_log_heap(const char *why)
{
    char live[128];
    health_liveness_report(live, sizeof live);
    ESP_LOGI(TAG, "heap %s: internal %u B free (min %u, largest %u), psram %u B free | uploads %lu | awake holds "
             "session=%d fastlane=%d usb=%d, light sleeps %lu, while inhibited %lu, while usb %lu | liveness %s",
             why, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM), (unsigned long)s_uploads,
             power_awake_held(POWER_AWAKE_SESSION), power_awake_held(POWER_AWAKE_FASTLANE),
             power_awake_held(POWER_AWAKE_USB), (unsigned long)power_light_sleeps(),
             (unsigned long)power_awake_violations(), (unsigned long)power_light_sleeps_while_usb(), live);
    pixelclip_ble_fast_lane_holds_ok("between requests");   /* fastlane=N must read 0 here unless one is in flight */
    if (power_awake_violations() != 0) {
        ESP_LOGE(TAG, "ASSERTION: %lu light sleep(s) entered while an awake hold was held",
                 (unsigned long)power_awake_violations());
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST || CONFIG_PIXELCLIP_BENCH_STRESS
        abort();
#endif
    }
}

void net_note_upload(const char *what)
{
    s_uploads++;
    health_note_upload();
    char why[64];
    snprintf(why, sizeof why, "after upload %s", what ? what : "?");
    net_log_heap(why);
}

/* Liveness probes (health.h): run in the httpd task / the lwIP thread; if either is wedged its beat goes stale. */
static void httpd_probe(void *arg) { health_beat(HEALTH_SRC_HTTPD); }
static void tcpip_probe(void *arg) { health_beat(HEALTH_SRC_TCPIP); }

void net_session_service(void)
{
    if (!s_active || !s_ready) return;
    const int64_t now = esp_timer_get_time();
    if (now >= s_next_probe_us) {
        s_next_probe_us = now + (int64_t)HEALTH_PROBE_PERIOD_MS * 1000;
        /* httpd_queue_work runs between requests; a running handler beats on its own recv/send. A full work
         * queue (control socket busy) just skips this probe. */
        if (s_httpd) httpd_queue_work(s_httpd, httpd_probe, NULL);
        tcpip_try_callback(tcpip_probe, NULL);
    }
    if (now >= s_next_heap_us) {
        s_next_heap_us = now + HEAP_LOG_US;
        net_log_heap("in session");
    }
}

esp_err_t net_init(void)
{
    http_api_init();   /* first: the BLE fast lane serves the API even if the rest fails */
    uint8_t mac[6];
    ESP_RETURN_ON_ERROR(esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP), TAG, "read mac");
    snprintf(s_ssid, sizeof s_ssid, "PixelClip-%02X%02X", mac[4], mac[5]);
    snprintf(s_id, sizeof s_id, "%02x%02x", mac[4], mac[5]);
    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "netif init");
    /* One-shot timers always wake the chip from light sleep (skip_unhandled_events only exists for
     * periodic timers); spelled out because the session end depends on it. */
    const esp_timer_create_args_t idle = { .callback = idle_cb, .name = "net_idle", .skip_unhandled_events = false };
    const esp_timer_create_args_t end = { .callback = end_cb, .name = "net_end", .skip_unhandled_events = false };
    ESP_RETURN_ON_ERROR(esp_timer_create(&idle, &s_idle_timer), TAG, "timer");
    ESP_RETURN_ON_ERROR(esp_timer_create(&end, &s_end_timer), TAG, "timer");
    const esp_timer_create_args_t awake = { .callback = awake_cb, .name = "net_awake", .skip_unhandled_events = false };
    ESP_RETURN_ON_ERROR(esp_timer_create(&awake, &s_awake_timer), TAG, "timer");
    s_wifi_lock = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_wifi_lock, ESP_ERR_NO_MEM, TAG, "lock");
    s_inited = true;
    ESP_LOGI(TAG, "SSID %s (WiFi off until upload mode)", s_ssid);
    return ESP_OK;
}

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (id == WIFI_EVENT_AP_STACONNECTED) {
        const wifi_event_ap_staconnected_t *e = data;
        ESP_LOGI(TAG, "station " MACSTR " joined", MAC2STR(e->mac));
        net_touch();
        if (s_clients++ == 0 && s_on_client) s_on_client(true);
    } else if (id == WIFI_EVENT_AP_STADISCONNECTED) {
        const wifi_event_ap_stadisconnected_t *e = data;
        ESP_LOGI(TAG, "station " MACSTR " left", MAC2STR(e->mac));
        if (s_clients > 0 && --s_clients == 0 && s_on_client) s_on_client(false);
    }
}

/* TX cap for the running session: lower on battery (peak current under TX sags the 500 mAh cell). */
static int tx_cap_dbm(void)
{
    return power_on_battery() ? CONFIG_PIXELCLIP_WIFI_MAX_TX_DBM_BATTERY : CONFIG_PIXELCLIP_WIFI_MAX_TX_DBM;
}

static void apply_tx_power(void)
{
    const int dbm = tx_cap_dbm();
    esp_err_t err = esp_wifi_set_max_tx_power((int8_t)(dbm * 4));
    int8_t pwr = 0;
    if (err == ESP_OK && esp_wifi_get_max_tx_power(&pwr) == ESP_OK) {
        ESP_LOGI(TAG, "TX cap %.2f dBm (%s)", pwr / 4.0, power_on_battery() ? "battery" : "USB");
    } else if (err != ESP_OK) {
        ESP_LOGE(TAG, "tx power: %s", esp_err_to_name(err));
    }
}

void net_apply_tx_power(void)
{
    if (s_active && s_ready) apply_tx_power();
}

/* Driver + netif + event handler, once (kept across sessions while BLE runs). Caller holds s_wifi_lock. */
static esp_err_t wifi_driver_init(void)
{
    if (!s_netif) s_netif = esp_netif_create_default_wifi_ap();
    ESP_RETURN_ON_FALSE(s_netif, ESP_FAIL, TAG, "netif");
    if (!s_wifi_inited) {
        wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
        ESP_RETURN_ON_ERROR(esp_wifi_init(&init), TAG, "wifi init");
        s_wifi_inited = true;   /* from here on wifi_driver_release() undoes it */
        ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), TAG, "storage");
        ESP_LOGI(TAG, "WiFi driver initialised");
    }
    if (!s_wifi_evt) {
        ESP_RETURN_ON_ERROR(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL, &s_wifi_evt),
                            TAG, "event register");
    }
    return ESP_OK;
}

/* Full teardown (radio already stopped). Only while BLE is off: esp_wifi_deinit() under an active NimBLE +
 * coexistence is what this design avoids. Caller holds s_wifi_lock. */
static void wifi_driver_release(void)
{
    if (s_wifi_evt) {
        esp_event_handler_instance_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, s_wifi_evt);
        s_wifi_evt = NULL;
    }
    if (s_wifi_inited) {
        esp_err_t err = esp_wifi_deinit();
        if (err != ESP_OK && err != ESP_ERR_WIFI_NOT_INIT) ESP_LOGE(TAG, "wifi_deinit: %s", esp_err_to_name(err));
        s_wifi_inited = false;
    }
    if (s_netif) {
        esp_netif_destroy_default_wifi(s_netif);
        s_netif = NULL;
    }
}

void net_wifi_release_if_idle(void)
{
    if (!s_wifi_lock) return;
    xSemaphoreTake(s_wifi_lock, portMAX_DELAY);
    if (!s_active && s_wifi_inited && !pixelclip_ble_enabled()) {
        wifi_driver_release();
        ESP_LOGI(TAG, "WiFi driver deinitialised (BLE off)");
    }
    xSemaphoreGive(s_wifi_lock);
}

/* Overwrite a buffer that held the passphrase (volatile: the compiler must not drop a "dead" store). */
static void wipe(void *p, size_t n)
{
    volatile uint8_t *b = p;
    while (n--) *b++ = 0;
}

bool net_host_allowed(const char *host)
{
    char ip[16] = "192.168.4.1";   /* the SoftAP default, should the lookup fail */
    esp_netif_ip_info_t info;
    if (s_netif && esp_netif_get_ip_info(s_netif, &info) == ESP_OK && info.ip.addr != 0) {
        esp_ip4addr_ntoa(&info.ip, ip, sizeof ip);
    }
    size_t n = strlen(host);
    if (n > 3 && strcmp(host + n - 3, ":80") == 0) n -= 3;
    static const char name[] = HOSTNAME ".local";
    return (n == strlen(ip) && memcmp(host, ip, n) == 0) || (n == sizeof name - 1 && strncasecmp(host, name, n) == 0);
}

static esp_err_t start_wifi(void)
{
    xSemaphoreTake(s_wifi_lock, portMAX_DELAY);
    esp_err_t err = wifi_driver_init();
    xSemaphoreGive(s_wifi_lock);
    ESP_RETURN_ON_ERROR(err, TAG, "driver");
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_AP), TAG, "mode");

    wifi_config_t ap = {
        .ap = {
            .channel = CONFIG_PIXELCLIP_WIFI_CHANNEL,
            .max_connection = 1,
            .authmode = WIFI_AUTH_WPA2_PSK,
            .pmf_cfg = { .required = false },
            .beacon_interval = 100,
        },
    };
    strlcpy((char *)ap.ap.ssid, s_ssid, sizeof ap.ap.ssid);
    ap.ap.ssid_len = (uint8_t)strlen(s_ssid);
    /* The passphrase goes from appcfg's static storage straight into the driver's config and is wiped from
     * this frame at once: the controller's stack is in every core dump (security audit WIFI-10). */
    _Static_assert(sizeof ap.ap.password >= APPCFG_AP_PASSWORD_MAX, "passphrase buffer");
    appcfg_get_ap_password((char *)ap.ap.password, sizeof ap.ap.password);
    err = esp_wifi_set_config(WIFI_IF_AP, &ap);
    wipe(ap.ap.password, sizeof ap.ap.password);
    ESP_RETURN_ON_ERROR(err, TAG, "ap config");
    ESP_RETURN_ON_ERROR(esp_wifi_set_protocol(WIFI_IF_AP, WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N), TAG, "protocol"); // 11B is mandatory in the mask (ESP_ERR_INVALID_ARG otherwise); the AP still negotiates g/n with modern phones
    ESP_RETURN_ON_ERROR(esp_wifi_set_bandwidth(WIFI_IF_AP, WIFI_BW_HT20), TAG, "bandwidth");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start");
    /* The cap is per esp_wifi_start(): set it every session (battery vs USB may have changed). */
    const int dbm = tx_cap_dbm();
    ESP_RETURN_ON_ERROR(esp_wifi_set_max_tx_power((int8_t)(dbm * 4)), TAG, "tx power");
    int8_t pwr = 0;
    if (esp_wifi_get_max_tx_power(&pwr) == ESP_OK) {
        ESP_LOGI(TAG, "SoftAP %s up on ch %d, TX cap %.2f dBm (%s)", s_ssid, CONFIG_PIXELCLIP_WIFI_CHANNEL, pwr / 4.0,
                 power_on_battery() ? "battery" : "USB");
    }
    return ESP_OK;
}

static esp_err_t start_mdns(const appcfg_t *cfg)
{
    ESP_RETURN_ON_ERROR(mdns_init(), TAG, "mdns init");
    ESP_RETURN_ON_ERROR(mdns_hostname_set(HOSTNAME), TAG, "mdns hostname");
    ESP_RETURN_ON_ERROR(mdns_instance_name_set(cfg->name), TAG, "mdns instance");
    ESP_RETURN_ON_ERROR(mdns_service_add(NULL, "_http", "_tcp", 80, NULL, 0), TAG, "mdns service");
    return ESP_OK;
}

static esp_err_t start_httpd(void)
{
    httpd_config_t hc = HTTPD_DEFAULT_CONFIG();
    hc.stack_size = HTTPD_STACK;
    hc.max_uri_handlers = 48;    /* 44 routes registered (http_api.c) */
    hc.max_open_sockets = 4;
    hc.lru_purge_enable = true;
    /* Slow clients (security audit WIFI-8, http_api.c "slow-client guard"): every blocking socket call returns
     * within HTTP_SOCK_TIMEOUT_S, so the httpd task checks in with the liveness watchdog, and notices a session
     * end, at least that often. How long a quiet client is waited for is decided there, not here. */
    hc.recv_wait_timeout = HTTP_SOCK_TIMEOUT_S;
    hc.send_wait_timeout = HTTP_SOCK_TIMEOUT_S;
    hc.open_fn = http_api_on_open;
    hc.max_resp_headers = 8;
    hc.uri_match_fn = httpd_uri_match_wildcard;
    http_api_stopping(false);
    ESP_RETURN_ON_ERROR(httpd_start(&s_httpd, &hc), TAG, "httpd start");
    return http_api_register(s_httpd);
}

esp_err_t net_session_start(const net_session_opts_t *opts)
{
    if (s_active) return ESP_OK;
    if (!s_inited) return ESP_ERR_INVALID_STATE;   /* net_init() failed at boot */
    appcfg_t cfg;
    appcfg_get(&cfg);
    s_on_end = opts->on_end;
    s_on_client = opts->on_client;
    s_display_on = opts->display_on;
    s_clients = 0;
    s_always_on = cfg.wifi_always_on && !s_always_on_suspended;
    s_timeout_s = cfg.upload_timeout_s;
    health_step(HEALTH_STEP_SESSION_START);
    health_session(true);
    /* No light sleep for the whole session and AWAKE_AFTER_MS after it (README "Session light-sleep
     * inhibit"): explicit NO_LIGHT_SLEEP hold, independent of the perf (CPU_FREQ_MAX) hold below. */
    esp_timer_stop(s_awake_timer);
    if (!s_awake) {
        s_awake = true;
        power_awake_acquire(POWER_AWAKE_SESSION);
    }
    ESP_LOGI(TAG, "session: light sleep inhibited (until %d s after the session ends)", AWAKE_AFTER_MS / 1000);
    power_perf_acquire(POWER_PERF_SESSION);
    s_uploads = 0;
    power_session(true);
    s_active = true;
    esp_err_t err = start_wifi();
    if (err == ESP_OK) err = start_mdns(&cfg);
    if (err == ESP_OK) err = start_httpd();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "session start failed: %s", esp_err_to_name(err));
        net_session_stop();
        return err;
    }
    net_touch();
    s_ready = true;
    /* Liveness during the session: the httpd task and the lwIP thread must answer the probes. */
    health_require(HEALTH_SRC_HTTPD, true);
    health_require(HEALTH_SRC_TCPIP, true);
    s_next_probe_us = 0;
    s_next_heap_us = esp_timer_get_time() + HEAP_LOG_US;
    health_step(HEALTH_STEP_SESSION_UP);
    ESP_LOGI(TAG, "internal heap with WiFi up: %u B free, largest block %u B",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    if (s_always_on) {
        ESP_LOGI(TAG, "upload mode: http://192.168.4.1 / http://" HOSTNAME ".local, ALWAYS ON (no idle timeout), "
                 "panel %s", s_display_on ? "on" : "off");
    } else {
        ESP_LOGI(TAG, "upload mode: http://192.168.4.1 / http://" HOSTNAME ".local, idle timeout %lu s, panel %s",
                 (unsigned long)s_timeout_s, s_display_on ? "on" : "off");
    }
    return ESP_OK;
}

void net_session_stop(void)
{
    if (!s_active) return;
    health_step(HEALTH_STEP_SESSION_STOP);
    s_ready = false;
    health_require(HEALTH_SRC_HTTPD, false);
    health_require(HEALTH_SRC_TCPIP, false);
    esp_timer_stop(s_idle_timer);
    esp_timer_stop(s_end_timer);
    if (s_httpd) {
        health_step(HEALTH_STEP_SESSION_STOP_HTTPD);
        TaskHandle_t t = xTaskGetHandle("httpd");
        if (t) ESP_LOGI(TAG, "httpd stack high-water: %u B free of %u", (unsigned)uxTaskGetStackHighWaterMark(t),
                        (unsigned)HTTPD_STACK);
        /* A request in flight (a stalled upload, a client that stopped reading) gives up at its next socket call,
         * at most HTTP_SOCK_TIMEOUT_S away, instead of holding httpd_stop(), and with it this task, which feeds
         * the RTC watchdog, until the client is done (security audit WIFI-8). */
        http_api_stopping(true);
        esp_err_t err = httpd_stop(s_httpd);
        if (err != ESP_OK) ESP_LOGE(TAG, "httpd_stop: %s", esp_err_to_name(err));
        s_httpd = NULL;
    }
    mdns_free();
    health_step(HEALTH_STEP_SESSION_STOP_WIFI);
    /* Radio off, driver kept: esp_wifi_stop() releases the PHY (refcounted with BLE) and the driver's own PM
     * lock; WIFI_MODE_NULL leaves no interface configured. The full deinit only happens without BLE. */
    esp_err_t err = esp_wifi_stop();
    if (err != ESP_OK && err != ESP_ERR_WIFI_NOT_INIT) ESP_LOGE(TAG, "wifi_stop: %s", esp_err_to_name(err));
    if (s_wifi_inited) {
        err = esp_wifi_set_mode(WIFI_MODE_NULL);
        if (err != ESP_OK) ESP_LOGE(TAG, "wifi mode NULL: %s", esp_err_to_name(err));
    }
    xSemaphoreTake(s_wifi_lock, portMAX_DELAY);
#if CONFIG_PIXELCLIP_BENCH_WIFI_DEINIT
    const bool keep = false;   /* bench bisect: the pre-fix behaviour (deinit under BLE + coexistence) */
#else
    const bool keep = pixelclip_ble_enabled();
#endif
    if (!keep) wifi_driver_release();
    xSemaphoreGive(s_wifi_lock);
    s_active = false;
    s_always_on = false;
    s_clients = 0;
    power_session(false);
    power_perf_release(POWER_PERF_SESSION);
    if (s_awake && esp_timer_start_once(s_awake_timer, (uint64_t)AWAKE_AFTER_MS * 1000) != ESP_OK) {
        s_awake = false;   /* no timer: release now rather than never */
        power_awake_release(POWER_AWAKE_SESSION);
    }
    health_session(false);
    health_step(HEALTH_STEP_SESSION_DONE);
    ESP_LOGI(TAG, "upload mode off, WiFi %s (caller stack high-water %u B)",
             keep ? "stopped, driver kept (BLE on)" : "deinitialised", (unsigned)uxTaskGetStackHighWaterMark(NULL));
}
