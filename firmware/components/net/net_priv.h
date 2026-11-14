/* net_priv.h — internal interface between the session manager and the HTTP API. */
#pragma once
#include "esp_http_server.h"

/* Register all PROTOCOL §4 handlers on `server`. */
esp_err_t http_api_register(httpd_handle_t server);
/* Once at boot (net_init): the handler lock and the BLE fast-lane adapter. */
void http_api_init(void);

/* Called for every HTTP request (never for a fast-lane one): resets the idle timer. */
void net_touch(void);
/* Request the session to end shortly (after the current response has been sent). */
void net_request_end_soon(void);
/* Apply a changed upload_timeout_s to the running session (counted from the last HTTP request). */
void net_set_timeout_s(uint32_t s);
