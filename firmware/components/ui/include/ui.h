/* ui.h — minimal built-in drawing (5x7 bitmap font, sparkle glyph) for system screens.
 * All functions draw into the display framebuffer only; the caller holds display_lock() and
 * flushes. Colours are RGB565BE (see DISPLAY_RGB565BE). */
#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Brand accent for the system screens: soft violet #C6A2FF (RGB565 0xC51F),
 * byte-swapped like every framebuffer colour, i.e. DISPLAY_RGB565BE(198, 162, 255). Callers pass it
 * as `color` wherever a system screen should carry the brand colour. */
#define UI_ACCENT ((uint16_t)0x1FC5)

void ui_clear(uint16_t color);
void ui_fill_rect(int x, int y, int w, int h, uint16_t color);
/* ASCII text, `scale` x scale pixels per font dot. Unknown chars render as '?'. */
void ui_text(int x, int y, int scale, uint16_t color, const char *s);
int  ui_text_width(int scale, const char *s);
void ui_text_centered(int y, int scale, uint16_t color, const char *s);
/* Four-point sparkle centred at (cx, cy) with arm length r. */
void ui_sparkle(int cx, int cy, int r, uint16_t color);

/* Full system screens: black background, one or two centred lines (line2 may be NULL). */
void ui_screen_message(const char *line1, const char *line2, uint16_t color);
/* "Send me something" + sparkle: shown when the playlist is empty. */
void ui_screen_idle(void);

/* Boot splash: play the .hca embedded from firmware/main/assets/splash.hca (if it was present at
 * build time): one pass, at most UI_SPLASH_MAX_MS, fading in to `brightness` and back out to 0.
 * Takes display_lock itself (call it before the player owns the panel). Returns false (and draws
 * nothing) when no splash is embedded or it is not a valid 536x240 animation. */
#define UI_SPLASH_MAX_MS 3000
bool ui_show_embedded_splash(uint8_t brightness);

#ifdef __cplusplus
}
#endif
