/* api_ble.c — BLE fast-lane adapter (PROTOCOL §3b): reassembled request -> api_req_t -> the same handlers
 * and route table as HTTP (http_api.c) -> "STATUS SP LF [body]".
 *
 * Runs on the fast-lane worker task of components/ble (never the NimBLE host task). Differences from the
 * HTTP adapter, all by design:
 *   - the body is already in memory (no recv hook) and there are no request headers;
 *   - WiFi-only routes (api_route_t.wifi_only: the bulk transfers, /imu, /imu/calibrate, /queue/test) are
 *     answered 413 {"ok":false,"error":"use_wifi"} without running, and so is a PUT /config that carries
 *     `ap_password` (http_api.c);
 *   - the response is collected into the fast-lane buffer; one larger than PIXELCLIP_BLE_API_MAX_BYTES is
 *     replaced by 413 use_wifi;
 *   - net_touch() is never called: a fast-lane request does not start or extend a WiFi session;
 *   - waiting for the handler lock is bounded (a long WiFi upload holds it): 503 busy after 10 s.
 */
#include "api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_log.h"
#include "pixelclip_ble.h"
#include "pixelclip_frame.h"

static const char *TAG = "fastlane";

#define LOCK_TIMEOUT_MS 10000

typedef struct {
    char *buf;
    size_t cap;
    size_t len;
    bool started;
    bool overflow;
} ble_rsp_t;

static void put(ble_rsp_t *w, const char *data, size_t len)
{
    if (w->overflow || !len) return;
    if (len > w->cap - w->len) {
        w->overflow = true;
        return;
    }
    memcpy(w->buf + w->len, data, len);
    w->len += len;
}

/* "STATUS SP LF": the three-digit code of an HTTP status line ("422 Unprocessable Entity" -> "422 \n"). */
static void start(ble_rsp_t *w, const char *status)
{
    char line[8];
    const int code = atoi(status);
    const int n = snprintf(line, sizeof line, "%03d \n", code > 0 && code < 1000 ? code : 500);
    w->len = 0;
    w->overflow = false;
    w->started = true;
    put(w, line, (size_t)n);
}

static esp_err_t ble_send(api_req_t *r, const char *status, const char *type, const char *data, size_t len)
{
    ble_rsp_t *w = r->ctx;
    start(w, status);   /* a second send replaces the first (never happens with the current handlers) */
    put(w, data, len);
    return w->overflow ? ESP_FAIL : ESP_OK;
}

static esp_err_t ble_send_chunk(api_req_t *r, const char *type, const char *data, size_t len)
{
    ble_rsp_t *w = r->ctx;
    if (!w->started) start(w, "200");
    if (data) put(w, data, len);
    return w->overflow ? ESP_FAIL : ESP_OK;   /* stops a streaming handler early, like a closed socket */
}

static const api_ops_t s_ble_ops = {
    .send = ble_send,
    .send_chunk = ble_send_chunk,
    .recv = NULL,     /* streaming bodies are WiFi only: refused before dispatch */
    .header = NULL,
};

static int method_of(const char *m)
{
    static const struct { const char *name; int method; } k[] = {
        { "GET", HTTP_GET }, { "PUT", HTTP_PUT }, { "POST", HTTP_POST }, { "DELETE", HTTP_DELETE },
        { "HEAD", HTTP_HEAD }, { "PATCH", HTTP_PATCH }, { "OPTIONS", HTTP_OPTIONS },
    };
    for (size_t i = 0; i < sizeof k / sizeof k[0]; i++) {
        if (strcmp(m, k[i].name) == 0) return k[i].method;
    }
    return -1;   /* no route has it: 405 on a known path, else 404 (as esp_http_server routes) */
}

static size_t raw(char *rsp, size_t cap, const char *msg)
{
    const size_t n = strlen(msg);
    if (n > cap) return 0;
    memcpy(rsp, msg, n);
    return n;
}

static size_t api_ble_handle(char *req, size_t req_len, char *rsp, size_t rsp_cap)
{
    zf_req_t z;
    if (!zf_parse_request(req, req_len, &z)) {
        ESP_LOGW(TAG, "malformed request line -> 400");
        return raw(rsp, rsp_cap, "400 \n{\"ok\":false,\"error\":\"bad_request\",\"message\":"
                                 "\"payload must be METHOD SP path LF [body]\"}");
    }
    ble_rsp_t w = { .buf = rsp, .cap = rsp_cap };
    api_req_t r = {
        .method = method_of(z.method),
        .method_name = z.method,
        .uri = z.path,
        .content_len = z.body_len,
        .body = z.body,
        .body_len = z.body_len,
        .ops = &s_ble_ops,
        .ctx = &w,
        .transport = "ble",
        .ble = true,
    };
    const char *q = strchr(z.path, '?');
    r.query = q ? q + 1 : NULL;

    bool path_known = false;
    const api_route_t *rt = api_find_route(r.method, z.path, strcspn(z.path, "?"), &path_known);
    if (!rt) {
        (path_known ? api_bad_method : api_not_found)(&r);
    } else if (rt->wifi_only) {
        ESP_LOGW(TAG, "%s %s: WiFi only -> 413 use_wifi", z.method, z.path);
        api_send_error(&r, "413 Payload Too Large", "use_wifi",
                       "WiFi only: open the WiFi hotspot (BLE wake 0x01) and use HTTP");
    } else if (z.body_len > PIXELCLIP_BLE_API_MAX_BYTES) {
        api_send_error(&r, "413 Payload Too Large", "too_large", "fast-lane request bodies are limited to 16 KB");
    } else if (!api_lock(LOCK_TIMEOUT_MS)) {
        api_send_error(&r, "503 Service Unavailable", "busy", "a WiFi transfer is running, retry");
    } else {
        rt->handler(&r);
        api_unlock();
    }
    free(r.body_owned);   /* never set (the body is provided), kept for symmetry with the HTTP adapter */
    if (w.overflow) {
        ESP_LOGW(TAG, "%s %s: response larger than %u B -> 413 use_wifi", z.method, z.path, (unsigned)PIXELCLIP_BLE_API_MAX_BYTES);
        w.len = 0;
        w.overflow = false;
        w.started = false;
        api_send_error(&r, "413 Payload Too Large", "use_wifi", "response larger than 16 KB: use the WiFi hotspot");
    }
    if (!w.started) {
        return raw(rsp, rsp_cap, "500 \n{\"ok\":false,\"error\":\"no_response\",\"message\":\"the handler sent nothing\"}");
    }
    return w.len;
}

void api_ble_init(void)
{
    pixelclip_ble_set_api_handler(api_ble_handle);
}
