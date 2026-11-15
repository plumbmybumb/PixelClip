/* http_api.c — PROTOCOL §4 handlers (plus the /batlog, /queue/test, /imu and /imu/calibrate extensions),
 * the Reader mode endpoints of §5c (/texts, /fonts, /reader) and the Oracle (§5f: POST /oracle/draw, POST /oracle/turn, /status.oracle with the sentence reader's "reading", /show with an oracle
 * body; the Magic 8 Ball of §5e is gone: no route, no status key), written once against the transport-neutral
 * api_req_t (api.h) and served by two adapters: esp_http_server (bottom of this file) and the BLE fast lane
 * (api_ble.c, PROTOCOL §3b). The route table at the bottom is shared by both. */
#include "api.h"
#include "net_priv.h"
#include "net.h"

#include <string.h>
#include <strings.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include "cJSON.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_app_desc.h"
#include "esp_log.h"
#include "sdkconfig.h"
#include "storage.h"
#include "playlist.h"
#include "player.h"
#include "orient.h"
#include "appcfg.h"
#include "timekeeping.h"
#include "power.h"
#include "display.h"
#include "ota.h"
#include "batlog.h"
#include "sched.h"
#include "imu.h"
#include "reader_store.h"
#include "rsvp.h"
#include "pixelclip_ble.h"
#include "health.h"
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "lwip/sockets.h"

static const char *TAG = "http";

/* The build caps cJSON's nesting depth (firmware/json_limit.cmake, applied to ESP-IDF's `json` component in
 * firmware/CMakeLists.txt): without the cap a body of a few hundred '[' overflows this task's stack (security
 * audits WIFI-3 / PARSE-1). ESP-IDF's own default is 1000; fail the build if the definition did not arrive. */
_Static_assert(CJSON_NESTING_LIMIT <= 16, "cJSON must be built with the firmware's nesting cap");

#define PROTOCOL_VERSION 1
#define HW_ID            "ws-amoled-1.91"
#define IO_CHUNK         4096
#define JSON_SMALL_MAX   2048

#define ST_200 "200 OK"
#define ST_201 "201 Created"
#define ST_400 "400 Bad Request"
#define ST_403 "403 Forbidden"
#define ST_404 "404 Not Found"
#define ST_408 "408 Request Timeout"
#define ST_409 "409 Conflict"
#define ST_411 "411 Length Required"
#define ST_413 "413 Payload Too Large"
#define ST_415 "415 Unsupported Media Type"
#define ST_422 "422 Unprocessable Entity"
#define ST_500 "500 Internal Server Error"
#define ST_503 "503 Service Unavailable"

/* Admission check for the bulk uploads (README "Internal RAM"): their own buffers are in PSRAM, but WiFi RX,
 * LittleFS caches and the SHA engine still draw on internal RAM while the body streams in. Below this the
 * request is refused with 503 low_memory (retryable) instead of risking a failed allocation mid-stream. */
#define UPLOAD_MIN_INTERNAL_FREE   12288
#define UPLOAD_MIN_INTERNAL_BLOCK  4096

/* ------------------------------------------------------------------ response helpers */

static esp_err_t send_json(api_req_t *req, const char *status, cJSON *obj)
{
    char *s = cJSON_PrintUnformatted(obj);
    cJSON_Delete(obj);
    if (!s) {
        static const char nomem[] = "{\"ok\":false,\"error\":\"no_memory\"}";
        return req->ops->send(req, status, "application/json", nomem, sizeof nomem - 1);
    }
    esp_err_t err = req->ops->send(req, status, "application/json", s, strlen(s));
    cJSON_free(s);
    return err;
}

static esp_err_t send_ok(api_req_t *req)
{
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    return send_json(req, ST_200, o);
}

static esp_err_t send_error(api_req_t *req, const char *status, const char *code, const char *message)
{
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", false);
    cJSON_AddStringToObject(o, "error", code);
    cJSON_AddStringToObject(o, "message", message ? message : code);
    ESP_LOGW(TAG, "%s %s %s -> %s %s", req->transport, req->method_name, req->uri, status, code);
    return send_json(req, status, o);
}

