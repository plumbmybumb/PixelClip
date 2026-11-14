/* button.c — debounced GPIO0 button with short / long / hold detection. */
#include "button.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_check.h"

static const char *TAG = "button";

#define BTN_GPIO        GPIO_NUM_0
#define SAMPLE_MS       10
#define DEBOUNCE_N      3        /* 30 ms stable */
#define BTN_TASK_STACK  3072     /* callback posts to a queue; small */
#define BTN_TASK_PRIO   5

static TaskHandle_t s_task;
static button_cb_t s_cb;
static uint32_t s_hold_ms = BUTTON_HOLD_MS;
static button_held_cb_t s_held_cb;
static button_down_cb_t s_down_cb;     /* button_set_down_cb(): NULL on the clip */
static volatile bool s_swallow;        /* button_swallow_press(): the current press reports nothing */
static button_result_cb_t s_res_cb;    /* button_set_result_cb(): NULL on the clip */

static void result(button_result_t r, uint32_t ms)
{
    if (s_res_cb) s_res_cb(r, ms);
}

void button_set_result_cb(button_result_cb_t cb) { s_res_cb = cb; }

static void IRAM_ATTR isr(void *arg)
{
    gpio_intr_disable(BTN_GPIO);
    BaseType_t woken = pdFALSE;
    vTaskNotifyGiveFromISR(s_task, &woken);
    if (woken) portYIELD_FROM_ISR();
}

bool button_is_pressed(void) { return gpio_get_level(BTN_GPIO) == 0; }

/* Wait until the level has been stable at `pressed` for DEBOUNCE_N samples, or timeout. */
static bool wait_stable(bool pressed, uint32_t timeout_ms)
{
    int stable = 0;
    for (uint32_t t = 0; t <= timeout_ms; t += SAMPLE_MS) {
        stable = (button_is_pressed() == pressed) ? stable + 1 : 0;
        if (stable >= DEBOUNCE_N) return true;
        vTaskDelay(pdMS_TO_TICKS(SAMPLE_MS));
    }
    return false;
}

bool button_wait_release(uint32_t timeout_ms) { return wait_stable(false, timeout_ms); }

static void button_task(void *arg)
{
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        if (!wait_stable(true, 60)) { /* glitch */
            result(BUTTON_RES_GLITCH, 0);
            s_swallow = false;
            gpio_intr_enable(BTN_GPIO);
            continue;
        }
        if (s_down_cb && !s_swallow) s_down_cb();
        int64_t t0 = esp_timer_get_time() - DEBOUNCE_N * SAMPLE_MS * 1000;
        bool hold_sent = false, held_sent = false;
        int released = 0;
        while (released < DEBOUNCE_N) {
            vTaskDelay(pdMS_TO_TICKS(SAMPLE_MS));
            released = button_is_pressed() ? 0 : released + 1;
            uint32_t held_ms = (uint32_t)((esp_timer_get_time() - t0) / 1000);
            if (s_swallow) continue;
            if (!held_sent && !hold_sent && released == 0 && held_ms >= BUTTON_LONG_MIN_MS) {
                held_sent = true;
                result(BUTTON_RES_HELD, held_ms);
                if (s_held_cb) s_held_cb();
            }
            if (!hold_sent && held_ms >= s_hold_ms) {
                hold_sent = true;
                ESP_LOGI(TAG, "hold");
                result(BUTTON_RES_HOLD, held_ms);
                if (s_cb) s_cb(BUTTON_EVT_HOLD);
            }
        }
        uint32_t ms = (uint32_t)((esp_timer_get_time() - t0) / 1000) - DEBOUNCE_N * SAMPLE_MS;
        if (s_swallow) {
            s_swallow = false;
            ESP_LOGI(TAG, "swallowed press (%lu ms)", (unsigned long)ms);
            result(BUTTON_RES_SWALLOWED, ms);
        } else if (!hold_sent) {
            if (ms < BUTTON_SHORT_MAX_MS) {
                ESP_LOGI(TAG, "short press (%lu ms)", (unsigned long)ms);
                result(BUTTON_RES_SHORT, ms);
                if (s_cb) s_cb(BUTTON_EVT_SHORT);
            } else if (ms >= BUTTON_LONG_MIN_MS) {
                ESP_LOGI(TAG, "long press (%lu ms)", (unsigned long)ms);
                result(BUTTON_RES_LONG, ms);
                if (s_cb) s_cb(BUTTON_EVT_LONG);
            } else {
                ESP_LOGI(TAG, "ignored press (%lu ms)", (unsigned long)ms);
                result(BUTTON_RES_IGNORED, ms);
            }
        } else {
            result(BUTTON_RES_HOLD_DONE, ms);
        }
        gpio_intr_enable(BTN_GPIO);
    }
}

