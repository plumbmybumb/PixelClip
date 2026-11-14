/* pixelclip_ble.c — BLE wake "doorbell" + fast lane: NimBLE peripheral with one GATT service (pixelclip_ble_uuids.h).
 *
 * Life cycle: pixelclip_ble_set_enabled(true) = nimble_port_init() (host + controller) + GATT table + host
 * task; advertising starts from the host sync callback.
 *
 * Findable while connected (2026-10-20): iOS sometimes keeps a link the app has let go, and a peripheral that stops
 * advertising while connected is then invisible to the phone's scans. So the clip keeps advertising (connectable, the
 * same data) while one central is connected: two links are allowed (CONFIG_BT_NIMBLE_MAX_CONNECTIONS=2, controller
 * activities 3 = advertising + two links) and the newest central wins: when a second one connects, the first is
 * dropped. A central that sends nothing (no read, write, subscription or MTU exchange) for IDLE_DROP_US is dropped too,
 * so a forgotten link never holds the clip. Advertising stops only for the instant two links exist.
 * pixelclip_ble_set_enabled(false) = nimble_port_stop() + nimble_port_deinit(): radio fully off, memory back.
 *
 * Power: legacy connectable advertising, 1022.5..1285 ms. With CONFIG_BT_CTRL_MODEM_SLEEP the controller
 * sleeps between events on the main-XTAL low-power clock (no 32 kHz crystal on this board), which keeps
 * the 40 MHz XTAL powered during light sleep (CONFIG_BT_CTRL_MAIN_XTAL_PU_DURING_LIGHT_SLEEP). The
 * expected average added current is logged at start (an estimate from datasheet figures, see README).
 *
 * Fast lane (PROTOCOL §3b): `req` writes are reassembled in the NimBLE host task (pixelclip_frame.c, into a
 * PSRAM buffer); a complete request is handed to a short-lived worker task (10 KB internal stack, created
 * per request, so nothing is held while idle) that runs the registered API handler (components/net: the
 * same handlers as HTTP) and notifies the response on `rsp` in ATT_MTU-3 frames. Flow control: before each
 * frame the worker waits until the NimBLE mbuf pool has room for it plus headroom, then waits for the
 * BLE_GAP_EVENT_NOTIFY_TX of that frame (in NimBLE that event means "handed to the stack"; the pool check is
 * what keeps a 16 KB response from exhausting the host's buffers). Error answers that need no handler
 * (bad_frame, 429, 413) are sent from the host task, or queued behind the running response.
 */
#include "pixelclip_ble.h"
#include "pixelclip_frame.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "health.h"
#include "power.h"
#include "sdkconfig.h"

static const char *TAG = "ble";

#define PROTOCOL_VERSION   1
#define ADV_ITVL_MIN       1636    /* x 0.625 ms = 1022.5 ms */
#define ADV_ITVL_MAX       2056    /* x 0.625 ms = 1285 ms */
#define NOTIFY_POLL_US     2000000 /* status change check while a central is subscribed */
#define IDLE_DROP_US       20000000 /* a connected central silent this long is disconnected (findable again) */
#define IDLE_CHECK_US      5000000  /* how often that is checked while a central is connected */
#define MAX_LINKS          CONFIG_BT_NIMBLE_MAX_CONNECTIONS
_Static_assert(CONFIG_BT_NIMBLE_MAX_CONNECTIONS >= 2, "a second link must be possible: the clip advertises while connected");

/* Average-current estimate (not measured; README "BLE doorbell"):
 *  - EST_XTAL_MA: extra light-sleep current because the 40 MHz XTAL stays powered as the BLE low-power
 *    clock (ESP32-S3 light sleep is ~0.24 mA with it off; ~1 mA with it on).
 *  - one advertising event = wake-up from light sleep + ADV_IND on channels 37/38/39 at 0 dBm with the
 *    short RX windows for scan/connect requests: ~3.5 ms at ~90 mA average (datasheet: BLE TX 0 dBm
 *    ~100 mA, RX ~80 mA, CPU active ~25-40 mA). */
#define EST_XTAL_MA        0.75
#define EST_EVENT_MS       3.5
#define EST_EVENT_MA       90.0

/* Fast lane */
#define API_REQ_CAP        (PIXELCLIP_BLE_API_MAX_BYTES + ZF_METHOD_MAX + ZF_PATH_MAX + 3)  /* body + "METHOD SP path CR LF" */
#define API_RSP_CAP        (PIXELCLIP_BLE_API_MAX_BYTES + 8)                               /* body + "STATUS SP LF" */
#define API_TASK_STACK     10240   /* same as the httpd task: the handlers are the same */
#define API_TASK_PRIO      5       /* same as the httpd task */
#define TX_MIN_FREE_BLOCKS 6       /* mbuf blocks that must stay free before a frame is queued (frame <= 3) */
#define TX_STALL_US        3000000 /* give up a response when no frame could be queued for this long */
#define TX_EVT_TIMEOUT_MS  1000
#define API_MIN_SPARE      8192    /* internal RAM that must stay free besides the worker stack (WiFi, LittleFS) */