/* A failed allocation: 503 no_memory (retryable) with the heap state in the log, never a silent failure. */
static esp_err_t send_no_memory(api_req_t *req, const char *what)
{
    ESP_LOGE(TAG, "%s %s: no memory for %s (internal %u B free, largest %u; psram largest %u)", req->method_name, req->uri,
             what, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
    return send_error(req, ST_503, "no_memory", "the clip is short of memory right now: retry in a few seconds");
}

/* Streaming buffers in PSRAM (internal RAM is what a session runs short of); internal only as a fallback. */
static char *io_alloc(size_t n)
{
    char *p = heap_caps_malloc(n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    return p ? p : malloc(n);
}

static bool upload_admitted(api_req_t *req)
{
    const size_t free_b = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    const size_t block = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
    if (free_b >= UPLOAD_MIN_INTERNAL_FREE && block >= UPLOAD_MIN_INTERNAL_BLOCK) return true;
    ESP_LOGE(TAG, "%s %s refused: internal heap %u B free (largest %u), need %d / %d", req->method_name, req->uri,
             (unsigned)free_b, (unsigned)block, UPLOAD_MIN_INTERNAL_FREE, UPLOAD_MIN_INTERNAL_BLOCK);
    send_error(req, ST_503, "low_memory", "the clip is short of memory right now: retry in a few seconds");
    return false;
}

esp_err_t api_send_error(api_req_t *r, const char *status, const char *code, const char *message)
{
    return send_error(r, status, code, message);
}

/* The whole body (<= max bytes), NUL-terminated, owned by the request (the adapter frees it). HTTP reads
 * it from the socket now; the fast lane already has it. On failure an error response has already been
 * sent and *out is NULL. */
static esp_err_t read_body(api_req_t *req, size_t max, const char **out, size_t *len)
{
    *out = NULL;
    if (req->content_len > max) {
        send_error(req, ST_413, "too_large", "request body too large");
        return ESP_FAIL;
    }
    if (!req->body) {
        if (!req->ops->recv) {
            send_error(req, ST_500, "no_body", NULL);
            return ESP_FAIL;
        }
        char *buf = io_alloc(req->content_len + 1);
        if (!buf) {
            send_no_memory(req, "the request body");
            return ESP_FAIL;
        }
        size_t got = 0;
        while (got < req->content_len) {
            int n = req->ops->recv(req, buf + got, req->content_len - got);   /* waits as long as the slow-client guard allows */
            if (n <= 0) {
                free(buf);
                send_error(req, ST_408, "recv_failed", "body not received");
                return ESP_FAIL;
            }
            got += (size_t)n;
        }
        buf[got] = '\0';
        req->body_owned = buf;
        req->body = buf;
        req->body_len = got;
    }
    *out = req->body;
    if (len) *len = req->body_len;
    return ESP_OK;
}

/* PROTOCOL §4 "Request checks": over HTTP a JSON body must be declared as application/json (parameters such as
 * "; charset=utf-8" are fine). A web page can only send text/plain, form or multipart bodies to another origin
 * without a preflight, so this is what keeps a page in the phone's browser from driving the JSON routes while
 * the phone is on the hotspot (security audit WIFI-4). The fast lane has no headers and nothing to check. On
 * failure the 415 has been sent. */
static bool json_type_ok(api_req_t *req)
{
    if (!req->ops->header || req->content_len == 0) return true;
    char v[48];
    if (req->ops->header(req, "Content-Type", v, sizeof v) && strcspn(v, "; \t") == 16 &&
        strncasecmp(v, "application/json", 16) == 0) {
        return true;
    }
    send_error(req, ST_415, "unsupported_media_type", "send JSON bodies with Content-Type: application/json");
    return false;
}

/* Parse a JSON object body; an empty body yields an empty object. */
static cJSON *read_json(api_req_t *req, size_t max)
{
    const char *buf;
    size_t len;
    if (req->content_len == 0) return cJSON_CreateObject();
    if (!json_type_ok(req)) return NULL;
    if (read_body(req, max, &buf, &len) != ESP_OK) return NULL;
    cJSON *j = cJSON_ParseWithLength(buf, len);
    if (!cJSON_IsObject(j)) {
        cJSON_Delete(j);
        send_error(req, ST_400, "bad_json", "body must be a JSON object");
        return NULL;
    }
    return j;
}

/* Copy the path segment after `prefix` (up to '?' or end) into `out`. */
static bool path_tail(api_req_t *req, const char *prefix, char *out, size_t out_len)
{
    size_t pl = strlen(prefix);
    if (strncmp(req->uri, prefix, pl) != 0) return false;
    const char *s = req->uri + pl;
    size_t n = strcspn(s, "?");
    if (n == 0 || n >= out_len) return false;
    memcpy(out, s, n);
    out[n] = '\0';
    return true;
}

static bool header_sha(api_req_t *req, uint8_t sha[32])
{
    char hex[80];
    if (!req->ops->header || !req->ops->header(req, "X-Content-SHA256", hex, sizeof hex)) return false;
    return storage_hex_to_sha(hex, sha);
}

/* Add "ok":true to a stored JSON document and send it. */
static esp_err_t send_stored_json(api_req_t *req, const char *json, size_t len)
{
    cJSON *o = cJSON_ParseWithLength(json, len);
    if (!cJSON_IsObject(o)) {
        cJSON_Delete(o);
        return send_error(req, ST_500, "corrupt", "stored document is not valid JSON");
    }
    cJSON_DeleteItemFromObject(o, "ok");
    cJSON_AddBoolToObject(o, "ok", true);
    return send_json(req, ST_200, o);
}

static cJSON *asset_json(const asset_info_t *a)
{
    char hex[65];
    storage_sha_to_hex(a->sha256, hex);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "id", a->id);
    cJSON_AddNumberToObject(o, "size", a->size);
    cJSON_AddStringToObject(o, "sha256", hex);
    cJSON_AddNumberToObject(o, "width", a->width);
    cJSON_AddNumberToObject(o, "height", a->height);
    cJSON_AddNumberToObject(o, "frames", a->frames);
    cJSON_AddBoolToObject(o, "atlas", a->atlas);
    cJSON_AddBoolToObject(o, "strip", a->strip);   /* PROTOCOL §4: strips report "strip":true and their width */
    return o;
}

/* ------------------------------------------------------------------ handlers */

/* PROTOCOL §5f /status.oracle (also the body of POST /oracle/draw|turn, with "ok"). */
static void oracle_fields(cJSON *o)
{
    player_oracle_status_t *sp = malloc(sizeof *sp);   /* ~1 KB with the text: off the handler's stack */
    if (!sp) {
        cJSON_AddStringToObject(o, "state", "waits");
        return;
    }
    player_get_oracle(sp);
    cJSON_AddNumberToObject(o, "cards", sp->active ? sp->cards : 0);
    cJSON_AddStringToObject(o, "state", sp->active ? sp->state : "waits");
    cJSON *cd = cJSON_AddArrayToObject(o, "cards_drawn");
    for (int i = 0; i < 3; i++) cJSON_AddItemToArray(cd, cJSON_CreateNumber(sp->active ? sp->drawn[i] : -1));
    cJSON_AddNumberToObject(o, "card", sp->active ? sp->card : -1);
    cJSON_AddNumberToObject(o, "page", sp->active ? sp->page : -1);
    cJSON_AddStringToObject(o, "reading", sp->active ? sp->reading : "");   /* §5f.4: the short screen / the paragraph */
    free(sp);
}

static void add_oracle(cJSON *parent, const char *key)
{
    oracle_fields(cJSON_AddObjectToObject(parent, key));
}

static esp_err_t h_status(api_req_t *req)
{
    appcfg_t cfg;
    appcfg_get(&cfg);
    power_battery_t bat;
    power_get_battery(&bat);
    player_status_t ps;
    player_get_status(&ps);
    size_t total, used;
    storage_usage(&total, &used);

    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON *dev = cJSON_AddObjectToObject(o, "device");
    cJSON_AddStringToObject(dev, "name", cfg.name);
    cJSON_AddStringToObject(dev, "id", net_device_id());
    cJSON_AddStringToObject(dev, "fw", esp_app_get_description()->version);
    cJSON_AddStringToObject(dev, "hw", HW_ID);
    cJSON_AddNumberToObject(dev, "protocol", PROTOCOL_VERSION);
    cJSON *b = cJSON_AddObjectToObject(o, "battery");
    cJSON_AddNumberToObject(b, "mv", bat.mv);
    cJSON_AddNumberToObject(b, "pct", bat.pct);
    cJSON_AddBoolToObject(b, "charging", bat.charging);
    cJSON_AddBoolToObject(b, "usb_present", bat.usb_present);
    /* Extension (README "USB light-sleep inhibit"): the USB light-sleep hold and the light-sleep counters since
     * boot; light_sleeps_while_usb and awake_violations must stay 0. */
    cJSON *pw = cJSON_AddObjectToObject(o, "power");
    cJSON_AddBoolToObject(pw, "usb_hold", power_usb_hold());
    cJSON_AddNumberToObject(pw, "light_sleeps", power_light_sleeps());
    cJSON_AddNumberToObject(pw, "light_sleeps_while_usb", power_light_sleeps_while_usb());
    cJSON_AddNumberToObject(pw, "awake_violations", power_awake_violations());
    /* PROTOCOL §4 "Orientation" */
    cJSON *orient = cJSON_AddObjectToObject(o, "orientation");
    cJSON_AddStringToObject(orient, "mode", appcfg_orientation_str(orient_mode()));
    cJSON_AddBoolToObject(orient, "flipped", orient_flipped());
    cJSON *st = cJSON_AddObjectToObject(o, "storage");
    cJSON_AddNumberToObject(st, "total", total);
    cJSON_AddNumberToObject(st, "used", used);
    cJSON_AddNumberToObject(st, "free", total > used ? total - used : 0);
    cJSON *pl = cJSON_AddObjectToObject(o, "playlist");
    cJSON_AddNumberToObject(pl, "count", ps.count);
    cJSON_AddNumberToObject(pl, "index", ps.index);
    if (ps.current[0]) {
        cJSON_AddStringToObject(pl, "current", ps.current);
    } else {
        cJSON_AddNullToObject(pl, "current");
    }
    cJSON *t = cJSON_AddObjectToObject(o, "time");
    cJSON_AddNumberToObject(t, "epoch", (double)timekeeping_now());
    cJSON_AddNumberToObject(t, "tz_offset_s", timekeeping_tz());
    cJSON_AddBoolToObject(t, "synced", timekeeping_synced());
    /* Extension: a clock rebuilt from the NVS anchor (or a sync > 24 h old) is "approximate": it never
     * drives the queue / windows. anchor_age_s = how long it has run from that anchor. */
    cJSON_AddBoolToObject(t, "approximate", timekeeping_approximate());
    const int64_t anchor_age = timekeeping_anchor_age_s();
    if (anchor_age >= 0) {
        cJSON_AddNumberToObject(t, "anchor_age_s", (double)anchor_age);
    } else {
        cJSON_AddNullToObject(t, "anchor_age_s");
    }
    sched_status_t q;
    sched_get_status(&q);
    cJSON *qo = cJSON_AddObjectToObject(o, "queue");
    cJSON_AddNumberToObject(qo, "pending", q.pending);
    if (q.next_at) {
        cJSON_AddNumberToObject(qo, "next_at", (double)q.next_at);
    } else {
        cJSON_AddNullToObject(qo, "next_at");
    }
    cJSON_AddNumberToObject(qo, "done", q.done);
    if (q.active[0]) {
        cJSON_AddStringToObject(qo, "active", q.active);
    } else {
        cJSON_AddNullToObject(qo, "active");
    }
    cJSON_AddBoolToObject(o, "clock_ok", timekeeping_synced());
    cJSON *se = cJSON_AddObjectToObject(o, "session");
    cJSON_AddNumberToObject(se, "idle_s", net_session_idle_s());
    cJSON_AddNumberToObject(se, "timeout_s", net_session_timeout_s());
    cJSON_AddBoolToObject(se, "always_on", net_always_on());          /* no idle timeout, /session/end ignored */
    cJSON_AddBoolToObject(se, "display_on", net_session_display_on()); /* the panel keeps playing */
    cJSON_AddNumberToObject(se, "clients", net_session_clients());
    /* PROTOCOL §5f.6: "oracle":{"cards","state","cards_drawn","card","page","reading"} (always present: cards 0, "waits",
     * -1s, "" when no oracle item is current) */
    add_oracle(o, "oracle");
    /* Extension: reset counters since the NVS was created (README "Light sleep on battery"): wdt = every
     * watchdog reset (rtc_wdt = by the RTC watchdog, the light-sleep safety net), last = this boot's reason. */
    health_resets_t hr;
    health_get_resets(&hr);
    cJSON *rs = cJSON_AddObjectToObject(o, "resets");
    cJSON_AddNumberToObject(rs, "wdt", hr.wdt);
    cJSON_AddNumberToObject(rs, "brownout", hr.brownout);
    cJSON_AddNumberToObject(rs, "panic", hr.panic);
    cJSON_AddNumberToObject(rs, "rtc_wdt", hr.rtc_wdt);
    cJSON_AddStringToObject(rs, "last", hr.last);
    cJSON_AddBoolToObject(rs, "coredump", health_coredump_size() > 0);   /* GET /coredump has one */
    cJSON_AddNumberToObject(o, "uptime_s", (double)(esp_timer_get_time() / 1000000));
    return send_json(req, ST_200, o);
}

static esp_err_t h_assets_list(api_req_t *req)
{
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON *arr = cJSON_AddArrayToObject(o, "assets");
    asset_info_t a;
    for (size_t i = 0; storage_asset_at(i, &a); i++) cJSON_AddItemToArray(arr, asset_json(&a));
    return send_json(req, ST_200, o);
}

static esp_err_t h_asset_put(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1];
    uint8_t sha[32];
    if (!path_tail(req, "/assets/", id, sizeof id) || !storage_id_valid(id)) {
        return send_error(req, ST_400, "invalid_id", "asset id must match [a-z0-9][a-z0-9-]{0,31}");
    }
    if (!header_sha(req, sha)) {
        return send_error(req, ST_400, "missing_sha256", "X-Content-SHA256 header (64 hex chars) required");
    }
    if (req->content_len == 0) return send_error(req, ST_411, "empty_body", "Content-Length required");
    if (!upload_admitted(req)) return ESP_OK;

    asset_info_t existing;
    if (storage_asset_find(id, &existing) && memcmp(existing.sha256, sha, 32) == 0 &&
        existing.size == req->content_len) {
        cJSON *o = asset_json(&existing);
        cJSON_AddBoolToObject(o, "ok", false);
        cJSON_AddStringToObject(o, "error", "exists");
        cJSON_AddStringToObject(o, "message", "identical asset already stored");
        return send_json(req, ST_409, o); /* remaining body is discarded by the server */
    }

    storage_writer_t *w = NULL;
    storage_status_t st = storage_asset_write_begin(id, req->content_len, &w);
    if (st == STORAGE_ERR_NO_SPACE || st == STORAGE_ERR_TOO_MANY) {
        return send_error(req, ST_413, storage_status_str(st), "not enough space on the clip");
    }
    if (st != STORAGE_OK) return send_error(req, st == STORAGE_ERR_ARG ? ST_422 : ST_500, storage_status_str(st), NULL);

    char *buf = io_alloc(IO_CHUNK);
    if (!buf) {
        storage_asset_write_abort(w);
        return send_no_memory(req, "the upload buffer");
    }
    size_t left = req->content_len;
    player_upload_active(true);   /* scenes at 15 fps while the body streams into flash */
    while (left > 0 && st == STORAGE_OK) {
        int n = req->ops->recv(req, buf, left < IO_CHUNK ? left : IO_CHUNK);
        if (n <= 0) {   /* closed, stalled or too slow (slow-client guard), or the session is ending */
            player_upload_active(false);
            free(buf);
            storage_asset_write_abort(w);
            ESP_LOGW(TAG, "upload %s: abandoned with %u bytes left", id, (unsigned)left);
            return ESP_FAIL; /* httpd closes the socket */
        }
        st = storage_asset_write(w, buf, (size_t)n);
        left -= (size_t)n;
        if ((left & 0xFFFF) < IO_CHUNK) net_touch(); /* long uploads must not trip the idle timer */
    }
    player_upload_active(false);
    free(buf);
    if (st != STORAGE_OK) {
        storage_asset_write_abort(w);
        return send_error(req, st == STORAGE_ERR_NO_SPACE ? ST_413 : ST_500, storage_status_str(st), NULL);
    }
    asset_info_t info;
    /* Screen-on session: the asset may be the animation on screen (open file = no rename). */
    const bool held = player_release_files(id, NULL);
    st = storage_asset_write_finish(w, sha, &info);
    if (st != STORAGE_OK) {
        if (held) player_reload_for(PLAYER_RELOAD_ASSET, id, false);   /* unfreeze: the old file is back */
        const char *msg = st == STORAGE_ERR_HASH ? "body does not match X-Content-SHA256"
                        : st == STORAGE_ERR_MALFORMED ? "not a valid .hca for this display (536x240, a glyph atlas, or a 1-frame strip 537..8192 x 240)" : NULL;
        const char *status = (st == STORAGE_ERR_HASH || st == STORAGE_ERR_MALFORMED) ? ST_422
                           : st == STORAGE_ERR_NO_SPACE || st == STORAGE_ERR_TOO_MANY ? ST_413 : ST_500;
        return send_error(req, status, storage_status_str(st), msg);
    }
    player_reload_for(PLAYER_RELOAD_ASSET, info.id, false);   /* restarts only an item that shows this asset */
    net_note_upload(info.id);   /* counted + "net: heap after upload <id>: ..." */
    cJSON *o = cJSON_CreateObject();
    char hex[65];
    storage_sha_to_hex(info.sha256, hex);
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON_AddStringToObject(o, "id", info.id);
    cJSON_AddNumberToObject(o, "size", info.size);
    cJSON_AddStringToObject(o, "sha256", hex);
    return send_json(req, ST_201, o);
}

static esp_err_t h_asset_delete(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1];
    if (!path_tail(req, "/assets/", id, sizeof id) || !storage_id_valid(id)) {
        return send_error(req, ST_400, "invalid_id", NULL);
    }
    const bool held = player_release_files(id, NULL);   /* screen-on session: may be on screen */
    if (storage_asset_delete(id) != STORAGE_OK) {
        if (held) player_reload_for(PLAYER_RELOAD_ASSET, id, false);
        return send_error(req, ST_404, "not_found", "no such asset");
    }
    if (playlist_remove_asset(id) != ESP_OK) ESP_LOGE(TAG, "playlist update after delete failed");
    player_reload_for(PLAYER_RELOAD_ASSET, id, true);
    return send_ok(req);
}

