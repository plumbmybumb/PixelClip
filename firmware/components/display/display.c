/* display.c — RM67162 AMOLED over QSPI using the esp_lcd_sh8601 driver (Waveshare init table).
 *
 * Flush strategy: the 257 KB framebuffer lives in PSRAM. The ESP32-S3 SPI master can only DMA from
 * internal RAM (it would otherwise malloc a temporary internal copy of every transaction), so we
 * flush through two internal DMA "bounce" buffers of CONFIG_PIXELCLIP_LCD_BOUNCE_ROWS rows each,
 * ping-ponging: the memcpy of band n+1 overlaps the DMA transfer of band n.
 */
#include "display.h"

#include <string.h>
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_sh8601.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_ipc.h"
#include "esp_log.h"
#include "esp_check.h"
#include "sdkconfig.h"

static const char *TAG = "display";

/* Pin map (schematic + Waveshare demo): QSPI SCL=47, D0=18 (RD_SDI), D1=7 (DCX_RS), D2=48 (DB0),
 * D3=5 (DB1), CS=6, RST=17 (via R13). TE is on GPIO9 but shared with the SD card CS; unused. */
#define PIN_LCD_CS   6
#define PIN_LCD_PCLK 47
#define PIN_LCD_D0   18
#define PIN_LCD_D1   7
#define PIN_LCD_D2   48
#define PIN_LCD_D3   5
#define PIN_LCD_RST  17
#define LCD_HOST     SPI2_HOST
#define LCD_ISR_CORE 0   /* the core the SPI interrupt is put on (panel_init); bus_settle() relies on it */
/* Panel enable (CONFIG_PIXELCLIP_LCD_EN_GPIO): -1 on the Waveshare board; GPIO38 on the LilyGo T-Display-S3
 * AMOLED V2, which must be high before the panel is reset. */
#define PIN_LCD_EN   CONFIG_PIXELCLIP_LCD_EN_GPIO

#define LCD_OPCODE_WRITE_CMD 0x02
#define LCD_CMD_BRIGHTNESS   0x51
#define LCD_CMD_DISPOFF      0x28
#define LCD_CMD_DISPON       0x29
#define LCD_CMD_SLPIN        0x10
#define LCD_CMD_SLPOUT       0x11
#define LCD_CMD_MADCTL       0x36

/* MADCTL (0x36) bits: 7 MY (row address order), 6 MX (column address order), 5 MV (row/column exchange),
 * 4 ML (vertical refresh order), 3 RGB/BGR. The Waveshare init value 0xF0 = MY|MX|MV|ML is the upright
 * 536x240 landscape. A 180° rotation mirrors both axes, i.e. toggles MX and MY: 0xF0 ^ 0xC0 = 0x30
 * (MV|ML). ML only changes the panel's refresh direction (no visible effect without TE sync): kept.
 * MX/MY act on the MCU -> GRAM write addressing, so the picture already in GRAM only turns over when it is
 * written again: display_set_flipped() re-sends the whole framebuffer right after the register write.
 * (If this controller applied them on readout instead, the re-send would still be correct: one mirror.) */
#define MADCTL_NORMAL        CONFIG_PIXELCLIP_LCD_MADCTL   /* 0xF0 on the Waveshare board (Kconfig) */
#define MADCTL_FLIP_BITS     0xC0          /* MY | MX */
#define MADCTL_FLIPPED       (MADCTL_NORMAL ^ MADCTL_FLIP_BITS)

/* Window offset (CASET/RASET gap, added by the sh8601 driver to every draw_bitmap window) in each
 * orientation, in the landscape frame: X = column (0..535, long edge), Y = row (0..239).
 * Why 0 in both: the RM67162's GRAM is exactly the 240x536 panel (the init sequence's CASET 0..535 /
 * RASET 0..239 window covers it with no gap, and neither the Waveshare demo nor LilyGo's driver for the same
 * 1.91" RM67162 panel uses an offset in any rotation), so mirroring an axis maps 0..535 onto 535..0 of the
 * same range and nothing shifts. A GRAM larger than the glass (the ST7789 240x240-in-240x320 case) would
 * show up as the image shifted by (GRAM - glass) px on the long and/or short edge only when flipped, with a
 * band of stale pixels on the opposite edge: put that N here (X for a shift along the long edge, Y along the
 * short one). Keep the values even: the RM67162 window needs even starts / odd ends (2-px granularity), and
 * both the panel size and every flushed window are even, so an even gap keeps that parity. */