_Static_assert(ZF_HDR_FIRST == PIXELCLIP_BLE_FRAME_FIRST && ZF_HDR_LAST == PIXELCLIP_BLE_FRAME_LAST &&
               ZF_SEQ_MASK == PIXELCLIP_BLE_FRAME_SEQ_MASK, "pixelclip_frame.h and pixelclip_ble_uuids.h disagree");
_Static_assert(ZF_FRAME_MAX == PIXELCLIP_BLE_PREFERRED_MTU - 3, "frame buffer must hold an MTU-3 frame");

static const ble_uuid128_t s_svc_uuid    = BLE_UUID128_INIT(PIXELCLIP_BLE_SERVICE_UUID_LE);
static const ble_uuid128_t s_wake_uuid   = BLE_UUID128_INIT(PIXELCLIP_BLE_CHR_WAKE_UUID_LE);
static const ble_uuid128_t s_status_uuid = BLE_UUID128_INIT(PIXELCLIP_BLE_CHR_STATUS_UUID_LE);
static const ble_uuid128_t s_info_uuid   = BLE_UUID128_INIT(PIXELCLIP_BLE_CHR_INFO_UUID_LE);
static const ble_uuid128_t s_req_uuid    = BLE_UUID128_INIT(PIXELCLIP_BLE_CHR_REQ_UUID_LE);
static const ble_uuid128_t s_rsp_uuid    = BLE_UUID128_INIT(PIXELCLIP_BLE_CHR_RSP_UUID_LE);

static char s_name[24];
static char s_info[48];
static pixelclip_ble_cmd_cb_t s_on_cmd;
static pixelclip_ble_state_cb_t s_on_state;
static SemaphoreHandle_t s_lock;           /* start/stop */
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
static bool s_inited;
static volatile bool s_enabled;            /* stack running */
static volatile bool s_synced;             /* host synced with the controller */
static volatile uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static volatile bool s_notify;             /* central subscribed to `status` */
static uint16_t s_status_handle;
static uint8_t s_own_addr_type;
static uint8_t s_last_result = PIXELCLIP_BLE_RESULT_NONE;
static uint8_t s_last_sent[PIXELCLIP_BLE_STATUS_LEN];
static bool s_last_valid;
static esp_timer_handle_t s_poll_timer;

/* Fast lane state. s_rx and s_req_* are touched only by the host task, except that the worker reads
 * s_req_buf while s_busy (the reassembler never stores while busy). */
static pixelclip_ble_api_fn_t s_api;
static uint8_t *s_req_buf;                 /* PSRAM, API_REQ_CAP + 1 */
static uint8_t *s_rsp_buf;                 /* PSRAM, API_RSP_CAP */
static zf_rx_t s_rx;
static volatile bool s_busy;               /* a request is being handled / its response sent */
static volatile uint32_t s_job_seq;        /* +1 per worker started (with s_busy, under s_mux) */
static volatile bool s_rsp_notify;         /* central subscribed to `rsp` */
static volatile uint16_t s_mtu = BLE_ATT_MTU_DFLT;   /* negotiated ATT MTU of the connection */
static uint16_t s_rsp_handle;
static int64_t s_req_t0;                   /* first frame of the current request */
static SemaphoreHandle_t s_tx_sem;         /* BLE_GAP_EVENT_NOTIFY_TX for `rsp` */
static volatile int s_tx_status;
static char s_pending[112];                /* an error answer queued behind the running response */
static size_t s_pending_len;
static struct ble_npl_event s_ping_ev;     /* liveness probe run by the host task (health.h, BLE source) */
static bool s_ping_inited;
static struct ble_npl_event s_idle_ev;     /* idle-central check, run by the host task */
static esp_timer_handle_t s_idle_timer;
static volatile int64_t s_last_rx_us;      /* the current central's last read / write / subscription / MTU exchange */
static volatile int s_links;               /* connections open (the current central and, for an instant, an old one) */

typedef struct {
    uint16_t conn;
    size_t len;
    int64_t t0;
} api_job_t;

bool pixelclip_ble_enabled(void) { return s_enabled; }
bool pixelclip_ble_connected(void) { return s_enabled && s_conn != BLE_HS_CONN_HANDLE_NONE; }
const char *pixelclip_ble_name(void) { return s_name; }

static void pack_status(uint8_t out[PIXELCLIP_BLE_STATUS_LEN])
{
    pixelclip_ble_state_t st = { 0 };
    if (s_on_state) s_on_state(&st);
    out[0] = (uint8_t)(st.mv & 0xFF);
    out[1] = (uint8_t)(st.mv >> 8);
    out[2] = st.pct;
    out[3] = st.flags;
    out[4] = st.kind;
    out[5] = PROTOCOL_VERSION;
    out[6] = s_last_result;
}

/* Send the status if it changed since the last notification (host task or poll timer). */
static void notify_if_changed(bool force)
{
    if (!s_enabled || !s_synced || !s_notify || s_conn == BLE_HS_CONN_HANDLE_NONE) return;
    uint8_t buf[PIXELCLIP_BLE_STATUS_LEN];
    pack_status(buf);
    bool send;
    taskENTER_CRITICAL(&s_mux);
    send = force || !s_last_valid || memcmp(buf, s_last_sent, sizeof buf) != 0;
    if (send) {
        memcpy(s_last_sent, buf, sizeof buf);
        s_last_valid = true;
    }
    taskEXIT_CRITICAL(&s_mux);
    if (!send) return;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, sizeof buf);
    if (!om) return;
    int rc = ble_gatts_notify_custom(s_conn, s_status_handle, om);   /* consumes om */
    if (rc != 0) ESP_LOGD(TAG, "notify: %d", rc);
}