static esp_err_t h_asset_get(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1], path[96];
    if (!path_tail(req, "/assets/", id, sizeof id) || !storage_asset_find(id, NULL)) {
        return send_error(req, ST_404, "not_found", "no such asset");
    }
    storage_asset_path(id, path, sizeof path);
    int fd = open(path, O_RDONLY);
    char *buf = io_alloc(IO_CHUNK);
    if (fd < 0 || !buf) {
        if (fd >= 0) close(fd);
        free(buf);
        return send_error(req, ST_500, "io_error", NULL);
    }
    static const char type[] = "application/octet-stream";
    esp_err_t err = ESP_OK;
    ssize_t n;
    while (err == ESP_OK && (n = read(fd, buf, IO_CHUNK)) > 0) err = req->ops->send_chunk(req, type, buf, (size_t)n);
    close(fd);
    free(buf);
    if (err == ESP_OK) err = req->ops->send_chunk(req, type, NULL, 0);
    return err;
}

static esp_err_t h_playlist_get(api_req_t *req)
{
    char *json = playlist_read_json();
    if (!json) return send_no_memory(req, "the playlist");
    esp_err_t err = send_stored_json(req, json, strlen(json));
    free(json);
    return err;
}

static esp_err_t h_playlist_put(api_req_t *req)
{
    const char *buf;
    size_t len;
    if (!json_type_ok(req)) return ESP_OK;
    if (read_body(req, PLAYLIST_MAX_BYTES, &buf, &len) != ESP_OK) return ESP_OK;
    char msg[128] = "";
    pl_status_t st = playlist_parse(buf, len, NULL, msg, sizeof msg);
    esp_err_t err;
    if (st == PL_ERR_JSON) {
        err = send_error(req, ST_400, "bad_json", msg);
    } else if (st == PL_ERR_UNKNOWN_ASSET) {
        err = send_error(req, ST_422, "unknown_asset", msg);
    } else if (st == PL_ERR_UNKNOWN_SCENE) {
        err = send_error(req, ST_422, "unknown_scene", msg);
    } else if (st == PL_ERR_INVALID_PARAMS) {
        err = send_error(req, ST_422, "invalid_params", msg);
    } else if (st == PL_ERR_UNKNOWN_TEXT) {
        err = send_error(req, ST_422, "unknown_text", msg);
    } else if (st == PL_ERR_UNKNOWN_FONT) {
        err = send_error(req, ST_422, "unknown_font", msg);
    } else if (st != PL_OK) {
        err = send_error(req, ST_422, "invalid_playlist", msg);
    } else if (playlist_store(buf, len) != ESP_OK) {
        err = send_error(req, ST_500, "io_error", "could not store playlist");
    } else {
        player_reload_playlist();   /* also applies reader from_word */
        err = send_ok(req);
    }
    return err;
}

static esp_err_t h_config_get(api_req_t *req)
{
    cJSON *o = appcfg_to_json();
    cJSON_AddBoolToObject(o, "ok", true);
    return send_json(req, ST_200, o);
}

static esp_err_t h_config_put(api_req_t *req)
{
    cJSON *patch = read_json(req, JSON_SMALL_MAX);
    if (!patch) return ESP_OK;
    /* The hotspot passphrase is the key to everything WiFi offers (uploads, firmware updates). The fast lane has
     * no pairing, so anyone in Bluetooth range could set it and lock the owner out: over BLE the key is refused
     * with the fast lane's usual "do this over WiFi" answer (security audits WIFI-1 / BLE-2). The lookup is
     * case-insensitive on purpose (broader than the case-sensitive merge). Nothing of the patch is applied. */
    if (req->ble && cJSON_HasObjectItem(patch, "ap_password")) {
        cJSON_Delete(patch);
        return send_error(req, ST_413, "use_wifi", "ap_password can only be set over the WiFi hotspot");
    }
    char msg[128] = "";
    esp_err_t err = appcfg_merge_json(patch, msg, sizeof msg);
    bool brightness_changed = cJSON_HasObjectItem(patch, "brightness");
    bool tz_changed = cJSON_HasObjectItem(patch, "tz_offset_s");
    bool always_changed = cJSON_HasObjectItem(patch, "wifi_always_on");
    bool ble_changed = cJSON_HasObjectItem(patch, "ble_wake");
    bool orient_changed = cJSON_HasObjectItem(patch, "orientation");
    cJSON_Delete(patch);
    if (err == ESP_ERR_INVALID_ARG) return send_error(req, ST_422, "invalid_config", msg);
    if (err != ESP_OK) return send_error(req, ST_500, "io_error", msg);
    appcfg_t cfg;
    appcfg_get(&cfg);
    if (brightness_changed) player_set_brightness(cfg.brightness);
    if (tz_changed) player_time_changed();
    power_set_low_battery_pct(cfg.low_battery_pct);
    net_set_timeout_s(cfg.upload_timeout_s);
    if (always_changed) net_always_on_config(cfg.wifi_always_on);   /* applies to this session at once */
    if (orient_changed) orient_set_mode(cfg.orientation);             /* at once (also over the fast lane) */
    if (ble_changed) {
        esp_err_t be = pixelclip_ble_set_enabled(cfg.ble_wake);
        if (be != ESP_OK) ESP_LOGE(TAG, "ble_wake -> %d: %s", cfg.ble_wake, esp_err_to_name(be));
        if (!cfg.ble_wake) net_wifi_release_if_idle();   /* the WiFi driver is only kept for BLE's sake */
    }
    /* display_during_upload takes effect at the next session. */
    cJSON *o = appcfg_to_json();
    cJSON_AddBoolToObject(o, "ok", true);
    return send_json(req, ST_200, o);
}

static esp_err_t h_time(api_req_t *req)
{
    cJSON *j = read_json(req, JSON_SMALL_MAX);
    if (!j) return ESP_OK;
    const cJSON *epoch = cJSON_GetObjectItemCaseSensitive(j, "epoch");
    const cJSON *tz = cJSON_GetObjectItemCaseSensitive(j, "tz_offset_s");
    esp_err_t err;
    if (!cJSON_IsNumber(epoch) || epoch->valuedouble < 1600000000.0 || epoch->valuedouble > 4102444800.0) {
        err = send_error(req, ST_422, "invalid_time", "epoch must be unix seconds");
    } else if (tz && (!cJSON_IsNumber(tz) || tz->valuedouble < -50400 || tz->valuedouble > 50400)) {
        err = send_error(req, ST_422, "invalid_time", "tz_offset_s must be within +/-50400");
    } else if (timekeeping_set((int64_t)epoch->valuedouble, tz ? (int32_t)tz->valuedouble : timekeeping_tz()) != ESP_OK) {
        err = send_error(req, ST_500, "time_failed", NULL);
    } else {
        player_time_changed();
        err = send_ok(req);
    }
    cJSON_Delete(j);
    return err;
}

static esp_err_t h_show(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1];
    if (!path_tail(req, "/show/", id, sizeof id)) return send_error(req, ST_400, "invalid_id", NULL);
    cJSON *j = read_json(req, JSON_SMALL_MAX);
    if (!j) return ESP_OK;
    const cJSON *type = cJSON_GetObjectItemCaseSensitive(j, "type");
    if (type) {
        /* PROTOCOL §5f: an item body ({"type":"oracle","deck":...}),
         * validated like a playlist item; the path names the asset (an oracle's text asset). */
        pl_item_t *it = (pl_item_t *)io_alloc(sizeof *it);
        if (!it) {
            cJSON_Delete(j);
            return send_no_memory(req, "the item");
        }
        char msg[160] = "";
        const pl_status_t st = playlist_parse_show_item(j, id, it, msg, sizeof msg);
        cJSON_Delete(j);
        esp_err_t err;
        if (st == PL_OK) {
            player_show_item(it);
            err = send_ok(req);
        } else if (st == PL_ERR_UNKNOWN_ASSET) {
            err = send_error(req, ST_404, "unknown_asset", msg);
        } else if (st == PL_ERR_JSON) {
            err = send_no_memory(req, "the item");
        } else {
            err = send_error(req, ST_422, "invalid_item", msg);
        }
        free(it);
        return err;
    }
    const cJSON *d = cJSON_GetObjectItemCaseSensitive(j, "duration_ms");
    uint32_t dur = 0;
    bool bad = d && (!cJSON_IsNumber(d) || d->valuedouble < 0 || d->valuedouble > 86400000.0);
    if (cJSON_IsNumber(d) && !bad) dur = (uint32_t)d->valuedouble;
    /* Optional "scroll" (same fields and validation as a playlist item's); without it a strip takes
     * the scroll of the playlist item showing it, else the default scroll (player_show_asset_scroll). */
    pl_scroll_t scroll = { 0 };
    char msg[96] = "";
    const pl_status_t sst = bad ? PL_OK : playlist_parse_scroll(cJSON_GetObjectItemCaseSensitive(j, "scroll"), &scroll, msg, sizeof msg);
    cJSON_Delete(j);
    if (bad) return send_error(req, ST_422, "invalid_duration", "duration_ms must be 0..86400000");
    if (sst != PL_OK) return send_error(req, ST_422, "invalid_scroll", msg);
    asset_info_t a;
    const bool found = storage_asset_find(id, &a);
    if (!found || a.atlas) {
        /* §5f.2: an oracle is named by its bundle (a text); §5b.1: a words sheet (an atlas, usually) by itself: shown
         * as the playlist (then queue) item using it */
        const bool oracle = reader_text_exists(id) && playlist_oracle_uses(id);
        const bool words = found && playlist_words_uses(id);
        if (!oracle && !words) return send_error(req, ST_404, "unknown_asset", "no such playable asset");
    }
    player_show_asset_scroll(id, dur, scroll.on ? &scroll : NULL);
    return send_ok(req);
}

/* PROTOCOL §5f.6: POST /oracle/draw {"cards":[a,b,c]}? (body optional) — a draw of the oracle on screen; "cards" forces
 * the row (three distinct integers 0..cards-1), else random. Other keys (the old "card", "question") are ignored. */
static esp_err_t h_oracle_draw(api_req_t *req)
{
    cJSON *j = read_json(req, JSON_SMALL_MAX);
    if (!j) return ESP_OK;
    const cJSON *k = cJSON_GetObjectItemCaseSensitive(j, "cards");
    const bool given = k && !cJSON_IsNull(k);
    int row[3] = { -1, -1, -1 };
    bool ok = !given;
    if (given && cJSON_IsArray(k) && cJSON_GetArraySize(k) == 3) {
        ok = true;
        for (int i = 0; i < 3; i++) {
            const cJSON *e = cJSON_GetArrayItem(k, i);
            if (!cJSON_IsNumber(e) || e->valuedouble < 0 || e->valuedouble >= 78 || e->valuedouble != floor(e->valuedouble)) {
                ok = false;
            } else {
                row[i] = (int)e->valuedouble;
            }
        }
        ok = ok && row[0] != row[1] && row[0] != row[2] && row[1] != row[2];
    }
    cJSON_Delete(j);
    if (!ok) return send_error(req, ST_422, "invalid_cards", "cards must be three distinct integers 0..cards-1");
    const esp_err_t r = player_oracle_draw(given ? row : NULL);
    if (r == ESP_ERR_INVALID_STATE) return send_error(req, ST_409, "not_showing", "no oracle item is on screen");
    if (r == ESP_ERR_INVALID_ARG) return send_error(req, ST_422, "invalid_cards", "cards must be three distinct integers 0..cards-1");
    if (r != ESP_OK) return send_error(req, ST_500, "busy", "the player did not answer");
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    oracle_fields(o);
    return send_json(req, ST_200, o);
}

