/* ota.c — esp_ota wrapper with streaming hash. */
#include "ota.h"

#include <stdlib.h>
#include <string.h>
#include "esp_ota_ops.h"
#include "esp_timer.h"
#include "esp_system.h"
#include "esp_log.h"
#include "mbedtls/sha256.h"

static const char *TAG = "ota";

struct ota_session {
    esp_ota_handle_t handle;
    const esp_partition_t *part;
    size_t size, written;
    mbedtls_sha256_context sha;
};

esp_err_t ota_begin(size_t size, ota_session_t **out)
{
    *out = NULL;
    const esp_partition_t *part = esp_ota_get_next_update_partition(NULL);
    if (!part) return ESP_ERR_NOT_FOUND;
    if (size == 0 || size > part->size) return ESP_ERR_INVALID_SIZE;
    ota_session_t *s = calloc(1, sizeof *s);
    if (!s) return ESP_ERR_NO_MEM;
    esp_err_t err = esp_ota_begin(part, OTA_WITH_SEQUENTIAL_WRITES, &s->handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_begin: %s", esp_err_to_name(err));
        free(s);
        return err;
    }
    s->part = part;
    s->size = size;
    mbedtls_sha256_init(&s->sha);
    mbedtls_sha256_starts(&s->sha, 0);
    *out = s;
    ESP_LOGI(TAG, "writing %u bytes to %s", (unsigned)size, part->label);
    return ESP_OK;
}

esp_err_t ota_write(ota_session_t *s, const void *data, size_t len)
{
    if (s->written + len > s->size) return ESP_ERR_INVALID_SIZE;
    esp_err_t err = esp_ota_write(s->handle, data, len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_write: %s", esp_err_to_name(err));
        return err;
    }
    mbedtls_sha256_update(&s->sha, data, len);
    s->written += len;
    return ESP_OK;
}

void ota_abort(ota_session_t *s)
{
    if (!s) return;
    esp_ota_abort(s->handle);
    mbedtls_sha256_free(&s->sha);
    free(s);
}

esp_err_t ota_finish(ota_session_t *s, const uint8_t expected_sha[32])
{
    uint8_t sha[32];
    if (s->written != s->size) {
        ota_abort(s);
        return ESP_ERR_INVALID_SIZE;
    }
    mbedtls_sha256_finish(&s->sha, sha);
    if (memcmp(sha, expected_sha, 32) != 0) {
        ESP_LOGW(TAG, "image hash mismatch");
        ota_abort(s);
        return ESP_ERR_INVALID_CRC;
    }
    esp_err_t err = esp_ota_end(s->handle); /* validates the image */
    if (err == ESP_OK) err = esp_ota_set_boot_partition(s->part);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "finish: %s", esp_err_to_name(err));
    } else {
        ESP_LOGI(TAG, "update staged in %s", s->part->label);
    }
    mbedtls_sha256_free(&s->sha);
    free(s);
    return err;
}

static void restart_cb(void *arg)
{
    ESP_LOGI(TAG, "rebooting");
    esp_restart();
}

void ota_restart_in(uint32_t ms)
{
    static esp_timer_handle_t t;
    const esp_timer_create_args_t args = { .callback = restart_cb, .name = "ota_reboot" };
    if (!t && esp_timer_create(&args, &t) != ESP_OK) {
        esp_restart();
    }
    esp_timer_stop(t); /* ignore "not running" */
    if (esp_timer_start_once(t, (uint64_t)ms * 1000) != ESP_OK) esp_restart();
}

static void mark_valid_cb(void *arg)
{
    esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "running image marked valid");
    } else {
        ESP_LOGE(TAG, "mark valid: %s", esp_err_to_name(err));
    }
}

void ota_schedule_mark_valid(uint32_t delay_s)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) != ESP_OK || state != ESP_OTA_IMG_PENDING_VERIFY) {
        return;
    }
    ESP_LOGI(TAG, "new image pending verification; marking valid in %lu s", (unsigned long)delay_s);
    static esp_timer_handle_t t;
    const esp_timer_create_args_t args = { .callback = mark_valid_cb, .name = "ota_valid" };
    if (esp_timer_create(&args, &t) == ESP_OK) {
        esp_err_t err = esp_timer_start_once(t, (uint64_t)delay_s * 1000000);
        if (err != ESP_OK) ESP_LOGE(TAG, "timer: %s", esp_err_to_name(err));
    }
}