void pixelclip_ble_status_changed(void)
{
    /* Try-lock: never wait behind a start/stop (which may itself be waiting for the host task). */
    if (!s_lock || xSemaphoreTake(s_lock, 0) != pdTRUE) return;
    notify_if_changed(false);
    xSemaphoreGive(s_lock);
}

static void poll_cb(void *arg) { pixelclip_ble_status_changed(); }

static void poll_timer(bool on)
{
    if (!s_poll_timer) return;
    esp_timer_stop(s_poll_timer);   /* ESP_ERR_INVALID_STATE when not running: fine */
    if (on) esp_timer_start_periodic(s_poll_timer, NOTIFY_POLL_US);
}

/* ------------------------------------------------------------------ fast lane (PROTOCOL §3b) */

void pixelclip_ble_set_api_handler(pixelclip_ble_api_fn_t fn) { s_api = fn; }

static bool rsp_ready(uint16_t conn)
{
    return s_enabled && s_synced && s_rsp_notify && s_conn == conn && conn != BLE_HS_CONN_HANDLE_NONE;
}

/* From the BLE_GAP_EVENT_MTU cache, not ble_att_mtu(): the worker may run after the stack was stopped. */
static size_t frame_max(uint16_t conn)
{
    uint16_t mtu = s_mtu;
    if (mtu < BLE_ATT_MTU_DFLT) mtu = BLE_ATT_MTU_DFLT;
    size_t n = (size_t)mtu - 3;
    return n > ZF_FRAME_MAX ? ZF_FRAME_MAX : n;
}

/* Host task only: queue the frames of a small message without waiting (dropped if the stack is full). */
static void send_nowait(uint16_t conn, const char *msg, size_t len)
{
    if (!rsp_ready(conn)) return;
    zf_tx_t tx;
    zf_tx_init(&tx, (const uint8_t *)msg, len);
    static uint8_t f[ZF_FRAME_MAX];   /* host task only; static: the host stack is 5 KB */
    const size_t max = frame_max(conn);
    size_t n;
    while ((n = zf_tx_next(&tx, f, max)) > 0) {
        struct os_mbuf *om = ble_hs_mbuf_from_flat(f, (uint16_t)n);
        if (!om || ble_gatts_notify_custom(conn, s_rsp_handle, om) != 0) {
            ESP_LOGW(TAG, "fast lane: could not queue an error answer");
            return;
        }
    }
}

/* Host task: answer without a handler. Queued behind the running response if there is one. */
static void reply_small(uint16_t conn, const char *msg)
{
    const size_t n = strnlen(msg, sizeof s_pending);
    bool queued = false;
    taskENTER_CRITICAL(&s_mux);
    if (s_busy) {
        memcpy(s_pending, msg, n);
        s_pending_len = n;
        queued = true;
    }
    taskEXIT_CRITICAL(&s_mux);
    if (!queued) send_nowait(conn, msg, n);
}

/* Worker: queue one frame, with flow control. false = connection gone / stack stopped / stalled. */
static bool notify_frame(uint16_t conn, const uint8_t *f, size_t n)
{
    const int64_t deadline = esp_timer_get_time() + TX_STALL_US;
    for (;;) {
        int rc = BLE_HS_ENOMEM;
        if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(TX_EVT_TIMEOUT_MS)) == pdTRUE) {
            if (!rsp_ready(conn)) {
                xSemaphoreGive(s_lock);
                return false;
            }
            if (os_msys_num_free() >= TX_MIN_FREE_BLOCKS) {
                struct os_mbuf *om = ble_hs_mbuf_from_flat(f, (uint16_t)n);
                if (om) {
                    xSemaphoreTake(s_tx_sem, 0);                        /* drop a stale event */
                    s_tx_status = BLE_HS_ETIMEOUT;
                    rc = ble_gatts_notify_custom(conn, s_rsp_handle, om);   /* consumes om */
                    if (rc == 0) {
                        /* NOTIFY_TX: raised from inside the call above in NimBLE, so normally already given. */
                        if (xSemaphoreTake(s_tx_sem, pdMS_TO_TICKS(TX_EVT_TIMEOUT_MS)) == pdTRUE) rc = s_tx_status;
                        else rc = 0;   /* no event, but the stack took the frame */
                    }
                }
            }
            xSemaphoreGive(s_lock);
        }
        if (rc == 0) return true;
        if (rc != BLE_HS_ENOMEM && rc != BLE_HS_EBUSY) {
            ESP_LOGW(TAG, "fast lane: notify failed (%d)", rc);
            return false;
        }
        if (esp_timer_get_time() > deadline) {
            ESP_LOGW(TAG, "fast lane: response stalled (no BLE buffers for %d s)", TX_STALL_US / 1000000);
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(5));   /* buffers drain as the controller sends (one or more per connection event) */
    }
}