/* PROTOCOL §5f.3 (extension): POST /oracle/back — the previous screen, like a double tap of BOOT. */
static esp_err_t h_oracle_back(api_req_t *req)
{
    cJSON *j = read_json(req, JSON_SMALL_MAX);   /* any (ignored) body is drained */
    if (!j) return ESP_OK;
    cJSON_Delete(j);
    const esp_err_t r = player_oracle_back_sync();
    if (r == ESP_ERR_INVALID_STATE) return send_error(req, ST_409, "not_showing", "no oracle item is on screen");
    if (r != ESP_OK) return send_error(req, ST_500, "busy", "the player did not answer");
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    oracle_fields(o);
    return send_json(req, ST_200, o);
}

/* PROTOCOL §5f: POST /oracle/turn — advances the oracle on screen like a press of BOOT. */
static esp_err_t h_oracle_turn(api_req_t *req)
{
    cJSON *j = read_json(req, JSON_SMALL_MAX);   /* any (ignored) body is drained */
    if (!j) return ESP_OK;
    cJSON_Delete(j);
    const esp_err_t r = player_oracle_turn();
    if (r == ESP_ERR_INVALID_STATE) return send_error(req, ST_409, "not_showing", "no oracle item is on screen");
    if (r != ESP_OK) return send_error(req, ST_500, "busy", "the player did not answer");
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    oracle_fields(o);
    return send_json(req, ST_200, o);
}

/* Non-normative development aid: play a queue entry now (not marked done, clock ignored). */
static esp_err_t h_queue_test(api_req_t *req)
{
    cJSON *j = read_json(req, JSON_SMALL_MAX);
    if (!j) return ESP_OK;
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(j, "id");
    esp_err_t err;
    if (!cJSON_IsString(id) || !sched_id_valid(id->valuestring)) {
        err = send_error(req, ST_400, "bad_json", "body must be {\"id\":\"<queue entry id>\"}");
    } else if (sched_find(id->valuestring) < 0) {
        err = send_error(req, ST_404, "unknown_entry", "no queue entry with this id in the playlist");
    } else {
        player_queue_test(id->valuestring);
        err = send_ok(req);
    }
    cJSON_Delete(j);
    return err;
}

static esp_err_t h_next(api_req_t *req) { player_next(); return send_ok(req); }
static esp_err_t h_prev(api_req_t *req) { player_prev(); return send_ok(req); }

static esp_err_t h_brightness(api_req_t *req)
{
    cJSON *j = read_json(req, JSON_SMALL_MAX);
    if (!j) return ESP_OK;
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(j, "value");
    bool ok = cJSON_IsNumber(v) && v->valuedouble >= 0 && v->valuedouble <= 255;
    uint8_t level = ok ? (uint8_t)v->valueint : 0;
    cJSON_Delete(j);
    if (!ok) return send_error(req, ST_422, "invalid_brightness", "value must be 0-255");
    player_set_brightness(level);
    return send_ok(req);
}

static esp_err_t h_screenshot(api_req_t *req)
{
    /* Snapshot under the lock, send without it: a 257 KB send over a weak link can take seconds
     * (up to send_wait_timeout per chunk) and must not stall the player meanwhile. */
    uint8_t *snap = heap_caps_malloc(DISPLAY_FB_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    esp_err_t err;
    if (snap) {
        display_lock();
        memcpy(snap, display_fb(), DISPLAY_FB_BYTES);
        display_unlock();
        err = req->ops->send(req, ST_200, "application/octet-stream", (const char *)snap, DISPLAY_FB_BYTES);
        free(snap);
    } else {
        display_lock();
        err = req->ops->send(req, ST_200, "application/octet-stream", (const char *)display_fb(), DISPLAY_FB_BYTES);
        display_unlock();
    }
    return err;
}

/* The update permission (PROTOCOL §4 "Firmware update", security audit WIFI-2): an image is only taken after
 * someone pressed the clip's button while it asked. Knowing the hotspot passphrase is not enough. */
static esp_err_t send_ota_state(api_req_t *req, const ota_permission_t *p)
{
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON_AddBoolToObject(o, "allowed", p->allowed);
    cJSON_AddBoolToObject(o, "asking", p->asking);
    cJSON_AddNumberToObject(o, "seconds_left", p->seconds_left);
    return send_json(req, ST_200, o);
}

static esp_err_t h_ota_get(api_req_t *req)
{
    ota_permission_t p;
    ota_permission_get(&p);
    return send_ota_state(req, &p);
}

/* WiFi only (route table): the prompt is for someone who has joined the hotspot, not for anyone in BLE range. */
static esp_err_t h_ota_ask(api_req_t *req)
{
    ota_permission_t p;
    ota_permission_ask(&p);
    return send_ota_state(req, &p);
}

static esp_err_t h_ota(api_req_t *req)
{
    uint8_t sha[32];
    if (!header_sha(req, sha)) return send_error(req, ST_400, "missing_sha256", "X-Content-SHA256 required");
    if (req->content_len == 0) return send_error(req, ST_411, "empty_body", NULL);
    /* Decided before any body byte is read. The refusal also asks, so a plain retry after the press works. */
    ota_permission_t perm;
    ota_permission_get(&perm);
    if (!perm.allowed) {
        ota_permission_ask(NULL);
        return send_error(req, ST_403, "press_button",
                          "press the button on the clip (it shows \"Update?\"), then send the update again");
    }
    if (!upload_admitted(req)) return ESP_OK;
    ota_session_t *s = NULL;
    esp_err_t err = ota_begin(req->content_len, &s);
    if (err == ESP_ERR_INVALID_SIZE) return send_error(req, ST_413, "too_large", "image larger than the OTA slot");
    if (err != ESP_OK) return send_error(req, ST_500, "ota_failed", esp_err_to_name(err));
    char *buf = io_alloc(IO_CHUNK);
    if (!buf) {
        ota_abort(s);
        return send_no_memory(req, "the upload buffer");
    }
    size_t left = req->content_len;
    while (left > 0) {
        int n = req->ops->recv(req, buf, left < IO_CHUNK ? left : IO_CHUNK);
        if (n <= 0) {   /* closed, stalled or too slow (slow-client guard), or the session is ending */
            free(buf);
            ota_abort(s);
            ESP_LOGW(TAG, "OTA: abandoned with %u bytes left", (unsigned)left);
            return ESP_FAIL;
        }
        err = ota_write(s, buf, (size_t)n);
        if (err != ESP_OK) {
            free(buf);
            ota_abort(s);
            return send_error(req, ST_500, "ota_write_failed", esp_err_to_name(err));
        }
        left -= (size_t)n;
        net_touch();
    }
    free(buf);
    err = ota_finish(s, sha);
    if (err == ESP_ERR_INVALID_CRC) return send_error(req, ST_422, "sha256_mismatch", "body does not match X-Content-SHA256");
    if (err != ESP_OK) return send_error(req, ST_422, "invalid_image", esp_err_to_name(err));
    ota_permission_clear();   /* one press, one image (a failed upload above keeps the permission until it runs out) */
    err = send_ok(req);
    ota_restart_in(1000);
    return err;
}

static esp_err_t h_session_end(api_req_t *req)
{
    if (net_always_on()) {
        /* wifi_always_on: the hotspot stays up (only a long press / BLE 0x02 / PUT /config ends that). */
        cJSON *o = cJSON_CreateObject();
        cJSON_AddBoolToObject(o, "ok", true);
        cJSON_AddBoolToObject(o, "always_on", true);
        cJSON_AddStringToObject(o, "message", "wifi_always_on: the hotspot stays up");
        return send_json(req, ST_200, o);
    }
    esp_err_t err = send_ok(req);
    net_request_end_soon();
    return err;
}

/* GET /ble (extension): the BLE doorbell. */
static esp_err_t h_ble(api_req_t *req)
{
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON_AddBoolToObject(o, "enabled", pixelclip_ble_enabled());
    cJSON_AddStringToObject(o, "name", pixelclip_ble_name());
    cJSON_AddStringToObject(o, "service_uuid", PIXELCLIP_BLE_SERVICE_UUID);
    cJSON_AddBoolToObject(o, "connected", pixelclip_ble_connected());
    return send_json(req, ST_200, o);
}

/* GET /scenes: generated from the core registry (PROTOCOL §4). */
static esp_err_t h_scenes(api_req_t *req)
{
#if PL_SCENES
    const size_t cap = 6144;
    char *buf = io_alloc(cap);
    if (!buf) return send_no_memory(req, "the response");
    size_t n = scene_describe_json(buf, cap);
    esp_err_t err;
    if (n == 0) {
        err = send_error(req, ST_500, "too_large", "scene registry description does not fit");
    } else {
        err = req->ops->send(req, ST_200, "application/json", buf, n);
    }
    free(buf);
    return err;
#else
    return send_error(req, ST_404, "not_found", "live scenes are not supported by this firmware");
#endif
}

static void add_vec(cJSON *o, const char *key, const float v[3])
{
    cJSON *a = cJSON_AddArrayToObject(o, key);
    for (int i = 0; i < 3; i++) cJSON_AddItemToArray(a, cJSON_CreateNumber(round((double)v[i] * 1000.0) / 1000.0));
}

static void add_map(cJSON *o, const int8_t m[3][3])
{
    cJSON *a = cJSON_AddArrayToObject(o, "axis_map");
    for (int i = 0; i < 3; i++) {
        int row[3] = { m[i][0], m[i][1], m[i][2] };
        cJSON_AddItemToArray(a, cJSON_CreateIntArray(row, 3));
    }
}

/* Bench endpoint (non-normative): accelerometer state in the display frame. Starts 30 s of 50 Hz
 * sampling if it was idle and waits for fresh samples. */
static esp_err_t h_imu(api_req_t *req)
{
    const bool present = imu_present();
    if (present) {
        const uint32_t n0 = imu_sample_count();
        imu_keepalive(30000);
        for (int i = 0; i < 25 && imu_sample_count() < n0 + 3; i++) vTaskDelay(pdMS_TO_TICKS(20));
    }
    float g[3], lp[3], raw[3];
    imu_get_gravity(&g[0], &g[1], &g[2]);
    imu_get_gravity_lp(lp);
    imu_get_raw(raw);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON_AddBoolToObject(o, "present", present);
    add_vec(o, "g", g);
    cJSON_AddNumberToObject(o, "shake", round((double)imu_get_shake() * 1000.0) / 1000.0);
    cJSON_AddNumberToObject(o, "samples", imu_sample_count());
    add_vec(o, "g_lp", lp);
    add_vec(o, "raw", raw);
    cJSON_AddBoolToObject(o, "flipped", orient_flipped());   /* g / g_lp stay in the unrotated display frame */
    int8_t m[3][3];
    const bool calibrated = imu_get_axis_map(m);
    cJSON_AddBoolToObject(o, "calibrated", calibrated);   /* a POST /imu/calibrate map is stored (NVS) */
    add_map(o, m);
    if (present) {
        char addr[8];
        snprintf(addr, sizeof addr, "0x%02X", imu_address());
        cJSON_AddStringToObject(o, "addr", addr);
    }
    return send_json(req, ST_200, o);
}

/* Bench calibration (non-normative): POST /imu/calibrate {"step":"upright"|"faceup"|"reset"}.
 * Each pose step averages a still reading (~0.5 s); once both poses are captured (any order) the axis
 * map is derived with scene_axis_map_calibrate(), applied and stored in NVS. "reset" erases it (back to
 * the compiled map + Kconfig flips). Captures live in RAM until they are used or the clip reboots. */
static esp_err_t h_imu_calibrate(api_req_t *req)
{
    static float s_up[3], s_face[3];
    static bool s_have_up, s_have_face;
    cJSON *j = read_json(req, JSON_SMALL_MAX);
    if (!j) return ESP_OK;
    const cJSON *stp = cJSON_GetObjectItemCaseSensitive(j, "step");
    char step[12] = "";
    if (cJSON_IsString(stp)) strlcpy(step, stp->valuestring, sizeof step);
    cJSON_Delete(j);
    const bool up = strcmp(step, "upright") == 0, face = strcmp(step, "faceup") == 0;
    if (!cJSON_IsString(stp)) return send_error(req, ST_400, "bad_json", "body must be {\"step\":\"upright\"|\"faceup\"|\"reset\"}");
    if (strcmp(step, "reset") == 0) {
        s_have_up = s_have_face = false;
        if (imu_clear_axis_map() != ESP_OK) return send_error(req, ST_500, "nvs_failed", "could not erase the stored map");
        cJSON *o = cJSON_CreateObject();
        cJSON_AddBoolToObject(o, "ok", true);
        cJSON_AddStringToObject(o, "step", step);
        cJSON_AddBoolToObject(o, "calibrated", false);
        int8_t m[3][3];
        imu_get_axis_map(m);
        add_map(o, m);
        return send_json(req, ST_200, o);
    }
    if (!up && !face) return send_error(req, ST_422, "invalid_step", "step must be \"upright\", \"faceup\" or \"reset\"");
#if PL_SCENES
    float r[3], spread = 0.0f;
    esp_err_t err = imu_capture_still(r, 500, &spread);
    if (err == ESP_ERR_NOT_FOUND) return send_error(req, "409 Conflict", "no_imu", "no accelerometer detected");
    if (err == ESP_ERR_INVALID_STATE) return send_error(req, ST_422, "not_still", "the clip moved during the reading: hold it still and retry");
    if (err != ESP_OK) return send_error(req, ST_500, "imu_timeout", "no accelerometer samples");
    const float mag = sqrtf(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]);
    int dominant = 0;
    for (int i = 0; i < 3; i++) dominant += fabsf(r[i]) > 0.7f;
    if (mag < 0.8f || mag > 1.2f || dominant != 1) {
        return send_error(req, ST_422, "ambiguous_pose", "reading is not ~1 g along one chip axis: square the clip up and retry");
    }
    memcpy(up ? s_up : s_face, r, sizeof r);
    if (up) s_have_up = true; else s_have_face = true;
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON_AddStringToObject(o, "step", step);
    add_vec(o, "raw", r);
    if (!(s_have_up && s_have_face)) {
        int8_t m[3][3];
        cJSON_AddStringToObject(o, "next", s_have_up ? "faceup" : "upright");
        cJSON_AddBoolToObject(o, "calibrated", imu_get_axis_map(m));
        return send_json(req, ST_200, o);
    }
    s_have_up = s_have_face = false;   /* a pair is used once, whatever the outcome */
    scene_axis_map_t map;
    if (!scene_axis_map_calibrate(s_up, s_face, &map)) {
        cJSON_Delete(o);
        return send_error(req, ST_422, "calibration_failed",
                          "upright and face-up readings are on the same chip axis: redo both steps");
    }
    err = imu_set_axis_map((const int8_t (*)[3])map.m);
    if (err == ESP_ERR_INVALID_ARG) {
        cJSON_Delete(o);
        return send_error(req, ST_422, "calibration_failed", "derived map is not a signed permutation");
    }
    if (err != ESP_OK) {
        cJSON_Delete(o);
        return send_error(req, ST_500, "nvs_failed", "map applied but not stored");
    }
    cJSON_AddBoolToObject(o, "calibrated", true);
    add_map(o, (const int8_t (*)[3])map.m);
    float g[3];
    imu_get_gravity(&g[0], &g[1], &g[2]);
    add_vec(o, "g", g);   /* sampled with the old map until the next sample; informational */
    return send_json(req, ST_200, o);
#else
    return send_error(req, ST_404, "not_found", "calibration needs the scene engine (core/src/scene.c)");
#endif
}

