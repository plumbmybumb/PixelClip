/* api.h — transport-neutral request object for the PROTOCOL §4 handlers (components/net, private).
 *
 * One implementation of every endpoint (http_api.c), two thin adapters onto it:
 *   - esp_http_server (http_api.c, bottom): httpd_req_t -> api_req_t, the body is read lazily from the
 *     socket (bulk endpoints stream it with ops->recv), the response goes out with httpd_resp_*;
 *   - the BLE fast lane (api_ble.c, PROTOCOL §3b): the reassembled "METHOD SP path LF [body]" -> api_req_t
 *     with the body already in memory, the response is collected into the fast-lane buffer as
 *     "STATUS SP LF [body]". No recv / header hooks: the bulk routes are refused before dispatch.
 * Handlers run one at a time (api_lock), as they did when the httpd task was their only caller.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "esp_http_server.h"   /* enum http_method (HTTP_GET, ...) and httpd_uri_match_wildcard() */

typedef struct api_req api_req_t;

typedef struct {
    /* Whole response: status line ("200 OK"), content type, body. */
    esp_err_t (*send)(api_req_t *r, const char *status, const char *type, const char *data, size_t len);
    /* Chunked response with status 200: data == NULL ends it; `type` is applied before the first chunk. */
    esp_err_t (*send_chunk)(api_req_t *r, const char *type, const char *data, size_t len);
    /* Streaming request body (bytes received, <= 0 on error, HTTPD_SOCK_ERR_TIMEOUT to retry) and request
     * headers. HTTP only (NULL on the fast lane): used by the bulk endpoints. */
    int (*recv)(api_req_t *r, char *buf, size_t len);
    bool (*header)(api_req_t *r, const char *name, char *out, size_t out_len);
} api_ops_t;

struct api_req {
    int method;                  /* HTTP_GET / HTTP_PUT / HTTP_POST / HTTP_DELETE ..., -1 = unknown */
    const char *method_name;     /* for logs */
    const char *uri;             /* path [?query] as received */
    const char *query;           /* after '?', or NULL */
    size_t content_len;          /* request body length */
    const char *body;            /* the body, NUL-terminated, once read (the fast lane provides it up front) */
    size_t body_len;
    char *body_owned;            /* read by api_body() from the socket: freed by the adapter */
    const api_ops_t *ops;
    void *ctx;                   /* adapter state: the httpd_req_t, or the fast-lane response writer */
    const char *transport;       /* "http" | "ble" (logs) */
};

typedef esp_err_t (*api_handler_t)(api_req_t *r);

typedef struct {
    const char *uri;             /* esp_http_server wildcard template, e.g. "/assets/" + "*" */
    int method;
    api_handler_t handler;
    bool bulk;                   /* bulk transfer: WiFi only (the fast lane answers 413 use_wifi) */
} api_route_t;

extern const api_route_t api_routes[];
extern const size_t api_route_count;

/* Route lookup with esp_http_server's rules (first match in table order; *path_matched = some route has
 * this path with another method -> 405). path_len excludes the query. */
const api_route_t *api_find_route(int method, const char *path, size_t path_len, bool *path_matched);

/* Shared answers (same JSON on both transports). */
esp_err_t api_send_error(api_req_t *r, const char *status, const char *code, const char *message);
esp_err_t api_not_found(api_req_t *r);    /* 404 not_found */
esp_err_t api_bad_method(api_req_t *r);   /* 405 method_not_allowed */

/* Serialise handlers across transports. timeout_ms = UINT32_MAX waits forever. */
bool api_lock(uint32_t timeout_ms);
void api_unlock(void);

/* api_ble.c: register the fast-lane adapter with components/ble. */
void api_ble_init(void);
