/* display.h — RM67162 AMOLED (536x240, QSPI) with a PSRAM framebuffer.
 *
 * The framebuffer holds RGB565 big-endian pixels (PROTOCOL §1): on this little-endian CPU a
 * uint16_t element therefore looks byte-swapped; use DISPLAY_RGB565BE() to build colours.
 *
 * Ownership: exactly one task draws at a time. Wrap draw+flush sequences in display_lock() /
 * display_unlock() (recursive mutex; every function below also takes it internally).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define DISPLAY_W 536
#define DISPLAY_H 240
#define DISPLAY_FB_BYTES (DISPLAY_W * DISPLAY_H * 2)

/* Build a big-endian RGB565 value as stored in the framebuffer (8-bit r,g,b inputs). */
#define DISPLAY_RGB565(r, g, b) ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | (((b) & 0xF8) >> 3)))
#define DISPLAY_BSWAP16(v)      ((uint16_t)((((v) >> 8) & 0xFF) | (((v) & 0xFF) << 8)))
#define DISPLAY_RGB565BE(r, g, b) DISPLAY_BSWAP16(DISPLAY_RGB565(r, g, b))

#define DISPLAY_FADE_MS 250

/* Bring up the QSPI bus, panel and framebuffer. The panel ends up awake, brightness 0, black. */
esp_err_t display_init(void);

/* Framebuffer (DISPLAY_W*DISPLAY_H pixels, RGB565BE, row-major). Valid after display_init(). */
uint16_t *display_fb(void);

void display_lock(void);
void display_unlock(void);

/* Push the whole framebuffer / a rectangle to the panel. Blocks until the transfer is complete.
 * Rectangles are widened to even x/y/w/h (RM67162 2-pixel window granularity) and clipped. */
esp_err_t display_flush_full(void);
esp_err_t display_flush_rect(int x, int y, int w, int h);

/* Band rendering: draw full-width rows [y, y + h) (widened to even rows, clipped) straight into the internal DMA
 * bounce buffers, CONFIG_HAIRCLIP_LCD_BOUNCE_ROWS rows at a time: fn(px, band_y, rows, arg) must write every pixel of
 * px (RGB565BE, DISPLAY_W per row, row 0 = panel row band_y). Band n + 1 is drawn while band n is on the wire, so a
 * frame costs about max(draw, transfer) instead of draw + copy + transfer. keep_fb also copies each band into the
 * framebuffer (screenshots, later display_flush_rect calls). Overlays are patched in as by the flushes. Blocks until
 * the last band is sent; takes the display lock. Headless: the bands are drawn into the framebuffer only. */
typedef void (*display_rows_fn_t)(uint16_t *px, int band_y, int rows, void *arg);
esp_err_t display_render_rows(int y, int h, display_rows_fn_t fn, void *arg, bool keep_fb);

/* Perceptual brightness 0..255 (gamma-mapped onto the 0x51 register). While the panel is off
 * the value is only recorded; display_on() always restarts at 0. */
esp_err_t display_set_brightness(uint8_t level);
uint8_t display_get_brightness(void);

/* Ramp brightness from the current level to `level` over `ms` milliseconds (blocking). */
esp_err_t display_fade_to(uint8_t level, uint32_t ms);

/* display_off(): brightness 0, DISPOFF (0x28) and SLPIN (0x10). Sleep-in makes the panel drop
 * OL_EN, which disables the TPS65137 ELVDD/ELVSS boost, so the panel really stops drawing power.
 * display_on(): SLPOUT (0x11) + 120 ms, DISPON (0x29), brightness stays 0 — the caller flushes
 * fresh content and then fades in. */
esp_err_t display_off(void);
esp_err_t display_on(void);
bool display_is_on(void);

/* Exclude the QSPI bus + reset pins from the light-sleep GPIO isolation (CONFIG_PM_SLP_DISABLE_GPIO) so the
 * panel never sees a floating bus while it holds the image. Done at init; idempotent, re-applied after every
 * WiFi session (README "Light sleep on battery"). */
void display_sleep_pins_apply(void);

/* 180° rotation of the whole picture (PROTOCOL §4 "Orientation") by the panel itself: MADCTL MX+MY
 * (0xF0 -> 0x30) plus the matching window offset, then the framebuffer is re-sent once so the picture
 * turns over at once. The framebuffer stays upright (screenshots are never flipped) and no flush pays
 * anything for it. Takes display_lock, so it lands between two flushes. With the panel off the register is
 * written at the next display_on(). */
esp_err_t display_set_flipped(bool flipped);
bool display_is_flipped(void);

/* Duration of the most recent full-frame flush in microseconds (0 = none yet). */
uint32_t display_last_full_flush_us(void);

/* Overlay sprite (at most DISPLAY_OVERLAY_MAX x DISPLAY_OVERLAY_MAX px, used for the upload-session
 * connection dot): composited into the bounce buffers of every flush that covers it, so it stays on
 * top of whatever the player draws without ever being written into the framebuffer (GET /screenshot
 * keeps returning the content). `px` = w*h RGB565BE pixels, `mask` = w*h bytes (0 = transparent).
 * The covered rectangle is re-flushed at once while the panel is on. display_overlay_clear() removes
 * it (and re-flushes the plain framebuffer there). Both take display_lock. */
#define DISPLAY_OVERLAY_MAX 8
esp_err_t display_overlay_set(int x, int y, int w, int h, const uint16_t *px, const uint8_t *mask);
void display_overlay_clear(void);

/* Several independent overlays (slot 0 = the session dot above; slot 1 = the bench heartbeat dot,
 * CONFIG_PIXELCLIP_BENCH_SLEEP_TEST). Same rules as display_overlay_set / _clear. */
#define DISPLAY_OVERLAY_SLOTS 2
esp_err_t display_overlay_slot_set(int slot, int x, int y, int w, int h, const uint16_t *px, const uint8_t *mask);
void display_overlay_slot_clear(int slot);

/* Called (outside the display lock) after the panel is switched on (true) or off (false): the app holds off
 * automatic light sleep while the panel is on (README "Light sleep on battery", 2026-10-17). */
typedef void (*display_power_cb_t)(bool on);
void display_set_power_cb(display_power_cb_t cb);

#ifdef __cplusplus
}
#endif