static esp_err_t batlog_sink(void *ctx, const char *data, size_t len)
{
    api_req_t *req = ctx;
    return req->ops->send_chunk(req, "text/csv", data, len);
}

static esp_err_t h_batlog_get(api_req_t *req)
{
    esp_err_t err = batlog_read(batlog_sink, req);
    if (err == ESP_OK) err = req->ops->send_chunk(req, "text/csv", NULL, 0);
    return err;
}

static esp_err_t h_batlog_delete(api_req_t *req)
{
    batlog_clear();
    return send_ok(req);
}

/* ------------------------------------------------------------------ core dump (README "Crash diagnostics") */

/* GET /coredump: the raw image of the last panic (flash image: header + ELF + SHA-256), for
 * `idf.py coredump-info -c core.bin` / `python -m esp_coredump info_corefile -t raw -c core.bin build/pixelclip.elf`.
 * Read from flash in IO_CHUNK pieces into one PSRAM buffer (<= the 56 KB partition) and sent with a
 * Content-Length; streamed chunked from a small buffer if PSRAM is short. WiFi only (bulk). */
static esp_err_t h_coredump_get(api_req_t *req)
{
    const size_t size = health_coredump_size();
    if (size == 0) return send_error(req, ST_404, "no_coredump", "no core dump stored (no crash since the last DELETE /coredump)");
    uint8_t *all = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (all) {
        esp_err_t err = ESP_OK;
        for (size_t off = 0; off < size && err == ESP_OK; off += IO_CHUNK) {
            err = health_coredump_read(off, all + off, size - off < IO_CHUNK ? size - off : IO_CHUNK);
        }
        if (err == ESP_OK) err = req->ops->send(req, ST_200, "application/octet-stream", (const char *)all, size);
        else err = send_error(req, ST_500, "io_error", esp_err_to_name(err));
        free(all);
        return err;
    }
    char *buf = io_alloc(IO_CHUNK);
    if (!buf) return send_no_memory(req, "the response");
    esp_err_t err = ESP_OK;
    for (size_t off = 0; off < size && err == ESP_OK; off += IO_CHUNK) {
        const size_t n = size - off < IO_CHUNK ? size - off : IO_CHUNK;
        err = health_coredump_read(off, buf, n);
        if (err == ESP_OK) err = req->ops->send_chunk(req, "application/octet-stream", buf, n);
    }
    free(buf);
    if (err == ESP_OK) err = req->ops->send_chunk(req, "application/octet-stream", NULL, 0);
    return err;   /* a read error mid-stream can only end the response: the client sees a short body */
}

static esp_err_t h_coredump_delete(api_req_t *req)
{
    const esp_err_t err = health_coredump_erase();
    if (err == ESP_ERR_NOT_FOUND) return send_error(req, ST_404, "no_coredump", "no core dump stored");
    if (err != ESP_OK) return send_error(req, ST_500, "io_error", esp_err_to_name(err));
    return send_ok(req);
}

/* ------------------------------------------------------------------ Reader (PROTOCOL §5c) */

static cJSON *text_json(const reader_text_info_t *t)
{
    char hex[65];
    storage_sha_to_hex(t->sha256, hex);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "id", t->id);
    cJSON_AddNumberToObject(o, "bytes", t->bytes);
    cJSON_AddNumberToObject(o, "words", t->words);
    cJSON_AddStringToObject(o, "title", t->title);
    cJSON_AddNumberToObject(o, "progress_word", reader_progress_get(t->id));
    cJSON_AddStringToObject(o, "sha256", hex);
    cJSON_AddNumberToObject(o, "minutes", rsvp_minutes(rsvp_total_ms(t->factor_x10, t->paragraphs, RSVP_WPM_DEFAULT)));
    return o;
}

static bool add_text(const reader_text_info_t *t, void *ctx)
{
    cJSON_AddItemToArray((cJSON *)ctx, text_json(t));
    return true;
}

static esp_err_t h_texts_list(api_req_t *req)
{
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    reader_text_foreach(add_text, cJSON_AddArrayToObject(o, "texts"));
    return send_json(req, ST_200, o);
}

static esp_err_t h_text_put(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1];
    uint8_t sha[32];
    if (!path_tail(req, "/texts/", id, sizeof id) || !storage_id_valid(id)) {
        return send_error(req, ST_400, "invalid_id", "text id must match [a-z0-9][a-z0-9-]{0,31}");
    }
    if (!header_sha(req, sha)) return send_error(req, ST_400, "missing_sha256", "X-Content-SHA256 header (64 hex chars) required");
    if (req->content_len == 0) return send_error(req, ST_411, "empty_body", "Content-Length required");
    if (req->content_len > READER_TEXT_MAX_BYTES) return send_error(req, ST_413, "too_large", "texts are limited to 1 MB");
    if (!upload_admitted(req)) return ESP_OK;
    reader_text_info_t existing;
    if (reader_text_info(id, &existing) && memcmp(existing.sha256, sha, 32) == 0 && existing.bytes == req->content_len) {
        cJSON *o = text_json(&existing);
        cJSON_AddBoolToObject(o, "ok", false);
        cJSON_AddStringToObject(o, "error", "exists");
        cJSON_AddStringToObject(o, "message", "identical text already stored");
        return send_json(req, ST_409, o);
    }
    reader_writer_t *w = NULL;
    storage_status_t st = reader_text_write_begin(id, req->content_len, &w);
    if (st == STORAGE_ERR_NO_SPACE) return send_error(req, ST_413, "no_space", "not enough space on the clip");
    if (st == STORAGE_ERR_TOO_MANY) return send_error(req, ST_413, "too_many_texts", "at most 64 texts");
    if (st != STORAGE_OK) return send_error(req, ST_500, storage_status_str(st), NULL);
    char *buf = io_alloc(IO_CHUNK);
    if (!buf) {
        reader_text_write_abort(w);
        return send_no_memory(req, "the upload buffer");
    }
    size_t left = req->content_len;
    player_upload_active(true);
    while (left > 0 && st == STORAGE_OK) {
        int n = req->ops->recv(req, buf, left < IO_CHUNK ? left : IO_CHUNK);
        if (n <= 0) {   /* closed, stalled or too slow (slow-client guard), or the session is ending */
            player_upload_active(false);
            free(buf);
            reader_text_write_abort(w);
            ESP_LOGW(TAG, "text %s: abandoned with %u bytes left", id, (unsigned)left);
            return ESP_FAIL;
        }
        st = reader_text_write(w, buf, (size_t)n);
        left -= (size_t)n;
        if ((left & 0xFFFF) < IO_CHUNK) net_touch();
    }
    player_upload_active(false);
    free(buf);
    if (st != STORAGE_OK) {
        reader_text_write_abort(w);
        return send_error(req, st == STORAGE_ERR_NO_SPACE ? ST_413 : ST_500, storage_status_str(st), NULL);
    }
    reader_text_info_t info;
    const bool held = player_release_files(NULL, id);   /* screen-on session: may be the text being read */
    st = reader_text_write_finish(w, sha, &info);
    if (st != STORAGE_OK && held) player_reload_for(PLAYER_RELOAD_TEXT, id, false);
    if (st == STORAGE_ERR_HASH) return send_error(req, ST_422, "sha256_mismatch", "body does not match X-Content-SHA256");
    if (st == STORAGE_ERR_MALFORMED) {
        return send_error(req, ST_422, "malformed", "not UTF-8 plain text with at least one word (invalid UTF-8 or NUL bytes)");
    }
    if (st == STORAGE_ERR_NO_SPACE) return send_error(req, ST_413, "no_space", "not enough space for the word index");
    if (st != STORAGE_OK) return send_error(req, ST_500, storage_status_str(st), NULL);
    player_reload_for(PLAYER_RELOAD_TEXT, id, false);   /* a reader item on this text restarts with the new content */
    net_note_upload(id);
    cJSON *o = text_json(&info);
    cJSON_AddBoolToObject(o, "ok", true);
    return send_json(req, ST_201, o);
}