/* Worker: send a whole response. Returns the number of frames sent (0 = not delivered). */
static size_t send_response(uint16_t conn, const uint8_t *msg, size_t len)
{
    zf_tx_t tx;
    zf_tx_init(&tx, msg, len);
    uint8_t f[ZF_FRAME_MAX];
    size_t frames = 0, n;
    while ((n = zf_tx_next(&tx, f, frame_max(conn))) > 0) {
        if (!notify_frame(conn, f, n)) return 0;
        frames++;
    }
    return frames;
}

static int status_of(const uint8_t *rsp, size_t len)
{
    int st = 0;
    for (size_t i = 0; i < 3 && i < len && rsp[i] >= '0' && rsp[i] <= '9'; i++) st = st * 10 + (rsp[i] - '0');
    return st;
}

static void api_worker(void *arg)
{
    const api_job_t job = *(api_job_t *)arg;
    free(arg);
    /* Request line for the log, copied before the handler parses (and modifies) the buffer. */
    char line[64];
    size_t ll = 0;
    while (ll < job.len && ll < sizeof line - 1 && s_req_buf[ll] != '\n' && s_req_buf[ll] != '\r') {
        line[ll] = (char)s_req_buf[ll];
        ll++;
    }
    line[ll] = '\0';

    const int64_t t1 = esp_timer_get_time();
    size_t rlen;
    if (s_api) {
        rlen = s_api((char *)s_req_buf, job.len, (char *)s_rsp_buf, API_RSP_CAP);
    } else {
        rlen = (size_t)snprintf((char *)s_rsp_buf, API_RSP_CAP,
                                "503 \n{\"ok\":false,\"error\":\"unavailable\",\"message\":\"fast lane not ready\"}");
    }
    if (rlen > API_RSP_CAP) rlen = API_RSP_CAP;
    const int64_t t2 = esp_timer_get_time();
    const size_t mtu = frame_max(job.conn) + 3;
    const size_t frames = send_response(job.conn, s_rsp_buf, rlen);
    const int64_t t3 = esp_timer_get_time();
    const int st = status_of(s_rsp_buf, rlen);

    /* Error answers that arrived meanwhile, then free the lane. The worker's awake hold (taken by the host
     * task with s_busy) is released BEFORE s_busy clears, so "lane idle" always implies "no fast-lane hold":
     * pixelclip_ble_fast_lane_holds_ok() relies on that. (Until 2026-10-15 the worker never released it: one
     * NO_LIGHT_SLEEP hold leaked per request, `awake holds ... fastlane=23` in the session heap lines.) */
    bool held = true;
    for (;;) {
        char extra[sizeof s_pending];
        size_t n = 0;
        taskENTER_CRITICAL(&s_mux);
        if (s_pending_len) {
            n = s_pending_len;
            memcpy(extra, s_pending, n);
            s_pending_len = 0;
        }
        taskEXIT_CRITICAL(&s_mux);
        if (!n) {
            if (held) power_awake_release(POWER_AWAKE_FASTLANE);
            held = false;
            taskENTER_CRITICAL(&s_mux);
            if (s_pending_len) {   /* one slipped in between: send it too */
                n = s_pending_len;
                memcpy(extra, s_pending, n);
                s_pending_len = 0;
            } else {
                s_busy = false;
            }
            taskEXIT_CRITICAL(&s_mux);
            if (!n) break;
            power_awake_acquire(POWER_AWAKE_FASTLANE);
            held = true;
        }
        send_response(job.conn, (const uint8_t *)extra, n);
    }
    if (frames) {
        ESP_LOGI(TAG, "fast lane: %s -> %d, %u B in / %u B out, %lld ms (rx %lld, handler %lld, tx %lld; %u frames, MTU %u)",
                 line, st, (unsigned)job.len, (unsigned)rlen, (t3 - job.t0) / 1000, (t1 - job.t0) / 1000,
                 (t2 - t1) / 1000, (t3 - t2) / 1000, (unsigned)frames, (unsigned)mtu);
    } else {
        ESP_LOGW(TAG, "fast lane: %s -> %d, %u B in, handler %lld ms, response NOT delivered (central gone, not "
                 "subscribed to rsp, or BLE stopped)", line, st, (unsigned)job.len, (t2 - t1) / 1000);
    }
    pixelclip_ble_fast_lane_holds_ok("after a fast-lane request");
    vTaskDelete(NULL);
}

int pixelclip_ble_fast_lane_leaked_holds(void)
{
    /* Consistent snapshot: no worker started (same sequence number) and the lane idle before and after
     * reading the count. The host task bumps s_job_seq and sets s_busy before it acquires a hold, and a
     * worker releases its hold before it clears s_busy, so an idle lane with a non-zero count is a leak. */
    taskENTER_CRITICAL(&s_mux);
    const uint32_t seq1 = s_job_seq;
    const bool busy1 = s_busy;
    taskEXIT_CRITICAL(&s_mux);
    const int held = power_awake_held(POWER_AWAKE_FASTLANE);
    taskENTER_CRITICAL(&s_mux);
    const uint32_t seq2 = s_job_seq;
    const bool busy2 = s_busy;
    taskEXIT_CRITICAL(&s_mux);
    if (busy1 || busy2 || seq1 != seq2) return 0;   /* a request in flight holds one legitimately */
    return held;
}