#define FLIP_GAP_X           0
#define FLIP_GAP_Y           0
#define NORMAL_GAP_X         0
#define NORMAL_GAP_Y         0

/* Band height must be even: the RM67162 window (CASET/RASET) needs even start / odd end rows and
 * columns (the Waveshare demo's LVGL rounder enforces the same). 24 rows -> 10 bands per frame. */
#define BOUNCE_ROWS  (CONFIG_PIXELCLIP_LCD_BOUNCE_ROWS & ~1)
#define BOUNCE_BYTES (DISPLAY_W * BOUNCE_ROWS * 2)

/* RM67162 init sequence from the Waveshare demo (example_qspi_with_ram.c), byte for byte, except
 * that the demo's final {0x51, 0xFF} (full brightness) is dropped: we start dark and the player fades
 * in after the first frame is in GRAM. MADCTL 0xF0 gives the 536x240 landscape orientation. */
static const sh8601_lcd_init_cmd_t s_init_cmds[] = {
    {0x11, (uint8_t[]){0x00}, 0, 120},             /* sleep out */
    {0x36, (uint8_t[]){MADCTL_NORMAL}, 1, 0},      /* MADCTL (CONFIG_PIXELCLIP_LCD_MADCTL) */
    {0x3A, (uint8_t[]){0x55}, 1, 0},               /* 16-bit RGB565 */
    {0x2A, (uint8_t[]){0x00, 0x00, 0x02, 0x17}, 4, 0}, /* CASET 0..535 */
    {0x2B, (uint8_t[]){0x00, 0x00, 0x00, 0xEF}, 4, 0}, /* RASET 0..239 */
    {0x51, (uint8_t[]){0x00}, 1, 10},              /* brightness 0 */
    {0x29, (uint8_t[]){0x00}, 0, 10},              /* display on */
};

static esp_lcd_panel_io_handle_t s_io;
static esp_lcd_panel_handle_t s_panel;
static uint16_t *s_fb;
static uint8_t *s_bounce[2];
static SemaphoreHandle_t s_lock;       /* recursive: fb + panel ownership */
static SemaphoreHandle_t s_done;       /* counting: one give per completed band transfer */
static uint8_t s_brightness;           /* perceptual level last requested */
static uint8_t s_gamma[256];
static bool s_on;
static bool s_panel_ok;                /* false: headless (panel init failed), fb still valid */
static uint32_t s_last_full_us;
static bool s_flipped;                 /* 180° (MADCTL_FLIPPED): what display_is_flipped() reports */
static bool s_madctl_stale;            /* s_flipped changed while the panel was off: send at display_on() */
typedef struct {
    bool on;
    int x, y, w, h;
    uint16_t px[DISPLAY_OVERLAY_MAX * DISPLAY_OVERLAY_MAX];
    uint8_t mask[DISPLAY_OVERLAY_MAX * DISPLAY_OVERLAY_MAX];
} overlay_t;
static overlay_t s_ovls[DISPLAY_OVERLAY_SLOTS]; /* written under s_lock, read by flush_region (also under it) */

#if CONFIG_PIXELCLIP_BENCH_LCD_RACE
#include "esp_rom_sys.h"
/* Bench only (main/bench.c, display bus stress): a busy-wait before every band after the first, so the
 * request for the bus can be placed at any moment of the previous band's transfer. Set under display_lock(). */
volatile uint32_t g_display_bench_gap_us;
#endif

static bool IRAM_ATTR on_color_done(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *e, void *ctx)
{
    BaseType_t woken = pdFALSE;
    xSemaphoreGiveFromISR(s_done, &woken);
    /* esp_lcd's SPI io drops this return value (lcd_spi_post_trans_color_cb), so the task waiting in
     * display_render_rows() / flush_region() ran only at the next tick: up to 1 ms per present (2026-11-10, measured on
     * partial redraws) */
    if (woken == pdTRUE && xPortInIsrContext()) portYIELD_FROM_ISR();
    return woken == pdTRUE;
}