static esp_err_t h_text_get(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1], path[96];
    if (!path_tail(req, "/texts/", id, sizeof id) || !reader_text_exists(id)) {
        return send_error(req, ST_404, "not_found", "no such text");
    }
    reader_text_path(id, path, sizeof path);
    int fd = open(path, O_RDONLY);
    char *buf = io_alloc(IO_CHUNK);
    if (fd < 0 || !buf) {
        if (fd >= 0) close(fd);
        free(buf);
        return send_error(req, ST_500, "io_error", NULL);
    }
    static const char type[] = "text/plain; charset=utf-8";
    esp_err_t err = ESP_OK;
    ssize_t n;
    while (err == ESP_OK && (n = read(fd, buf, IO_CHUNK)) > 0) err = req->ops->send_chunk(req, type, buf, (size_t)n);
    close(fd);
    free(buf);
    if (err == ESP_OK) err = req->ops->send_chunk(req, type, NULL, 0);
    return err;
}

static esp_err_t h_text_delete(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1];
    if (!path_tail(req, "/texts/", id, sizeof id) || !storage_id_valid(id)) return send_error(req, ST_400, "invalid_id", NULL);
    const bool held = player_release_files(NULL, id);
    if (reader_text_delete(id) != STORAGE_OK) {
        if (held) player_reload_for(PLAYER_RELOAD_TEXT, id, false);
        return send_error(req, ST_404, "not_found", "no such text");
    }
    if (playlist_remove_reader("text", id) != ESP_OK) ESP_LOGE(TAG, "playlist update after text delete failed");
    player_reload_for(PLAYER_RELOAD_TEXT, id, true);
    return send_ok(req);
}

typedef struct { cJSON *arr; rsvp_font_t *f; } font_list_t;

static bool add_font(const char *id, void *ctx)
{
    font_list_t *l = ctx;
    char *json = NULL;
    size_t len = 0;
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "id", id);
    if (reader_font_read(id, &json, &len) == ESP_OK && rsvp_font_parse(json, len, l->f, NULL, 0) == RSVP_OK) {
        cJSON_AddNumberToObject(o, "glyphs", l->f->normal.count);
        cJSON_AddNumberToObject(o, "cell_w", l->f->normal.cell_w);
        cJSON_AddNumberToObject(o, "cell_h", l->f->normal.cell_h);
        cJSON_AddBoolToObject(o, "compact", l->f->has_compact);
        cJSON_AddBoolToObject(o, "large", l->f->has_large);   /* §5f.11 */
    }
    free(json);
    cJSON_AddItemToArray(l->arr, o);
    return true;
}

/* GET /fonts (extension): the stored reader fonts. */
static esp_err_t h_fonts_list(api_req_t *req)
{
    font_list_t l = { NULL, heap_caps_malloc(sizeof(rsvp_font_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT) };
    if (!l.f) return send_no_memory(req, "the response");
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    l.arr = cJSON_AddArrayToObject(o, "fonts");
    reader_font_foreach(add_font, &l);
    free(l.f);
    return send_json(req, ST_200, o);
}

static esp_err_t h_font_put(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1];
    if (!path_tail(req, "/fonts/", id, sizeof id) || !storage_id_valid(id)) {
        return send_error(req, ST_400, "invalid_id", "font id must match [a-z0-9][a-z0-9-]{0,31}");
    }
    const char *buf;
    size_t len;
    if (!json_type_ok(req)) return ESP_OK;
    if (read_body(req, READER_FONT_MAX_BYTES, &buf, &len) != ESP_OK) return ESP_OK;
    char msg[160] = "";
    esp_err_t v = reader_font_validate(buf, len, msg, sizeof msg);
    esp_err_t err;
    if (v == ESP_ERR_INVALID_ARG) {
        err = send_error(req, ST_422, "malformed", msg);
    } else if (v == ESP_ERR_NOT_FOUND) {
        err = send_error(req, ST_422, "unknown_asset", msg);
    } else if (v != ESP_OK) {
        err = send_no_memory(req, "the response");
    } else {
        esp_err_t w = reader_font_store(id, buf, len);
        if (w == ESP_ERR_NO_MEM) {
            err = send_error(req, ST_413, "too_many_fonts", "at most 32 fonts");
        } else if (w != ESP_OK) {
            err = send_error(req, ST_500, "io_error", NULL);
        } else {
            player_reload_for(PLAYER_RELOAD_FONT, id, false);   /* a reader item using this font restarts with it */
            cJSON *o = cJSON_CreateObject();
            cJSON_AddBoolToObject(o, "ok", true);
            cJSON_AddStringToObject(o, "id", id);
            cJSON_AddNumberToObject(o, "size", len);
            err = send_json(req, ST_201, o);
        }
    }
    return err;
}

static esp_err_t h_font_get(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1];
    char *json = NULL;
    size_t len = 0;
    if (!path_tail(req, "/fonts/", id, sizeof id) || reader_font_read(id, &json, &len) != ESP_OK) {
        return send_error(req, ST_404, "unknown_font", "no such font");
    }
    esp_err_t err = send_stored_json(req, json, len);
    free(json);
    return err;
}

/* DELETE /fonts/{id} (extension): also removes the reader items that use it. */
static esp_err_t h_font_delete(api_req_t *req)
{
    char id[STORAGE_ID_MAX + 1];
    if (!path_tail(req, "/fonts/", id, sizeof id) || !storage_id_valid(id)) return send_error(req, ST_400, "invalid_id", NULL);
    if (reader_font_delete(id) != STORAGE_OK) return send_error(req, ST_404, "unknown_font", "no such font");
    if (playlist_remove_reader("font", id) != ESP_OK) ESP_LOGE(TAG, "playlist update after font delete failed");
    player_reload_for(PLAYER_RELOAD_FONT, id, true);
    return send_ok(req);
}

static cJSON *reader_json(void)
{
    player_reader_status_t r;
    player_get_reader(&r);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON_AddBoolToObject(o, "active", r.active);
    if (r.active) {
        cJSON_AddStringToObject(o, "text", r.text);
    } else {
        cJSON_AddNullToObject(o, "text");
    }
    cJSON_AddNumberToObject(o, "word", r.word);
    cJSON_AddNumberToObject(o, "words", r.words);
    cJSON_AddBoolToObject(o, "paused", r.paused);
    cJSON_AddNumberToObject(o, "wpm", r.wpm);
    if (r.active) {
        cJSON_AddStringToObject(o, "font", r.font);
        cJSON_AddStringToObject(o, "title", r.title);
        cJSON_AddBoolToObject(o, "end_card", r.end_card);
    }
    return o;
}

static esp_err_t h_reader_get(api_req_t *req)
{
    return send_json(req, ST_200, reader_json());
}

static esp_err_t h_reader_post(api_req_t *req)
{
    cJSON *j = read_json(req, JSON_SMALL_MAX);
    if (!j) return ESP_OK;
    const cJSON *a = cJSON_GetObjectItemCaseSensitive(j, "action");
    const cJSON *wd = cJSON_GetObjectItemCaseSensitive(j, "word");
    char action[12] = "";
    const bool has_action = cJSON_IsString(a);
    if (has_action) strlcpy(action, a->valuestring, sizeof action);
    bool word_ok = cJSON_IsNumber(wd) && wd->valuedouble >= 0 && wd->valuedouble <= 4294967295.0 &&
                   wd->valuedouble == floor(wd->valuedouble);
    uint32_t word = word_ok ? (uint32_t)wd->valuedouble : 0;
    cJSON_Delete(j);
    if (!has_action) return send_error(req, ST_400, "bad_json", "body must be {\"action\":\"pause\"|\"resume\"|\"seek\",\"word\":n}");
    player_reader_action_t act;
    if (strcmp(action, "pause") == 0) act = PLAYER_READER_PAUSE;
    else if (strcmp(action, "resume") == 0) act = PLAYER_READER_RESUME;
    else if (strcmp(action, "seek") == 0) act = PLAYER_READER_SEEK;
    else return send_error(req, ST_422, "invalid_action", "action must be \"pause\", \"resume\" or \"seek\"");
    if (act == PLAYER_READER_SEEK && !word_ok) return send_error(req, ST_422, "invalid_word", "seek needs \"word\": an integer >= 0");
    esp_err_t r = player_reader_control(act, word);
    if (r == ESP_ERR_INVALID_STATE) return send_error(req, ST_409, "no_reader", "no reader item is playing");
    if (r == ESP_ERR_INVALID_ARG) return send_error(req, ST_422, "invalid_word", "word is beyond the end of the text");
    if (r == ESP_ERR_TIMEOUT) return send_error(req, ST_500, "busy", "the player did not answer");
    if (r != ESP_OK) return send_error(req, ST_500, "reader_failed", "could not read the text");
    return send_json(req, ST_200, reader_json());
}

#if CONFIG_PIXELCLIP_BENCH_ROUTES
/* Bench builds only (health.h): POST /bench/crash {"kind":...}, POST /bench/wedge {"mode":...}. */
static esp_err_t bench_fault(api_req_t *req, bool crash)
{
    cJSON *j = read_json(req, JSON_SMALL_MAX);
    if (!j) return ESP_OK;
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(j, crash ? "kind" : "mode");
    char what[16] = "";
    if (cJSON_IsString(v)) strlcpy(what, v->valuestring, sizeof what);
    cJSON_Delete(j);
    const esp_err_t err = crash ? health_bench_crash(what) : health_bench_wedge(what);
    if (err == ESP_ERR_INVALID_ARG) {
        return send_error(req, ST_422, "invalid_fault", crash ? "kind: abort | assert | null | stack"
                          : "mode: sleep | suspend | irqoff | player | power | httpd | tcpip | ble | controller");
    }
    if (err != ESP_OK) return send_error(req, ST_500, "fault_failed", esp_err_to_name(err));
    ESP_LOGW(TAG, "bench: %s %s armed by %s", crash ? "crash" : "wedge", what, req->transport);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON_AddStringToObject(o, crash ? "kind" : "mode", what);
    cJSON_AddNumberToObject(o, "rtc_wdt_s", CONFIG_PIXELCLIP_RTC_WDT_TIMEOUT_S);
    return send_json(req, ST_200, o);
}
static esp_err_t h_bench_crash(api_req_t *req) { return bench_fault(req, true); }
static esp_err_t h_bench_wedge(api_req_t *req) { return bench_fault(req, false); }
#endif

esp_err_t api_not_found(api_req_t *req)
{
    send_error(req, ST_404, "not_found", "unknown endpoint");
    return ESP_OK;
}

esp_err_t api_bad_method(api_req_t *req)
{
    send_error(req, "405 Method Not Allowed", "method_not_allowed", "method not supported on this path");
    return ESP_OK;
}

/* ------------------------------------------------------------------ routes (shared by both transports) */

/* Order matters (first match wins, as in esp_http_server). The last column = WiFi only (api_route_t.wifi_only):
 * the bulk transfers of PROTOCOL §3b (PUT /assets/{id}, PUT /texts/{id}, POST /ota, GET /screenshot,
 * GET /assets/{id}, GET /batlog, plus the GET /coredump extension), and the three development / bench routes
 * that the unpaired BLE link must not offer (security audits WIFI-10 / BLE-9): GET /imu (the wearer's head
 * motion), POST /imu/calibrate (replaces or erases the stored axis map) and POST /queue/test. The app only
 * calls /imu and /imu/calibrate after it has joined the hotspot (its calibration wizard connects first).
 * POST /ota/ask is WiFi only as well: someone in BLE range must not be able to put "Update?" on the screen. */