bool pixelclip_ble_fast_lane_holds_ok(const char *when)
{
    const int leaked = pixelclip_ble_fast_lane_leaked_holds();
    if (leaked == 0) return true;
    ESP_LOGE(TAG, "ASSERTION: %d fast-lane awake hold(s) still held %s with the lane idle (leak)", leaked,
             when ? when : "");
#if CONFIG_PIXELCLIP_BENCH_SLEEP_TEST || CONFIG_PIXELCLIP_BENCH_STRESS
    abort();
#endif
    return false;
}

/* Host task: one `req` write. */
static void fast_lane_frame(uint16_t conn, struct os_mbuf *om)
{
    if (!s_req_buf) return;   /* no PSRAM buffers (logged at init) */
    static uint8_t f[ZF_FRAME_MAX];   /* host task only; static: the host stack is 5 KB */
    uint16_t n = 0;
    const uint16_t total = OS_MBUF_PKTLEN(om);
    if (total > sizeof f || ble_hs_mbuf_to_flat(om, f, sizeof f, &n) != 0) {
        n = 0;   /* longer than any MTU allows: treat like an empty frame */
    }
    if (total > sizeof f) ESP_LOGW(TAG, "fast lane: %u-byte write is longer than a frame", (unsigned)total);
    const bool busy = s_busy;
    if (n > 0 && (f[0] & ZF_HDR_FIRST) && !busy) s_req_t0 = esp_timer_get_time();
    const uint32_t abandoned = s_rx.abandoned;
    const zf_rx_result_t r = zf_rx_push(&s_rx, f, n, busy);
    if (s_rx.abandoned != abandoned) ESP_LOGW(TAG, "fast lane: new request before the last frame of the previous one (dropped it)");
    switch (r) {
    case ZF_DONE: {
        /* The worker's 10 KB stack must be internal (handlers write flash). Refuse with a retryable 503 when it
         * would eat the last internal RAM a WiFi session needs, instead of starving WiFi / LittleFS. */
        const size_t largest = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
        const size_t free_b = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
        api_job_t *job = NULL;
        if (largest >= API_TASK_STACK + 512 && free_b >= API_TASK_STACK + API_MIN_SPARE) job = malloc(sizeof *job);
        if (job) {
            job->conn = conn;
            job->len = s_rx.len;
            job->t0 = s_req_t0;
            taskENTER_CRITICAL(&s_mux);
            s_busy = true;
            s_job_seq++;
            taskEXIT_CRITICAL(&s_mux);
            /* No light sleep while a worker runs; the worker releases it before it frees the lane. */
            power_awake_acquire(POWER_AWAKE_FASTLANE);
            if (xTaskCreatePinnedToCore(api_worker, "ble_api", API_TASK_STACK, job, API_TASK_PRIO, NULL, tskNO_AFFINITY) == pdPASS) break;
            power_awake_release(POWER_AWAKE_FASTLANE);
            s_busy = false;
            free(job);
        }
        ESP_LOGE(TAG, "fast lane: no memory for the worker task (internal heap %u B free, largest %u; need %d + %d spare)",
                 (unsigned)free_b, (unsigned)largest, API_TASK_STACK, API_MIN_SPARE);
        reply_small(conn, "503 \n{\"ok\":false,\"error\":\"no_memory\",\"message\":\"the clip is short of memory right now: retry in a few seconds\"}");
        break;
    }
    case ZF_BUSY:
        ESP_LOGW(TAG, "fast lane: request while another is in flight -> 429");
        reply_small(conn, "429 \n{\"ok\":false,\"error\":\"busy\",\"message\":\"one request at a time\"}");
        break;
    case ZF_BAD_FRAME:
        ESP_LOGW(TAG, "fast lane: bad frame (header 0x%02x, %u B: sequence gap or no first frame) -> 400",
                 n ? f[0] : 0, (unsigned)n);
        reply_small(conn, "400 \nbad_frame");
        break;
    case ZF_TOO_LARGE:
        ESP_LOGW(TAG, "fast lane: request larger than %u B -> 413", (unsigned)API_REQ_CAP);
        reply_small(conn, "413 \n{\"ok\":false,\"error\":\"too_large\",\"message\":\"fast-lane requests are limited to 16 KB\"}");
        break;
    case ZF_MORE:
        break;
    }
}

/* ------------------------------------------------------------------ GATT */