#if !CONFIG_FREERTOS_UNICORE
static void settle_nop(void *arg) { (void)arg; }
#endif

/* Returns once the SPI interrupt that reported a finished colour transfer has returned.
 *
 * Why (2026-11-15, the freeze that ended in an RTC watchdog reset, reproduced in seconds by
 * CONFIG_PIXELCLIP_BENCH_LCD_RACE): ESP-IDF 5.5.0's SPI bus lock can lose the hand-over of the bus. When the
 * interrupt finds its queue empty it decides nobody is waiting, then clears its "busy" bit and leaves. A task on
 * the other core that asks for the bus (spi_device_acquire_bus, the first thing every esp_lcd call does)
 * inside those few instructions still sees "busy", waits for the interrupt to hand the bus over, and is
 * never woken: the wait has no timeout. So this driver never asks for the bus while that interrupt may be
 * finishing: every colour transfer is waited for (s_done, given inside the interrupt), then this function makes
 * sure the interrupt is over, and only then comes the next esp_lcd call. With the bus idle the request
 * succeeds at once and needs no hand-over.
 *
 * A task that runs on the interrupt's core after s_done was given is proof enough (the interrupt cannot be
 * in progress there); from the other core a blocking call to that core's IPC task is: that task only runs
 * once the interrupt has returned. */
static void bus_settle(void)
{
#if !CONFIG_FREERTOS_UNICORE
    if (xPortGetCoreID() != LCD_ISR_CORE) esp_ipc_call_blocking(LCD_ISR_CORE, settle_nop, NULL);
#endif
}

/* Wait for the band on the wire, then for its interrupt (bus_settle). Call with the display lock held. */
static esp_err_t band_wait(const char *what)
{
    if (xSemaphoreTake(s_done, pdMS_TO_TICKS(500)) != pdTRUE) {
        ESP_LOGE(TAG, "%s timeout", what);
        return ESP_ERR_TIMEOUT;
    }
    bus_settle();
    return ESP_OK;
}

static esp_err_t tx_cmd(uint8_t cmd, const void *param, size_t len)
{
    if (!s_panel_ok) return ESP_ERR_INVALID_STATE;
    int lcd_cmd = (LCD_OPCODE_WRITE_CMD << 24) | ((int)cmd << 8);
    return esp_lcd_panel_io_tx_param(s_io, lcd_cmd, param, len);
}

static esp_err_t write_orientation(void);

void display_lock(void)   { xSemaphoreTakeRecursive(s_lock, portMAX_DELAY); }
void display_unlock(void) { xSemaphoreGiveRecursive(s_lock); }
uint16_t *display_fb(void) { return s_fb; }
bool display_is_on(void) { return s_on; }
uint8_t display_get_brightness(void) { return s_brightness; }
uint32_t display_last_full_flush_us(void) { return s_last_full_us; }
bool display_is_flipped(void) { return s_flipped; }

/* CONFIG_PM_SLP_DISABLE_GPIO (and the S3 sleep-GPIO workaround) isolate every GPIO during automatic
 * light sleep: outputs float, pulls are removed. The panel keeps showing GRAM while we sleep, so a
 * floating CS/CLK/data bus could clock garbage (or a stray SLPIN) into it. Keep the bus pins in their
 * normal (driven) configuration during sleep. RST has an external 10k pull-up but is kept too. */
void display_sleep_pins_apply(void)
{
    static const int pins[] = { PIN_LCD_CS, PIN_LCD_PCLK, PIN_LCD_D0, PIN_LCD_D1, PIN_LCD_D2, PIN_LCD_D3, PIN_LCD_RST };
    for (size_t i = 0; i < sizeof pins / sizeof pins[0]; i++) {
        esp_err_t err = gpio_sleep_sel_dis((gpio_num_t)pins[i]);
        if (err != ESP_OK) ESP_LOGW(TAG, "gpio_sleep_sel_dis(%d): %s", pins[i], esp_err_to_name(err));
    }
#if CONFIG_PIXELCLIP_LCD_EN_GPIO >= 0
    esp_err_t err = gpio_sleep_sel_dis((gpio_num_t)PIN_LCD_EN);   /* the enable must not float in light sleep */
    if (err != ESP_OK) ESP_LOGW(TAG, "gpio_sleep_sel_dis(%d): %s", PIN_LCD_EN, esp_err_to_name(err));
#endif
}

