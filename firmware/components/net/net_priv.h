/* net_priv.h — internal interface between the session manager and the HTTP API. */
#pragma once
#include "esp_http_server.h"

/* Register all PROTOCOL §4 handlers on `server`. */
esp_err_t http_api_register(httpd_handle_t server);
/* Once at boot (net_init): the handler lock and the BLE fast-lane adapter. */
void http_api_init(void);
/* httpd_config_t.open_fn: installs the slow-client guard on every new connection (http_api.c). */
esp_err_t http_api_on_open(httpd_handle_t server, int sockfd);
/* true before httpd_stop(), false before httpd_start(): a request still in flight gives up at its next
 * socket call instead of keeping the session end (and the controller, which feeds the RTC watchdog) waiting. */
void http_api_stopping(bool stopping);
/* Socket timeout (s) of every recv / send: httpd_config_t.recv_wait_timeout and .send_wait_timeout. */
#define HTTP_SOCK_TIMEOUT_S 5

/* The Host header of an HTTP request names this clip: its own address or pixelclip.local, with or without
 * ":80" (net.c; PROTOCOL §4 "Request checks"). */
bool net_host_allowed(const char *host);

/* Called for every HTTP request (never for a fast-lane one): resets the idle timer. */
void net_touch(void);
/* Request the session to end shortly (after the current response has been sent). */
void net_request_end_soon(void);
/* Apply a changed upload_timeout_s to the running session (counted from the last HTTP request). */
void net_set_timeout_s(uint32_t s);
