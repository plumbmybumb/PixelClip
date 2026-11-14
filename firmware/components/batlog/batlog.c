/* batlog.c — periodic battery/state CSV logger in a two-file ring. */
#include "batlog.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_check.h"
#include "storage.h"
#include "power.h"
#include "timekeeping.h"

static const char *TAG = "batlog";
#define CUR_FILE  "batlog.csv"
#define OLD_FILE  "batlog.1.csv"
#define FILE_CAP  (32 * 1024)
#define BATLOG_TASK_STACK 3072   /* snprintf + stdio file append */

static SemaphoreHandle_t s_mutex;
static batlog_state_fn_t s_state_fn;

static void append_line(void)
{
    power_battery_t b;
    batlog_state_t st = { .mode = "?" };
    power_get_battery(&b);
    if (s_state_fn) s_state_fn(&st);
    char line[128];
    int n = snprintf(line, sizeof line, "%lld,%lld,%d,%d,%d,%s,%s,%u\n",
                     timekeeping_synced() ? (long long)timekeeping_now() : 0LL,
                     (long long)(esp_timer_get_time() / 1000000), b.mv, b.pct, b.usb_present ? 1 : 0,
                     st.mode, st.display_on ? "on" : "off", st.brightness);
    if (n <= 0 || n >= (int)sizeof line) return;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    if (storage_file_size(CUR_FILE) >= FILE_CAP && storage_rename_file(CUR_FILE, OLD_FILE) != ESP_OK) {
        ESP_LOGE(TAG, "rotate failed");
    }
    if (storage_append_file(CUR_FILE, line, (size_t)n) != ESP_OK) ESP_LOGE(TAG, "append failed");
    xSemaphoreGive(s_mutex);
}

static void batlog_task(void *arg)
{
    TickType_t last = xTaskGetTickCount();
    for (;;) {
        vTaskDelayUntil(&last, pdMS_TO_TICKS(BATLOG_PERIOD_S * 1000));
        append_line();
    }
}

esp_err_t batlog_init(batlog_state_fn_t state_fn)
{
    s_state_fn = state_fn;
    s_mutex = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_mutex, ESP_ERR_NO_MEM, TAG, "no mem");
    BaseType_t ok = xTaskCreate(batlog_task, "batlog", BATLOG_TASK_STACK, NULL, 1, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "task");
    return ESP_OK;
}

static esp_err_t stream_file(const char *name, batlog_sink_t sink, void *ctx)
{
    char *buf = NULL;
    size_t len = 0;
    esp_err_t err = storage_read_file(name, &buf, &len, FILE_CAP + 1024);
    if (err == ESP_ERR_NOT_FOUND) return ESP_OK;
    if (err != ESP_OK) return err;
    err = len ? sink(ctx, buf, len) : ESP_OK;
    free(buf);
    return err;
}

esp_err_t batlog_read(batlog_sink_t sink, void *ctx)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    esp_err_t err = sink(ctx, BATLOG_HEADER, strlen(BATLOG_HEADER));
    if (err == ESP_OK) err = stream_file(OLD_FILE, sink, ctx);
    if (err == ESP_OK) err = stream_file(CUR_FILE, sink, ctx);
    xSemaphoreGive(s_mutex);
    return err;
}

esp_err_t batlog_clear(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    storage_remove_file(OLD_FILE);
    storage_remove_file(CUR_FILE);
    xSemaphoreGive(s_mutex);
    ESP_LOGI(TAG, "cleared");
    return ESP_OK;
}