static esp_err_t panel_init(void)
{
#if CONFIG_PIXELCLIP_LCD_EN_GPIO >= 0
    /* Panel enable first (LilyGo V2: GPIO38): the panel only answers once it is powered. */
    const gpio_config_t en = { .pin_bit_mask = 1ULL << PIN_LCD_EN, .mode = GPIO_MODE_OUTPUT };
    ESP_RETURN_ON_ERROR(gpio_config(&en), TAG, "enable gpio");
    ESP_RETURN_ON_ERROR(gpio_set_level((gpio_num_t)PIN_LCD_EN, 1), TAG, "enable high");
    vTaskDelay(pdMS_TO_TICKS(20));
#endif
    spi_bus_config_t bus = SH8601_PANEL_BUS_QSPI_CONFIG(PIN_LCD_PCLK, PIN_LCD_D0, PIN_LCD_D1,
                                                        PIN_LCD_D2, PIN_LCD_D3, BOUNCE_BYTES);
    bus.isr_cpu_id = ESP_INTR_CPU_AFFINITY_0;   /* LCD_ISR_CORE: bus_settle() must know where the interrupt runs */
    /* Demo uses max_transfer_sz = whole frame; we never send more than one band per transaction. */
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_HOST, &bus, SPI_DMA_CH_AUTO), TAG, "spi bus init");

    /* Demo: SH8601_PANEL_IO_QSPI_CONFIG = cs 6, dc -1, mode 0, 40 MHz, cmd 32 bit, param 8 bit,
     * quad_mode. Only the queue depth differs (4 vs 10): we never queue more than one colour
     * transaction, because every tx_param drains the queue first. */
    esp_lcd_panel_io_spi_config_t io_cfg = SH8601_PANEL_IO_QSPI_CONFIG(PIN_LCD_CS, on_color_done, NULL);
    io_cfg.pclk_hz = CONFIG_PIXELCLIP_LCD_PCLK_MHZ * 1000 * 1000;
    io_cfg.trans_queue_depth = 4;
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_cfg, &s_io),
                        TAG, "panel io");

    sh8601_vendor_config_t vendor = {
        .init_cmds = s_init_cmds,
        .init_cmds_size = sizeof(s_init_cmds) / sizeof(s_init_cmds[0]),
        .flags = { .use_qspi_interface = 1 },
    };
    /* Reset: GPIO17 active low (reset_active_high = 0), 10 ms low then 150 ms, as in the demo. */
    const esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = PIN_LCD_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
        .vendor_config = &vendor,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_sh8601(s_io, &panel_cfg, &s_panel), TAG, "new panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(s_panel), TAG, "panel reset");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(s_panel), TAG, "panel init");
    /* No esp_lcd_panel_mirror()/swap_xy(): the 0x36 = 0xF0 entry above already sets the landscape
     * orientation (the driver adopts it as its MADCTL value), and mirror(true,false) would only
     * re-send the same 0xF0. Native byte order: the SPI master sends buffer bytes in memory order,
     * MSB first, so big-endian RGB565 in RAM reaches the panel as RRRRRGGG GGGBBBBB — the same as
     * the demo's LVGL build (CONFIG_LV_COLOR_16_SWAP=y). No swap anywhere. */
    display_sleep_pins_apply();
    return ESP_OK;
}