void button_set_hold(uint32_t hold_ms, button_held_cb_t held_cb)
{
    s_hold_ms = hold_ms;
    s_held_cb = held_cb;
}

void button_swallow_press(void)
{
    if (button_is_pressed()) s_swallow = true;
}

void button_set_down_cb(button_down_cb_t cb) { s_down_cb = cb; }

static esp_err_t init(button_cb_t cb, bool swallow_held)
{
    s_cb = cb;
    BaseType_t ok = xTaskCreate(button_task, "button", BTN_TASK_STACK, NULL, BTN_TASK_PRIO, &s_task);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "task");

    const gpio_config_t io = {
        .pin_bit_mask = 1ULL << BTN_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        /* 2026-11-11: the pin's interrupt stays off until its handler is in place. With LOW_LEVEL here, gpio_config()
         * enabled it, and gpio_install_isr_service() then opened the CPU interrupt with no handler for GPIO0: a key
         * still down (the press that woke the device) fired without end, nothing could switch it off, and the
         * interrupt watchdog reset the chip (key wake, reset INT_WDT right after display_init). */
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&io), TAG, "gpio_config");
    /* button_init_swallow(): marked before the ISR can start the task on it */
    const bool swallow = swallow_held && button_is_pressed();
    if (swallow) s_swallow = true;
    esp_err_t err = gpio_install_isr_service(0);
    ESP_RETURN_ON_FALSE(err == ESP_OK || err == ESP_ERR_INVALID_STATE, err, TAG, "isr service");
    ESP_RETURN_ON_ERROR(gpio_set_intr_type(BTN_GPIO, GPIO_INTR_LOW_LEVEL), TAG, "intr type");   /* does not enable */
    /* If it is held right now (e.g. still held from the wake-up press), wait for release first so
     * the waking press is not reported as an event. The interrupt is still off here. */
    if (swallow) {   /* the task times this press and reports nothing; init does not wait for it */
        ESP_LOGI(TAG, "BOOT down at init: that press is swallowed");
    } else if (button_is_pressed()) {
        button_wait_release(3000);
    }
    /* enables the pin's interrupt with the handler already set (a key still down: the ISR runs once, switches the
     * interrupt off and starts the task) */
    ESP_RETURN_ON_ERROR(gpio_isr_handler_add(BTN_GPIO, isr, NULL), TAG, "isr add");
    /* Level wake-up so a press also ends automatic light sleep. */
    ESP_RETURN_ON_ERROR(gpio_wakeup_enable(BTN_GPIO, GPIO_INTR_LOW_LEVEL), TAG, "wakeup enable");
    ESP_RETURN_ON_ERROR(esp_sleep_enable_gpio_wakeup(), TAG, "gpio wakeup");
    ESP_LOGI(TAG, "BOOT button ready on GPIO0");
    return ESP_OK;
}

esp_err_t button_init(button_cb_t cb) { return init(cb, false); }

esp_err_t button_init_swallow(button_cb_t cb) { return init(cb, true); }
