/* ui.c — tiny framebuffer drawing helpers for system screens. */
#include "ui.h"
#include <string.h>
#include "display.h"
#include "hca.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

_Static_assert(UI_ACCENT == DISPLAY_RGB565BE(198, 162, 255), "UI_ACCENT must be soft violet #C6A2FF");

extern const uint8_t ui_font5x7[95][5]; /* font5x7.c: ASCII 0x20..0x7E, column-major, bit0 = top */

void ui_fill_rect(int x, int y, int w, int h, uint16_t color)
{
    uint16_t *fb = display_fb();
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + w > DISPLAY_W ? DISPLAY_W : x + w;
    int y1 = y + h > DISPLAY_H ? DISPLAY_H : y + h;
    for (int yy = y0; yy < y1; yy++) {
        uint16_t *row = &fb[yy * DISPLAY_W];
        for (int xx = x0; xx < x1; xx++) row[xx] = color;
    }
}

void ui_clear(uint16_t color)
{
    if (color == 0) {
        memset(display_fb(), 0, DISPLAY_FB_BYTES);
    } else {
        ui_fill_rect(0, 0, DISPLAY_W, DISPLAY_H, color);
    }
}

static void draw_char(int x, int y, int scale, uint16_t color, char c)
{
    if (c < 0x20 || c > 0x7E) c = '?';
    const uint8_t *g = ui_font5x7[c - 0x20];
    for (int col = 0; col < 5; col++) {
        for (int row = 0; row < 7; row++) {
            if (g[col] & (1u << row)) ui_fill_rect(x + col * scale, y + row * scale, scale, scale, color);
        }
    }
}

int ui_text_width(int scale, const char *s)
{
    int n = (int)strlen(s);
    return n == 0 ? 0 : (n * 6 - 1) * scale;
}

void ui_text(int x, int y, int scale, uint16_t color, const char *s)
{
    for (; *s; s++, x += 6 * scale) draw_char(x, y, scale, color, *s);
}

void ui_text_centered(int y, int scale, uint16_t color, const char *s)
{
    ui_text((DISPLAY_W - ui_text_width(scale, s)) / 2, y, scale, color, s);
}

void ui_sparkle(int cx, int cy, int r, uint16_t color)
{
    /* Concave four-point star: each row's half-width shrinks quadratically toward the tips. */
    for (int dy = -r; dy <= r; dy++) {
        int ady = dy < 0 ? -dy : dy;
        int t = r - ady;                  /* 0 at the tips, r at the centre */
        int half = (t * t) / (r > 0 ? r : 1) / 3;
        ui_fill_rect(cx - half, cy + dy, 2 * half + 1, 1, color);
    }
    for (int dx = -r; dx <= r; dx++) {
        int adx = dx < 0 ? -dx : dx;
        int t = r - adx;
        int half = (t * t) / (r > 0 ? r : 1) / 3;
        ui_fill_rect(cx + dx, cy - half, 1, 2 * half + 1, color);
    }
}

void ui_screen_message(const char *line1, const char *line2, uint16_t color)
{
    ui_clear(0);
    const int scale1 = ui_text_width(4, line1) <= DISPLAY_W - 16 ? 4 : 3;
    if (line2) {
        ui_text_centered(70, scale1, color, line1);
        const int scale2 = ui_text_width(3, line2) <= DISPLAY_W - 16 ? 3 : 2;
        ui_text_centered(70 + 7 * scale1 + 24, scale2, DISPLAY_RGB565BE(160, 160, 160), line2);
    } else {
        ui_text_centered((DISPLAY_H - 7 * scale1) / 2, scale1, color, line1);
    }
}

void ui_screen_idle(void)
{
    const char *msg = "Send me something";
    const int scale = 3;
    const int w = ui_text_width(scale, msg);
    const int gap = 18, star_r = 14;
    const int total = w + gap + 2 * star_r;
    const int x = (DISPLAY_W - total) / 2;
    const int y = (DISPLAY_H - 7 * scale) / 2;
    ui_clear(0);
    ui_text(x, y, scale, DISPLAY_RGB565BE(200, 200, 210), msg);
    ui_sparkle(x + w + gap + star_r, y + (7 * scale) / 2, star_r, UI_ACCENT);
}

#if UI_HAVE_SPLASH
extern const uint8_t splash_hca_start[] asm("_binary_splash_hca_start");
extern const uint8_t splash_hca_end[] asm("_binary_splash_hca_end");
#endif

bool ui_show_embedded_splash(uint8_t brightness)
{
#if UI_HAVE_SPLASH
    static const char *TAG = "splash";
    const size_t size = (size_t)(splash_hca_end - splash_hca_start);
    hca_asset_t a;
    hca_status_t st = hca_open(&a, splash_hca_start, size);
    if (st != HCA_OK || a.hdr.data_size != size || a.hdr.width != DISPLAY_W || a.hdr.height != DISPLAY_H ||
        (a.hdr.flags & HCA_FLAG_GLYPH_ATLAS)) {
        ESP_LOGW(TAG, "embedded splash.hca unusable (%s, %ux%u): skipped", hca_status_str(st), a.hdr.width, a.hdr.height);
        return false;
    }
    if (brightness < 40) brightness = 40;
    const TickType_t t0 = xTaskGetTickCount();
    const uint16_t frames = a.hdr.frame_count;
    for (uint16_t f = 0; f < frames; f++) {
        display_lock();
        st = hca_decode_frame(&a, f, display_fb(), DISPLAY_W);
        esp_err_t err = st == HCA_OK ? display_flush_full() : ESP_FAIL;
        display_unlock();
        if (st != HCA_OK || err != ESP_OK) {
            ESP_LOGW(TAG, "frame %u: %s", f, st != HCA_OK ? hca_status_str(st) : esp_err_to_name(err));
            break;
        }
        if (f == 0) display_fade_to(brightness, DISPLAY_FADE_MS);
        uint32_t ms = hca_frame_duration(&a, f, 100);
        if (frames == 1 && ms < 1200) ms = 1200;   /* a still splash stays up long enough to see */
        vTaskDelay(pdMS_TO_TICKS(ms));
        if ((xTaskGetTickCount() - t0) * portTICK_PERIOD_MS >= UI_SPLASH_MAX_MS) break;
    }
    display_fade_to(0, DISPLAY_FADE_MS);
    ESP_LOGI(TAG, "%u frame(s), %u B, %lu ms", frames, (unsigned)size,
             (unsigned long)((xTaskGetTickCount() - t0) * portTICK_PERIOD_MS));
    return true;
#else
    return false;
#endif
}