esp_err_t display_init(void)
{
    s_lock = xSemaphoreCreateRecursiveMutex();
    s_done = xSemaphoreCreateCounting(64, 0);
    ESP_RETURN_ON_FALSE(s_lock && s_done, ESP_ERR_NO_MEM, TAG, "no mem for semaphores");

    /* Perceptual curve: gamma 2.2, but keep every non-zero level visible. */
    for (int i = 0; i < 256; i++) {
        int v = (int)lroundf(255.0f * powf(i / 255.0f, 2.2f));
        if (i > 0 && v < 1) v = 1;
        s_gamma[i] = (uint8_t)v;
    }

    /* Framebuffer in PSRAM: never handed to DMA, only memcpy'd into the internal bounce buffers. */
    s_fb = heap_caps_aligned_alloc(64, DISPLAY_FB_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    ESP_RETURN_ON_FALSE(s_fb, ESP_ERR_NO_MEM, TAG, "framebuffer alloc failed");
    memset(s_fb, 0, DISPLAY_FB_BYTES);
    for (int i = 0; i < 2; i++) {
        s_bounce[i] = heap_caps_aligned_alloc(4, BOUNCE_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
        ESP_RETURN_ON_FALSE(s_bounce[i], ESP_ERR_NO_MEM, TAG, "bounce buffer alloc failed");
    }

    /* From here on a failure leaves the framebuffer usable (screenshots, WiFi still work) and the
     * panel calls become no-ops, so a dead/missing panel never takes the rest of the clip down. */
    esp_err_t err = panel_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "panel bring-up failed (%s): running headless", esp_err_to_name(err));
        return err;
    }
    s_panel_ok = true;
    s_on = true;
    s_brightness = 0;

    err = display_flush_full();
    ESP_LOGI(TAG, "AMOLED %dx%d up, QSPI %d MHz, bounce %d rows x2 (%d B internal), full flush %lu us",
             DISPLAY_W, DISPLAY_H, CONFIG_PIXELCLIP_LCD_PCLK_MHZ, BOUNCE_ROWS, 2 * BOUNCE_BYTES,
             (unsigned long)s_last_full_us);
    if (err != ESP_OK) ESP_LOGE(TAG, "initial flush: %s", esp_err_to_name(err));
    return err;
}

/* Paint the overlay sprites over the part of a bounce band [x, x+w) x [band_y, band_y+rows) they cover. */
static void overlay_patch(uint8_t *dst, int x, int band_y, int w, int rows)
{
    for (int k = 0; k < DISPLAY_OVERLAY_SLOTS; k++) {
        const overlay_t *o = &s_ovls[k];
        if (!o->on) continue;
        const int y0 = band_y > o->y ? band_y : o->y;
        const int y1 = band_y + rows < o->y + o->h ? band_y + rows : o->y + o->h;
        const int x0 = x > o->x ? x : o->x;
        const int x1 = x + w < o->x + o->w ? x + w : o->x + o->w;
        if (y0 >= y1 || x0 >= x1) continue;
        uint16_t *d = (uint16_t *)dst;   /* bounce buffers are 4-byte aligned */
        for (int yy = y0; yy < y1; yy++) {
            const int off = (yy - o->y) * o->w;
            for (int xx = x0; xx < x1; xx++) {
                if (o->mask[off + xx - o->x]) d[(yy - band_y) * w + (xx - x)] = o->px[off + xx - o->x];
            }
        }
    }
}