static int chr_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    const ble_uuid_t *u = ctxt->chr->uuid;
    if (conn == s_conn) s_last_rx_us = esp_timer_get_time();   /* the central is alive: no idle drop */
    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        if (ble_uuid_cmp(u, &s_status_uuid.u) == 0) {
            uint8_t buf[PIXELCLIP_BLE_STATUS_LEN];
            pack_status(buf);
            return os_mbuf_append(ctxt->om, buf, sizeof buf) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (ble_uuid_cmp(u, &s_info_uuid.u) == 0) {
            return os_mbuf_append(ctxt->om, s_info, strlen(s_info)) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR && ble_uuid_cmp(u, &s_req_uuid.u) == 0) {
        if (conn == s_conn) fast_lane_frame(conn, ctxt->om);   /* a superseded link (being dropped) is not heard */
        return 0;   /* protocol errors are answered on `rsp`, never as ATT errors */
    }
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR && ble_uuid_cmp(u, &s_wake_uuid.u) == 0) {
        uint8_t v[2] = { 0 };
        uint16_t len = 0;
        int att = 0;
        if (OS_MBUF_PKTLEN(ctxt->om) != 1 || ble_hs_mbuf_to_flat(ctxt->om, v, sizeof v, &len) != 0 || len != 1) {
            s_last_result = PIXELCLIP_BLE_RESULT_INVALID;
            att = BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        } else if (v[0] != PIXELCLIP_BLE_CMD_WAKE && v[0] != PIXELCLIP_BLE_CMD_END) {
            s_last_result = PIXELCLIP_BLE_RESULT_INVALID;
            att = BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        } else {
            s_last_result = s_on_cmd ? s_on_cmd(v[0]) : PIXELCLIP_BLE_RESULT_ACCEPTED;
            if (s_last_result == PIXELCLIP_BLE_RESULT_LOW_BATTERY) att = PIXELCLIP_BLE_ATT_ERR_LOW_BATTERY;
        }
        ESP_LOGI(TAG, "wake write 0x%02x (%u B) -> %s", v[0], (unsigned)OS_MBUF_PKTLEN(ctxt->om),
                 s_last_result == PIXELCLIP_BLE_RESULT_ACCEPTED ? "accepted"
                 : s_last_result == PIXELCLIP_BLE_RESULT_LOW_BATTERY ? "refused (battery below the WiFi floor)" : "refused (invalid)");
        notify_if_changed(true);   /* the result byte changed (host task: the stack is alive) */
        return att;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            { .uuid = &s_wake_uuid.u, .access_cb = chr_access, .flags = BLE_GATT_CHR_F_WRITE },
            { .uuid = &s_status_uuid.u, .access_cb = chr_access, .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
              .val_handle = &s_status_handle },
            { .uuid = &s_info_uuid.u, .access_cb = chr_access, .flags = BLE_GATT_CHR_F_READ },
            /* Fast lane. `req` also accepts writes with response (same frames), for clients that want them. */
            { .uuid = &s_req_uuid.u, .access_cb = chr_access, .flags = BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE },
            { .uuid = &s_rsp_uuid.u, .access_cb = chr_access, .flags = BLE_GATT_CHR_F_NOTIFY, .val_handle = &s_rsp_handle },
            { 0 },
        },
    },
    { 0 },
};

/* ------------------------------------------------------------------ GAP */

static int gap_event(struct ble_gap_event *ev, void *arg);

static void advertise(void)
{
    if (!s_enabled || !s_synced || s_links >= MAX_LINKS) return;   /* (two links: again when one goes) */
    struct ble_hs_adv_fields f;
    memset(&f, 0, sizeof f);
    f.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    f.uuids128 = (ble_uuid128_t *)&s_svc_uuid;   /* 3 + 18 bytes: the name goes into the scan response */
    f.num_uuids128 = 1;
    f.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&f);
    if (rc == 0) {
        struct ble_hs_adv_fields r;
        memset(&r, 0, sizeof r);
        r.name = (const uint8_t *)s_name;
        r.name_len = (uint8_t)strlen(s_name);
        r.name_is_complete = 1;
        rc = ble_gap_adv_rsp_set_fields(&r);
    }
    if (rc != 0) {
        ESP_LOGE(TAG, "advertising data: %d", rc);
        return;
    }
    struct ble_gap_adv_params p;
    memset(&p, 0, sizeof p);
    p.conn_mode = BLE_GAP_CONN_MODE_UND;
    p.disc_mode = BLE_GAP_DISC_MODE_GEN;
    p.itvl_min = ADV_ITVL_MIN;
    p.itvl_max = ADV_ITVL_MAX;
    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &p, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) ESP_LOGE(TAG, "advertising start: %d (links %d)", rc, s_links);
}

static void idle_timer(bool on)
{
    if (!s_idle_timer) return;
    esp_timer_stop(s_idle_timer);   /* ESP_ERR_INVALID_STATE when not running: fine */
    if (on) esp_timer_start_periodic(s_idle_timer, IDLE_CHECK_US);
}

/* esp_timer task: hand the check to the host task (GAP calls belong there). */
static void idle_cb(void *arg)
{
    if (s_enabled && s_synced && s_ping_inited) ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &s_idle_ev);
}

/* Host task: drop the current central when it has been silent for IDLE_DROP_US (never while a fast-lane request
 * runs: its handler or response may take a while). Advertising resumes on the disconnect. */
static void idle_check(struct ble_npl_event *ev)
{
    const uint16_t c = s_conn;
    if (c == BLE_HS_CONN_HANDLE_NONE || s_busy) return;
    const int64_t quiet = esp_timer_get_time() - s_last_rx_us;
    if (quiet < IDLE_DROP_US) return;
    ESP_LOGI(TAG, "idle central dropped after %d s (handle %u, silent %lld s)", IDLE_DROP_US / 1000000, c,
             (long long)(quiet / 1000000));
    const int rc = ble_gap_terminate(c, BLE_ERR_REM_USER_CONN_TERM);
    if (rc != 0 && rc != BLE_HS_EALREADY) ESP_LOGW(TAG, "idle central: terminate %d", rc);
}