const api_route_t api_routes[] = {
    { "/status",        HTTP_GET,    h_status,        false },
    { "/assets",        HTTP_GET,    h_assets_list,   false },
    { "/assets/*",      HTTP_PUT,    h_asset_put,     true  },
    { "/assets/*",      HTTP_DELETE, h_asset_delete,  false },
    { "/assets/*",      HTTP_GET,    h_asset_get,     true  },
    { "/playlist",      HTTP_GET,    h_playlist_get,  false },
    { "/playlist",      HTTP_PUT,    h_playlist_put,  false },
    { "/config",        HTTP_GET,    h_config_get,    false },
    { "/config",        HTTP_PUT,    h_config_put,    false },
    { "/time",          HTTP_POST,   h_time,          false },
    { "/show/*",        HTTP_POST,   h_show,          false },
    { "/oracle/draw",   HTTP_POST,   h_oracle_draw,   false },   /* PROTOCOL §5f: fast-lane eligible */
    { "/oracle/turn",   HTTP_POST,   h_oracle_turn,   false },
    { "/oracle/back",   HTTP_POST,   h_oracle_back,   false },   /* §5f.3 extension: the previous screen */
    { "/next",          HTTP_POST,   h_next,          false },
    { "/queue/test",    HTTP_POST,   h_queue_test,    true  },   /* development aid: WiFi only */
    { "/prev",          HTTP_POST,   h_prev,          false },
    { "/brightness",    HTTP_POST,   h_brightness,    false },
    { "/screenshot",    HTTP_GET,    h_screenshot,    true  },
    { "/ota",           HTTP_POST,   h_ota,           true  },
    { "/ota",           HTTP_GET,    h_ota_get,       false },   /* the update permission: fast-lane eligible */
    { "/ota/ask",       HTTP_POST,   h_ota_ask,       true  },   /* the prompt on the clip: WiFi only */
    { "/session/end",   HTTP_POST,   h_session_end,   false },
    { "/batlog",        HTTP_GET,    h_batlog_get,    true  },
    { "/imu",           HTTP_GET,    h_imu,           true  },   /* bench: WiFi only */
    { "/imu/calibrate", HTTP_POST,   h_imu_calibrate, true  },
    { "/scenes",        HTTP_GET,    h_scenes,        false },
    { "/batlog",        HTTP_DELETE, h_batlog_delete, false },
    { "/coredump",      HTTP_GET,    h_coredump_get,  true  },   /* README "Crash diagnostics" */
    { "/coredump",      HTTP_DELETE, h_coredump_delete, false },
    { "/texts",         HTTP_GET,    h_texts_list,    false },
    { "/texts/*",       HTTP_PUT,    h_text_put,      true  },
    { "/texts/*",       HTTP_GET,    h_text_get,      false },   /* streamed; over BLE up to the 16 KB response cap */
    { "/texts/*",       HTTP_DELETE, h_text_delete,   false },
    { "/fonts",         HTTP_GET,    h_fonts_list,    false },
    { "/fonts/*",       HTTP_PUT,    h_font_put,      false },
    { "/fonts/*",       HTTP_GET,    h_font_get,      false },
    { "/fonts/*",       HTTP_DELETE, h_font_delete,   false },
    { "/reader",        HTTP_GET,    h_reader_get,    false },
    { "/reader",        HTTP_POST,   h_reader_post,   false },
    { "/ble",           HTTP_GET,    h_ble,           false },
#if CONFIG_PIXELCLIP_BENCH_ROUTES
    { "/bench/crash",   HTTP_POST,   h_bench_crash,   false },   /* bench builds only (health.h) */
    { "/bench/wedge",   HTTP_POST,   h_bench_wedge,   false },
#endif
};
const size_t api_route_count = sizeof api_routes / sizeof api_routes[0];

const api_route_t *api_find_route(int method, const char *path, size_t path_len, bool *path_matched)
{
    *path_matched = false;
    for (size_t i = 0; i < api_route_count; i++) {
        if (!httpd_uri_match_wildcard(api_routes[i].uri, path, path_len)) continue;
        if (api_routes[i].method == method) return &api_routes[i];
        *path_matched = true;
    }
    return NULL;
}

static SemaphoreHandle_t s_api_lock;
static StaticSemaphore_t s_api_lock_buf;

bool api_lock(uint32_t timeout_ms)
{
    if (!s_api_lock) return true;
    return xSemaphoreTake(s_api_lock, timeout_ms == UINT32_MAX ? portMAX_DELAY : pdMS_TO_TICKS(timeout_ms)) == pdTRUE;
}

void api_unlock(void)
{
    if (s_api_lock) xSemaphoreGive(s_api_lock);
}