/* Copy rows [y, y+h) x [x, x+w) of the framebuffer to the panel through the bounce buffers. */
static esp_err_t flush_region(int x, int y, int w, int h)
{
    if (!s_panel_ok) return ESP_ERR_INVALID_STATE;
    /* Even band height keeps every band's RASET start even (2-pixel window granularity). */
    const int rows_per_band = (BOUNCE_BYTES / (w * 2)) & ~1;
    const size_t row_bytes = (size_t)w * 2;
    bool on_wire = false;   /* the previous band's transfer has been queued and not yet waited for */
    esp_err_t err = ESP_OK;
    /* A previous flush that timed out may still deliver late "done" gives: drop them so they are
     * not counted against this flush (nothing is in flight here: we hold the lock). */
    while (xSemaphoreTake(s_done, 0) == pdTRUE) {}

    for (int band_y = y, n = 0; band_y < y + h; band_y += rows_per_band, n++) {
        int rows = (y + h) - band_y;
        if (rows > rows_per_band) rows = rows_per_band;
        uint8_t *dst = s_bounce[n & 1];
        /* The buffer we are about to fill was used by band n-2, which is complete: band n-1 was only
         * sent after it (band_wait below). The copy overlaps band n-1's transfer. */
        if (x == 0 && w == DISPLAY_W) {
            memcpy(dst, &s_fb[band_y * DISPLAY_W], row_bytes * rows);
        } else {
            for (int r = 0; r < rows; r++) {
                memcpy(dst + r * row_bytes, &s_fb[(band_y + r) * DISPLAY_W + x], row_bytes);
            }
        }
        overlay_patch(dst, x, band_y, w, rows);
#if CONFIG_PIXELCLIP_BENCH_LCD_RACE
        if (n > 0 && g_display_bench_gap_us) esp_rom_delay_us(g_display_bench_gap_us);
#endif
        /* Never ask for the bus while the previous band's interrupt may be finishing: see bus_settle(). */
        if (on_wire) {
            on_wire = false;
            if (band_wait("flush") != ESP_OK) return ESP_ERR_TIMEOUT;
        }
        err = esp_lcd_panel_draw_bitmap(s_panel, x, band_y, x + w, band_y + rows, dst);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "draw_bitmap failed: %s", esp_err_to_name(err));
            break;
        }
        on_wire = true;
    }
    /* Wait for the last band so the bounce buffers and the bus are free when we return. */
    if (on_wire && band_wait("flush") != ESP_OK) return ESP_ERR_TIMEOUT;
    return err;
}

esp_err_t display_render_rows(int y, int h, display_rows_fn_t fn, void *arg, bool keep_fb)
{
    if (!fn) return ESP_ERR_INVALID_ARG;
    int y0 = y < 0 ? 0 : y, y1 = y + h > DISPLAY_H ? DISPLAY_H : y + h;
    y0 &= ~1;
    y1 = (y1 + 1) & ~1;
    if (y1 <= y0) return ESP_OK;
    const size_t row_bytes = (size_t)DISPLAY_W * 2;
    esp_err_t err = ESP_OK;
    bool on_wire = false;   /* as in flush_region */
    display_lock();
    if (!s_panel_ok) {
        for (int band_y = y0; band_y < y1; band_y += BOUNCE_ROWS) {
            const int rows = y1 - band_y < BOUNCE_ROWS ? y1 - band_y : BOUNCE_ROWS;
            fn(&s_fb[band_y * DISPLAY_W], band_y, rows, arg);
        }
        display_unlock();
        return ESP_ERR_INVALID_STATE;
    }
    while (xSemaphoreTake(s_done, 0) == pdTRUE) {}   /* late gives of a timed-out flush (see flush_region) */
    bool ovl = false;   /* an overlay patches the bounce band: the framebuffer copy is taken before it */
    for (int k = 0; k < DISPLAY_OVERLAY_SLOTS; k++) ovl = ovl || s_ovls[k].on;
    for (int band_y = y0, n = 0; band_y < y1; band_y += BOUNCE_ROWS, n++) {
        const int rows = y1 - band_y < BOUNCE_ROWS ? y1 - band_y : BOUNCE_ROWS;
        uint8_t *dst = s_bounce[n & 1];   /* band n - 2 used it and is complete (flush_region) */
        fn((uint16_t *)dst, band_y, rows, arg);
        if (keep_fb && ovl) memcpy(&s_fb[band_y * DISPLAY_W], dst, row_bytes * rows);
        overlay_patch(dst, 0, band_y, DISPLAY_W, rows);
        /* Never ask for the bus while the previous band's interrupt may be finishing: see bus_settle(). */
        if (on_wire) {
            on_wire = false;
            err = band_wait("render");
            if (err != ESP_OK) break;
        }
        err = esp_lcd_panel_draw_bitmap(s_panel, 0, band_y, DISPLAY_W, band_y + rows, dst);
        /* 2026-11-10: without an overlay the copy runs while the band itself is sent (the DMA only reads dst), not
         * before it: each range's first band reaches the panel about 0.8 ms sooner */
        if (keep_fb && !ovl) memcpy(&s_fb[band_y * DISPLAY_W], dst, row_bytes * rows);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "draw_bitmap failed: %s", esp_err_to_name(err));
            break;
        }
        on_wire = true;
    }
    if (on_wire && band_wait("render") != ESP_OK) err = ESP_ERR_TIMEOUT;
    display_unlock();
    return err;
}