static int gap_event(struct ble_gap_event *ev, void *arg)
{
    switch (ev->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (ev->connect.status == 0) {
            s_links++;
            const uint16_t old = s_conn;
            if (old != BLE_HS_CONN_HANDLE_NONE && old != ev->connect.conn_handle) {
                /* Newest wins: the phone that connects now is the one that wants the clip; the old link (often one
                 * iOS kept after the app let go) is dropped. Its disconnect event only updates the link count. */
                ESP_LOGI(TAG, "second central (handle %u): dropping the previous one (handle %u)", ev->connect.conn_handle,
                         old);
                const int trc = ble_gap_terminate(old, BLE_ERR_REM_USER_CONN_TERM);
                if (trc != 0 && trc != BLE_HS_EALREADY) ESP_LOGW(TAG, "terminate previous central: %d", trc);
                s_notify = false;
                poll_timer(false);
            }
            s_conn = ev->connect.conn_handle;
            s_last_rx_us = esp_timer_get_time();
            s_last_valid = false;
            s_rsp_notify = false;
            s_mtu = BLE_ATT_MTU_DFLT;
            zf_rx_reset(&s_rx);
            /* 251-byte link-layer packets: a 517-byte ATT frame then takes 3 packets instead of 20. */
            int rc = ble_gap_set_data_len(ev->connect.conn_handle, 251, 2120);
            ESP_LOGI(TAG, "central connected (handle %u%s), internal heap %u B free (largest block %u B), PSRAM %u B free",
                     ev->connect.conn_handle, rc == 0 ? "" : ", no data length extension",
                     (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                     (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                     (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
            idle_timer(true);
        }
        advertise();   /* keep advertising while connected (findable by scans); not with two links */
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        if (s_links > 0) s_links--;
        if (ev->disconnect.conn.conn_handle != s_conn) {   /* a superseded link went: the current one stays */
            ESP_LOGI(TAG, "previous central disconnected (handle %u, reason 0x%x)", ev->disconnect.conn.conn_handle,
                     ev->disconnect.reason);
            advertise();
            break;
        }
        ESP_LOGI(TAG, "central disconnected (reason 0x%x)", ev->disconnect.reason);
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_notify = false;
        s_rsp_notify = false;
        zf_rx_reset(&s_rx);
        poll_timer(false);
        idle_timer(false);
        advertise();
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (ev->subscribe.conn_handle != s_conn) break;   /* a superseded link */
        s_last_rx_us = esp_timer_get_time();
        if (ev->subscribe.attr_handle == s_status_handle) {
            s_notify = ev->subscribe.cur_notify;
            s_last_valid = false;
            poll_timer(s_notify);
            if (s_notify) notify_if_changed(true);
        } else if (ev->subscribe.attr_handle == s_rsp_handle) {
            s_rsp_notify = ev->subscribe.cur_notify;
        }
        break;
    case BLE_GAP_EVENT_MTU:
        if (ev->mtu.conn_handle != s_conn) break;   /* a superseded link */
        s_last_rx_us = esp_timer_get_time();
        s_mtu = ev->mtu.value;
        ESP_LOGI(TAG, "ATT MTU %u (fast-lane frames of %u B)", ev->mtu.value, (unsigned)(ev->mtu.value - 3));
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        /* Raised in the task that called ble_gatts_notify_custom() (the fast-lane worker). */
        if (ev->notify_tx.attr_handle == s_rsp_handle && !ev->notify_tx.indication) {
            s_tx_status = ev->notify_tx.status;
            if (s_tx_sem) xSemaphoreGive(s_tx_sem);
        }
        break;
    default:
        break;
    }
    return 0;
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0) rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "no usable address: %d", rc);
        return;
    }
    uint8_t addr[6] = { 0 };
    ble_hs_id_copy_addr(s_own_addr_type, addr, NULL);
    s_synced = true;
    advertise();
    const double mean_ms = (ADV_ITVL_MIN + ADV_ITVL_MAX) * 0.625 / 2.0;
    ESP_LOGI(TAG, "advertising %s (%02x:%02x:%02x:%02x:%02x:%02x) every %.1f-%.1f ms, service %s", s_name, addr[5],
             addr[4], addr[3], addr[2], addr[1], addr[0], ADV_ITVL_MIN * 0.625, ADV_ITVL_MAX * 0.625, PIXELCLIP_BLE_SERVICE_UUID);
    ESP_LOGI(TAG, "expected average current added by BLE: ~%.2f mA (estimate: %.2f mA XTAL kept on in light sleep + "
             "%.1f ms x %.0f mA per event / %.0f ms; not measured)", EST_XTAL_MA + EST_EVENT_MS * EST_EVENT_MA / mean_ms,
             EST_XTAL_MA, EST_EVENT_MS, EST_EVENT_MA, mean_ms);
}

static void ping_cb(struct ble_npl_event *ev) { health_beat(HEALTH_SRC_BLE); }

void pixelclip_ble_probe(void)
{
    /* Controller task: post the ping to the host's default event queue (not queued twice). Only while the
     * host runs and is synced; the BLE liveness source is armed / disarmed with that state. */
    if (!s_lock || xSemaphoreTake(s_lock, pdMS_TO_TICKS(50)) != pdTRUE) return;   /* start / stop in progress: next time */
    const bool live = s_enabled && s_synced && s_ping_inited;
    health_require(HEALTH_SRC_BLE, live);
    if (live) ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &s_ping_ev);
    xSemaphoreGive(s_lock);
}

