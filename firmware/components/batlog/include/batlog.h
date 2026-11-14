/* batlog.h — battery logger (no power meter available, so we log the discharge curve).
 *
 * Every 60 s one CSV line is appended:
 *   epoch,uptime_s,mv,pct,usb,mode,display,brightness
 * epoch is 0 while the clock is not synced; mode = playing | idle | upload; display = on | off.
 * Storage is a two-file ring (/batlog.csv + /batlog.1.csv, each <= 32 KB, so <= ~64 KB total).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BATLOG_PERIOD_S 60
#define BATLOG_HEADER   "epoch,uptime_s,mv,pct,usb,mode,display,brightness\n"

typedef struct {
    const char *mode;     /* "playing" | "idle" | "upload" */
    bool display_on;
    uint8_t brightness;
} batlog_state_t;

typedef void (*batlog_state_fn_t)(batlog_state_t *out);
typedef esp_err_t (*batlog_sink_t)(void *ctx, const char *data, size_t len);

esp_err_t batlog_init(batlog_state_fn_t state_fn);
/* Stream header + oldest..newest lines to `sink`. */
esp_err_t batlog_read(batlog_sink_t sink, void *ctx);
esp_err_t batlog_clear(void);

#ifdef __cplusplus
}
#endif