esp_err_t display_flush_full(void)
{
    display_lock();
    int64_t t0 = esp_timer_get_time();
    esp_err_t err = flush_region(0, 0, DISPLAY_W, DISPLAY_H);
    s_last_full_us = (uint32_t)(esp_timer_get_time() - t0);
    display_unlock();
    return err;
}

esp_err_t display_flush_rect(int x, int y, int w, int h)
{
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + w > DISPLAY_W ? DISPLAY_W : x + w;
    int y1 = y + h > DISPLAY_H ? DISPLAY_H : y + h;
    if (x1 <= x0 || y1 <= y0) return ESP_OK;
    x0 &= ~1; y0 &= ~1;                 /* start on even pixel */
    x1 = (x1 + 1) & ~1; y1 = (y1 + 1) & ~1; /* end exclusive on even pixel (DISPLAY_W/H are even) */
    display_lock();
    esp_err_t err = flush_region(x0, y0, x1 - x0, y1 - y0);
    display_unlock();
    return err;
}

static esp_err_t write_brightness_raw(uint8_t level)
{
    uint8_t raw = s_gamma[level];
    return tx_cmd(LCD_CMD_BRIGHTNESS, &raw, 1);
}

esp_err_t display_set_brightness(uint8_t level)
{
    display_lock();
    s_brightness = level;
    esp_err_t err = s_on ? write_brightness_raw(level) : ESP_OK;
    display_unlock();
    if (err != ESP_OK) ESP_LOGE(TAG, "brightness: %s", esp_err_to_name(err));
    return err;
}

esp_err_t display_fade_to(uint8_t level, uint32_t ms)
{
    const uint32_t step_ms = 15;
    uint8_t from = s_brightness;
    if (!s_on || ms < step_ms || from == level) return display_set_brightness(level);
    uint32_t steps = ms / step_ms;
    TickType_t last = xTaskGetTickCount();
    for (uint32_t i = 1; i <= steps; i++) {
        int v = from + ((int)level - (int)from) * (int)i / (int)steps;
        esp_err_t err = display_set_brightness((uint8_t)v);
        if (err != ESP_OK) return err;
        vTaskDelayUntil(&last, pdMS_TO_TICKS(step_ms));
    }
    return ESP_OK;
}

static display_power_cb_t s_power_cb;
void display_set_power_cb(display_power_cb_t cb) { s_power_cb = cb; }

esp_err_t display_off(void)
{
    display_lock();
    esp_err_t err = ESP_OK;
    bool changed = false;
    if (s_on) {
        uint8_t zero = 0;
        err = tx_cmd(LCD_CMD_BRIGHTNESS, &zero, 1);
        if (err == ESP_OK) err = tx_cmd(LCD_CMD_DISPOFF, NULL, 0);
        if (err == ESP_OK) err = tx_cmd(LCD_CMD_SLPIN, NULL, 0);
        if (err == ESP_OK) {
            vTaskDelay(pdMS_TO_TICKS(120)); /* SLPIN -> SLPOUT needs 120 ms; also lets the boost settle */
            s_on = false;
            changed = true;
            ESP_LOGI(TAG, "panel off (sleep-in)");
        }
    }
    display_unlock();
    if (changed && s_power_cb) s_power_cb(false);
    if (err != ESP_OK) ESP_LOGE(TAG, "display_off: %s", esp_err_to_name(err));
    return err;
}