static void on_reset(int reason)
{
    s_synced = false;
    ESP_LOGW(TAG, "host reset (reason %d)", reason);
}

static void host_task(void *arg)
{
    nimble_port_run();            /* returns after nimble_port_stop() */
    nimble_port_freertos_deinit();
}

/* ------------------------------------------------------------------ public */

esp_err_t pixelclip_ble_init(const char *name, const char *device_id, const char *fw_version,
                        pixelclip_ble_cmd_cb_t on_cmd, pixelclip_ble_state_cb_t on_state)
{
    if (s_inited) return ESP_OK;
    s_lock = xSemaphoreCreateMutex();
    if (!s_lock) return ESP_ERR_NO_MEM;
    const esp_timer_create_args_t t = { .callback = poll_cb, .name = "ble_poll" };
    if (esp_timer_create(&t, &s_poll_timer) != ESP_OK) s_poll_timer = NULL;   /* then: notify on events only */
    const esp_timer_create_args_t ti = { .callback = idle_cb, .name = "ble_idle" };
    if (esp_timer_create(&ti, &s_idle_timer) != ESP_OK) s_idle_timer = NULL;   /* then: no idle drop */
    strlcpy(s_name, name, sizeof s_name);
    snprintf(s_info, sizeof s_info, "%s;%s", device_id, fw_version);
    s_on_cmd = on_cmd;
    s_on_state = on_state;
    /* Fast lane: request and response buffers in PSRAM (allocated once, ~33 KB), notify-event semaphore. */
    s_tx_sem = xSemaphoreCreateBinary();
    s_req_buf = heap_caps_malloc(API_REQ_CAP + 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_rsp_buf = heap_caps_malloc(API_RSP_CAP, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_tx_sem || !s_req_buf || !s_rsp_buf) {
        ESP_LOGE(TAG, "fast lane disabled: no PSRAM for its buffers");
        free(s_req_buf);
        free(s_rsp_buf);
        s_req_buf = s_rsp_buf = NULL;
    } else {
        zf_rx_init(&s_rx, s_req_buf, API_REQ_CAP);
    }
    s_inited = true;
    return ESP_OK;
}

static esp_err_t start_locked(void)
{
    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init: %s", esp_err_to_name(err));
        return err;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    /* Largest ATT MTU for the fast lane: the central's Exchange MTU request (iOS / macOS always send one at
     * connect) is answered with 517. (Initiating the exchange from here needs NimBLE's GATT client, which
     * comes with the central role, compiled out.) */
    if (ble_att_set_preferred_mtu(PIXELCLIP_BLE_PREFERRED_MTU) != 0) ESP_LOGW(TAG, "preferred MTU %d refused", PIXELCLIP_BLE_PREFERRED_MTU);
    int rc = ble_gatts_count_cfg(s_svcs);
    if (rc == 0) rc = ble_gatts_add_svcs(s_svcs);
    if (rc == 0) rc = ble_svc_gap_device_name_set(s_name);
    if (rc != 0) {
        ESP_LOGE(TAG, "GATT setup: %d", rc);
        nimble_port_deinit();
        return ESP_FAIL;
    }
    s_conn = BLE_HS_CONN_HANDLE_NONE;
    s_notify = false;
    s_rsp_notify = false;
    zf_rx_reset(&s_rx);
    s_synced = false;
    /* Liveness ping (event pool of the NimBLE port: plenty of spare entries on the S3, whose controller does
     * not use the pool). Created after nimble_port_init, destroyed before nimble_port_deinit. */
    ble_npl_event_init(&s_ping_ev, ping_cb, NULL);
    ble_npl_event_init(&s_idle_ev, idle_check, NULL);
    s_links = 0;
    s_ping_inited = true;
    s_enabled = true;
    nimble_port_freertos_init(host_task);   /* on_sync starts advertising */
    return ESP_OK;
}

static void stop_locked(void)
{
    s_enabled = false;
    health_require(HEALTH_SRC_BLE, false);
    poll_timer(false);
    idle_timer(false);
    int rc = nimble_port_stop();            /* waits for the host task to leave nimble_port_run() */
    if (rc == 0) {
        if (s_ping_inited) {
            ble_npl_event_deinit(&s_ping_ev);    /* back to the pool before nimble_port_deinit frees it */
            ble_npl_event_deinit(&s_idle_ev);
            s_ping_inited = false;
        }
        esp_err_t err = nimble_port_deinit();
        if (err != ESP_OK) ESP_LOGE(TAG, "nimble_port_deinit: %s", esp_err_to_name(err));
    } else {
        ESP_LOGE(TAG, "nimble_port_stop: %d", rc);
    }
    s_synced = false;
    s_notify = false;
    s_rsp_notify = false;
    s_conn = BLE_HS_CONN_HANDLE_NONE;
    s_links = 0;
    ESP_LOGI(TAG, "doorbell off (BLE deinitialised)");
}

esp_err_t pixelclip_ble_set_enabled(bool enabled)
{
    if (!s_inited) return ESP_ERR_INVALID_STATE;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    esp_err_t err = ESP_OK;
    if (enabled && !s_enabled) {
        err = start_locked();
    } else if (!enabled && s_enabled) {
        stop_locked();
    }
    xSemaphoreGive(s_lock);
    return err;
}