static void *json_malloc(size_t n)
{
    void *p = heap_caps_malloc(n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    return p ? p : malloc(n);
}

void http_api_init(void)
{
    if (!s_api_lock) s_api_lock = xSemaphoreCreateMutexStatic(&s_api_lock_buf);
    /* Every cJSON tree and printed document (playlist, config, status ...) in PSRAM: a 16 KB
     * playlist parse is hundreds of small nodes that would otherwise all land in internal RAM. */
    cJSON_Hooks hooks = { .malloc_fn = json_malloc, .free_fn = free };
    cJSON_InitHooks(&hooks);
    api_ble_init();
}

/* ------------------------------------------------------------------ esp_http_server adapter */

/* Slow-client guard (security audit WIFI-8).
 *
 * esp_http_server serves every connection on one task, and the controller (which feeds the RTC watchdog) waits
 * for that task when a session ends. A client that trickles its request, stops sending in the middle of an upload
 * or stops reading a response used to keep the task inside the server (no liveness beat: an RTC watchdog reset
 * after about 70 s), or kept the session end waiting until it was done. Now every socket call of the server goes
 * through http_sock_recv / http_sock_send (installed per connection by http_api_on_open), which
 *   - beat the httpd liveness source: the sockets time out after HTTP_SOCK_TIMEOUT_S (5 s), so a waiting task
 *     checks in at least that often and only a task that is really stuck goes silent;
 *   - fail as soon as the session is ending (http_api_stopping): the handler abandons its request cleanly (temp
 *     file removed, OTA aborted) and httpd_stop() returns within one socket timeout;
 *   - bound the request line + headers: HTTP_HEADER_MS in all (they are at most 1.2 KB: one or two packets).
 * and the body / response rules below, which are deliberately far outside anything a working link does:
 *   - silence: HTTP_RX_SILENCE_MS (30 s, what three 10 s timeouts allowed before) without a single body byte, or
 *     HTTP_TX_SILENCE_MS (10 s, the old send timeout) without the client taking a byte, ends the request;
 *   - floor: whenever the server has spent HTTP_FLOOR_WINDOW_MS (30 s) blocked on the client, in either
 *     direction, at least HTTP_FLOOR_BYTES (4 KB) must have moved in that time. Only time spent waiting for the
 *     client counts (not flash writes, hashing or decoding), so a slow clip never trips it. 4 KB per 30 s is
 *     137 B/s: a 1 MB picture would take two hours at that rate, while the app gives a whole transfer 5 minutes
 *     and gives up itself after 20 s (assets) to 60 s (firmware) without progress. A several-MB upload over a
 *     poor link (tens of KB/s, with stalls of seconds) is nowhere near either rule.
 * A body the handler did not read (an early error, a route without a body) is drained here under the same
 * rules, with the upload buffer instead of the server's own purge loop, so the answer reaches the client as it
 * did before; a declared body larger than the clip's whole flash is not read at all (the connection closes).
 * The idle timer of the session is refreshed while bytes move (at most once a second), so a long transfer
 * never times the session out underneath itself. */
#define HTTP_HEADER_MS         10000
#define HTTP_RX_SILENCE_MS     30000
#define HTTP_TX_SILENCE_MS     10000
#define HTTP_FLOOR_WINDOW_MS   30000
#define HTTP_FLOOR_BYTES       4096
#define HTTP_STOP_GRACE_MS     3000                   /* a response already on its way when the session ends */
#define HTTP_DRAIN_MAX         (16u * 1024 * 1024)    /* the flash size: no legitimate body is larger */

typedef struct {
    int64_t wait_us;      /* time blocked on the client in the current window */
    size_t bytes;         /* bytes moved in it */
} http_floor_t;

/* All of it belongs to the httpd task (one request at a time), except `stopping`. */
static struct {
    bool in_request;      /* a route / error handler owns the connection (else: request line + headers) */
    int hdr_fd;           /* the connection whose headers are being read ... */
    int64_t hdr_t0_us;    /* ... since when (0 = no request begun) */
    size_t consumed;      /* body bytes of this request read so far */
    http_floor_t rx, tx;
    int64_t touch_us;     /* last idle-timer refresh from a transfer */
    int64_t stop_wait_us; /* time a send blocked after the session began to end */
} s_http;
static volatile bool s_http_stopping;

void http_api_stopping(bool stopping) { s_http_stopping = stopping; }

/* Account `waited_us` blocked on the client and `n` bytes moved; false when the floor is not met. */
static bool http_floor_ok(http_floor_t *f, int64_t waited_us, size_t n)
{
    f->wait_us += waited_us;
    f->bytes += n;
    if (f->wait_us < (int64_t)HTTP_FLOOR_WINDOW_MS * 1000) return true;
    const bool ok = f->bytes >= HTTP_FLOOR_BYTES;
    f->wait_us = 0;
    f->bytes = 0;
    return ok;
}

/* Bytes are moving in a request: keep the session's idle timer away (at most once a second). */
static void http_transfer_touch(int64_t now)
{
    if (!s_http.in_request || now - s_http.touch_us < 1000000) return;
    s_http.touch_us = now;
    net_touch();
}

static int http_sock_errno(void)
{
    switch (errno) {
    case EAGAIN:
#if EWOULDBLOCK != EAGAIN
    case EWOULDBLOCK:
#endif
    case EINTR: return HTTPD_SOCK_ERR_TIMEOUT;
    case EINVAL:
    case EBADF:
    case EFAULT:
    case ENOTSOCK: return HTTPD_SOCK_ERR_INVALID;
    default: return HTTPD_SOCK_ERR_FAIL;
    }
}

/* One recv() of the server: request line and headers (outside a handler, bounded here), or one read of a body
 * (inside one: http_recv below owns the waiting rules). */
static int http_sock_recv(httpd_handle_t hd, int fd, char *buf, size_t len, int flags)
{
    if (!buf) return HTTPD_SOCK_ERR_INVALID;
    if (s_http_stopping) return HTTPD_SOCK_ERR_FAIL;
    if (!s_http.in_request) {
        const int64_t now = esp_timer_get_time();
        if (s_http.hdr_fd != fd || s_http.hdr_t0_us == 0) {
            s_http.hdr_fd = fd;
            s_http.hdr_t0_us = now;
        } else if (now - s_http.hdr_t0_us > (int64_t)HTTP_HEADER_MS * 1000) {
            ESP_LOGW(TAG, "request headers not complete after %d s: closing the connection", HTTP_HEADER_MS / 1000);
            s_http.hdr_t0_us = 0;
            return HTTPD_SOCK_ERR_TIMEOUT;   /* the server answers 408 and closes */
        }
    }
    const int n = recv(fd, buf, len, flags);
    health_beat(HEALTH_SRC_HTTPD);   /* data, or a bounded timeout: the task is not wedged */
    return n < 0 ? http_sock_errno() : n;
}

/* One send() of the server (a response, whole or in chunks). The server gives up on the first timeout, so the
 * waiting rules for a client that reads slowly or not at all live here. */
static int http_sock_send(httpd_handle_t hd, int fd, const char *buf, size_t len, int flags)
{
    if (!buf) return HTTPD_SOCK_ERR_INVALID;
    int64_t silent_us = 0;
    for (;;) {
        const int64_t t0 = esp_timer_get_time();
        const int n = send(fd, buf, len, flags);
        const int64_t now = esp_timer_get_time();
        health_beat(HEALTH_SRC_HTTPD);
        const int err = n < 0 ? http_sock_errno() : 0;
        if (n < 0 && err != HTTPD_SOCK_ERR_TIMEOUT) return err;
        if (s_http_stopping) {
            /* The session is ending: a response that goes out without waiting still does; one that makes the
             * server wait gets HTTP_STOP_GRACE_MS in all. */
            s_http.stop_wait_us += now - t0;
            if (n < 0 || s_http.stop_wait_us > (int64_t)HTTP_STOP_GRACE_MS * 1000) return HTTPD_SOCK_ERR_FAIL;
        }
        /* (the server's own short error answers, outside a request, are not held to the floor) */
        if (s_http.in_request && !http_floor_ok(&s_http.tx, now - t0, n > 0 ? (size_t)n : 0)) {
            ESP_LOGW(TAG, "client reads slower than %d B per %d s: closing the connection", HTTP_FLOOR_BYTES,
                     HTTP_FLOOR_WINDOW_MS / 1000);
            return HTTPD_SOCK_ERR_FAIL;
        }
        if (n >= 0) {
            http_transfer_touch(now);
            return n;
        }
        silent_us += now - t0;
        if (silent_us >= (int64_t)HTTP_TX_SILENCE_MS * 1000) {
            ESP_LOGW(TAG, "client took nothing for %d s: closing the connection", HTTP_TX_SILENCE_MS / 1000);
            return HTTPD_SOCK_ERR_TIMEOUT;
        }
    }
}

esp_err_t http_api_on_open(httpd_handle_t server, int sockfd)
{
    if (s_http.hdr_fd == sockfd) s_http.hdr_t0_us = 0;   /* a new connection on a recycled descriptor */
    esp_err_t err = httpd_sess_set_recv_override(server, sockfd, http_sock_recv);
    if (err == ESP_OK) err = httpd_sess_set_send_override(server, sockfd, http_sock_send);
    return err;
}

static esp_err_t http_send(api_req_t *r, const char *status, const char *type, const char *data, size_t len)
{
    httpd_req_t *req = r->ctx;
    health_beat(HEALTH_SRC_HTTPD);
    httpd_resp_set_status(req, status);
    httpd_resp_set_type(req, type);
    return httpd_resp_send(req, data, (ssize_t)len);
}

static esp_err_t http_send_chunk(api_req_t *r, const char *type, const char *data, size_t len)
{
    httpd_req_t *req = r->ctx;
    health_beat(HEALTH_SRC_HTTPD);
    if (type) httpd_resp_set_type(req, type);   /* only takes effect before the first chunk; harmless after */
    return httpd_resp_send_chunk(req, data, data ? (ssize_t)len : 0);
}

/* Body bytes for a handler: > 0, or <= 0 when the request is over for it (the client closed, sent nothing for
 * HTTP_RX_SILENCE_MS, fell below the floor, or the session is ending). Never HTTPD_SOCK_ERR_TIMEOUT: the waiting
 * happens here, in HTTP_SOCK_TIMEOUT_S steps, each with a liveness beat (http_sock_recv). */
static int http_recv(api_req_t *r, char *buf, size_t len)
{
    httpd_req_t *req = r->ctx;
    int64_t silent_us = 0;
    for (;;) {
        const int64_t t0 = esp_timer_get_time();
        const int n = httpd_req_recv(req, buf, len);
        const int64_t now = esp_timer_get_time();
        health_beat(HEALTH_SRC_HTTPD);
        if (n != HTTPD_SOCK_ERR_TIMEOUT && n <= 0) return n;
        if (n > 0) s_http.consumed += (size_t)n;
        if (!http_floor_ok(&s_http.rx, now - t0, n > 0 ? (size_t)n : 0)) {
            ESP_LOGW(TAG, "%s %s: body slower than %d B per %d s: giving up", r->method_name, r->uri, HTTP_FLOOR_BYTES,
                     HTTP_FLOOR_WINDOW_MS / 1000);
            return HTTPD_SOCK_ERR_FAIL;
        }
        if (n > 0) {
            http_transfer_touch(now);
            return n;
        }
        silent_us += now - t0;
        if (s_http_stopping || silent_us >= (int64_t)HTTP_RX_SILENCE_MS * 1000) {
            ESP_LOGW(TAG, "%s %s: %s: giving up", r->method_name, r->uri,
                     s_http_stopping ? "the session is ending" : "no body bytes for 30 s");
            return HTTPD_SOCK_ERR_FAIL;
        }
    }
}

static bool http_header(api_req_t *r, const char *name, char *out, size_t out_len)
{
    return httpd_req_get_hdr_value_str((httpd_req_t *)r->ctx, name, out, out_len) == ESP_OK;
}

static const api_ops_t s_http_ops = {
    .send = http_send,
    .send_chunk = http_send_chunk,
    .recv = http_recv,
    .header = http_header,
};

/* A request reached a handler (a route's, or the 404 / 405 answers): its headers are in. */
static void http_req_init(api_req_t *r, httpd_req_t *req)
{
    memset(r, 0, sizeof *r);
    r->method = req->method;
    r->method_name = http_method_str((enum http_method)req->method);
    r->uri = req->uri;
    const char *q = strchr(req->uri, '?');
    r->query = q ? q + 1 : NULL;
    r->content_len = req->content_len;
    r->ops = &s_http_ops;
    r->ctx = req;
    r->transport = "http";
    s_http.in_request = true;
    s_http.consumed = 0;
    s_http.rx = s_http.tx = (http_floor_t){ 0 };
    s_http.stop_wait_us = 0;
    s_http.touch_us = esp_timer_get_time();   /* the caller has just touched the idle timer */
}

/* The request is answered: read what is left of its body (see the guard above), then hand the connection back
 * to the server. ESP_FAIL makes the server close it. */
static esp_err_t http_req_done(api_req_t *r, esp_err_t err)
{
    size_t left = r->content_len > s_http.consumed ? r->content_len - s_http.consumed : 0;
    if (err == ESP_OK && left > 0) {
        char small[128];
        char *buf = left > sizeof small ? io_alloc(IO_CHUNK) : NULL;
        char *dst = buf ? buf : small;
        const size_t cap = buf ? IO_CHUNK : sizeof small;
        if (left > HTTP_DRAIN_MAX) {
            ESP_LOGW(TAG, "%s %s: %u unread body bytes: closing the connection", r->method_name, r->uri, (unsigned)left);
            err = ESP_FAIL;
        }
        while (err == ESP_OK && left > 0) {
            const int n = http_recv(r, dst, left < cap ? left : cap);
            if (n <= 0) err = ESP_FAIL;
            else left -= (size_t)n;
        }
        free(buf);
    }
    s_http.in_request = false;
    s_http.hdr_t0_us = 0;   /* the next bytes on any connection start a new request */
    return err;
}

/* PROTOCOL §4 "Request checks" (security audit WIFI-4), HTTP only. The clip serves no web pages, so no request
 * of its own clients (the app's URLSession, curl, the scripts) is ever made by a page:
 *   - Origin: browsers add it to every cross-origin request that can change state (and to every fetch that
 *     wants to read the answer). Any request that carries one is refused, as is one whose Sec-Fetch-Site says
 *     it was started by another site;
 *   - Host must name this clip (its address or pixelclip.local, with or without ":80"): a page that points its
 *     own host name at 192.168.4.1 (DNS rebinding) would otherwise be same-origin with the whole API. A
 *     request without Host is served: only HTTP/1.0 tools send none, a browser always sends one, and a client
 *     that is not a browser could write any Host it likes, so refusing it would protect nothing.
 * On refusal the 403 has been sent. The fast lane has no headers and is not checked. */
static bool http_request_allowed(httpd_req_t *req, api_req_t *r)
{
    char v[64];
    if (httpd_req_get_hdr_value_len(req, "Origin") > 0) {
        send_error(r, ST_403, "cross_origin", "requests from web pages are not served");
        return false;
    }
    if (httpd_req_get_hdr_value_len(req, "Sec-Fetch-Site") > 0 &&
        !(httpd_req_get_hdr_value_str(req, "Sec-Fetch-Site", v, sizeof v) == ESP_OK &&
          (strcasecmp(v, "none") == 0 || strcasecmp(v, "same-origin") == 0))) {
        send_error(r, ST_403, "cross_origin", "requests from web pages are not served");
        return false;
    }
    if (httpd_req_get_hdr_value_len(req, "Host") > 0 &&
        !(httpd_req_get_hdr_value_str(req, "Host", v, sizeof v) == ESP_OK && net_host_allowed(v))) {
        send_error(r, ST_403, "bad_host", "address the clip as 192.168.4.1 or pixelclip.local");
        return false;
    }
    return true;
}

/* Every route is registered with this trampoline; user_ctx is its api_routes[] entry. */
static esp_err_t http_dispatch(httpd_req_t *req)
{
    const api_route_t *rt = req->user_ctx;
    net_touch();   /* an HTTP request resets the session idle timer (a fast-lane request does not) */
    api_req_t r;
    http_req_init(&r, req);
    health_beat(HEALTH_SRC_HTTPD);
    health_note_http(r.method_name, r.uri, true);   /* RTC crumb: the request in flight if the clip dies */
    esp_err_t err = ESP_OK;
    if (http_request_allowed(req, &r)) {
        api_lock(UINT32_MAX);
        err = rt->handler(&r);
        api_unlock();
    }
    free(r.body_owned);
    r.body_owned = NULL;
    err = http_req_done(&r, err);   /* outside the handler lock: a slow leftover body must not hold the fast lane up */
    health_note_http(NULL, NULL, false);
    health_beat(HEALTH_SRC_HTTPD);
    return err;
}

static esp_err_t http_not_found(httpd_req_t *req, httpd_err_code_t code)
{
    net_touch();
    api_req_t r;
    http_req_init(&r, req);
    return http_req_done(&r, api_not_found(&r));
}

static esp_err_t http_bad_method(httpd_req_t *req, httpd_err_code_t code)
{
    net_touch();
    api_req_t r;
    http_req_init(&r, req);
    return http_req_done(&r, api_bad_method(&r));
}

esp_err_t http_api_register(httpd_handle_t server)
{
    for (size_t i = 0; i < api_route_count; i++) {
        const httpd_uri_t u = {
            .uri = api_routes[i].uri,
            .method = (httpd_method_t)api_routes[i].method,
            .handler = http_dispatch,
            .user_ctx = (void *)&api_routes[i],
        };
        esp_err_t err = httpd_register_uri_handler(server, &u);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "register %s: %s", api_routes[i].uri, esp_err_to_name(err));
            return err;
        }
    }
    esp_err_t err = httpd_register_err_handler(server, HTTPD_404_NOT_FOUND, http_not_found);
    if (err == ESP_OK) err = httpd_register_err_handler(server, HTTPD_405_METHOD_NOT_ALLOWED, http_bad_method);
    return err;
}