esp_err_t display_on(void)
{
    display_lock();
    esp_err_t err = ESP_OK;
    bool changed = false;
    if (!s_on && s_panel_ok) {
        uint8_t zero = 0;
        err = tx_cmd(LCD_CMD_SLPOUT, NULL, 0);
        if (err == ESP_OK) vTaskDelay(pdMS_TO_TICKS(120));
        if (err == ESP_OK && s_madctl_stale) err = write_orientation();   /* flipped while off */
        if (err == ESP_OK) err = tx_cmd(LCD_CMD_BRIGHTNESS, &zero, 1);
        if (err == ESP_OK) err = tx_cmd(LCD_CMD_DISPON, NULL, 0);
        if (err == ESP_OK) {
            s_on = true;
            s_brightness = 0;
            changed = true;
            ESP_LOGI(TAG, "panel on (sleep-out)");
        }
    }
    display_unlock();
    if (changed && s_power_cb) s_power_cb(true);
    if (err != ESP_OK) ESP_LOGE(TAG, "display_on: %s", esp_err_to_name(err));
    return err;
}

/* MADCTL + window gap for s_flipped (caller holds the lock; the GRAM content is not rewritten). */
static esp_err_t write_orientation(void)
{
    const uint8_t madctl = s_flipped ? MADCTL_FLIPPED : MADCTL_NORMAL;
    esp_err_t err = tx_cmd(LCD_CMD_MADCTL, &madctl, 1);
    if (err == ESP_OK) {
        err = esp_lcd_panel_set_gap(s_panel, s_flipped ? FLIP_GAP_X : NORMAL_GAP_X, s_flipped ? FLIP_GAP_Y : NORMAL_GAP_Y);
    }
    if (err == ESP_OK) s_madctl_stale = false;
    return err;
}

esp_err_t display_set_flipped(bool flipped)
{
    display_lock();
    esp_err_t err = ESP_OK;
    if (flipped != s_flipped) {
        s_flipped = flipped;
        s_madctl_stale = true;
        /* Between frames: we hold the lock, so no flush is in flight. While the panel is asleep (or absent)
         * the register is written at display_on(), before anything is drawn. */
        if (s_panel_ok && s_on) {
            err = write_orientation();
            if (err == ESP_OK) err = flush_region(0, 0, DISPLAY_W, DISPLAY_H);   /* turn the picture over */
        }
    }
    display_unlock();
    if (err != ESP_OK) ESP_LOGE(TAG, "set_flipped(%d): %s", flipped, esp_err_to_name(err));
    return err;
}

esp_err_t display_overlay_slot_set(int slot, int x, int y, int w, int h, const uint16_t *px, const uint8_t *mask)
{
    if (slot < 0 || slot >= DISPLAY_OVERLAY_SLOTS) return ESP_ERR_INVALID_ARG;
    if (!px || !mask) {
        display_overlay_slot_clear(slot);
        return ESP_OK;
    }
    if (w <= 0 || h <= 0 || w > DISPLAY_OVERLAY_MAX || h > DISPLAY_OVERLAY_MAX || x < 0 || y < 0 ||
        x + w > DISPLAY_W || y + h > DISPLAY_H) {
        return ESP_ERR_INVALID_ARG;
    }
    overlay_t *o = &s_ovls[slot];
    display_lock();
    const bool moved = o->on && (o->x != x || o->y != y || o->w != w || o->h != h);
    if (moved) {
        o->on = false;
        if (s_on) display_flush_rect(o->x, o->y, o->w, o->h);
    }
    o->x = x;
    o->y = y;
    o->w = w;
    o->h = h;
    memcpy(o->px, px, (size_t)w * h * sizeof px[0]);
    memcpy(o->mask, mask, (size_t)w * h);
    o->on = true;
    esp_err_t err = s_on ? display_flush_rect(x, y, w, h) : ESP_OK;
    display_unlock();
    return err;
}

void display_overlay_slot_clear(int slot)
{
    if (slot < 0 || slot >= DISPLAY_OVERLAY_SLOTS) return;
    overlay_t *o = &s_ovls[slot];
    display_lock();
    if (o->on) {
        o->on = false;
        if (s_on) display_flush_rect(o->x, o->y, o->w, o->h);
    }
    display_unlock();
}

esp_err_t display_overlay_set(int x, int y, int w, int h, const uint16_t *px, const uint8_t *mask)
{
    return display_overlay_slot_set(0, x, y, w, h, px, mask);
}

void display_overlay_clear(void) { display_overlay_slot_clear(0); }
