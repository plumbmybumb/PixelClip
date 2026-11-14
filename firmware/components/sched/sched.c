/* sched.c — time windows, queue due/skip decisions and the persisted done-set. */
#include "sched.h"

#include <string.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "cJSON.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "storage.h"

static const char *TAG = "sched";
#define DONE_FILE      "queue-done.json"
#define DONE_FILE_MAX  (SCHED_DONE_MAX * (SCHED_ID_MAX + 8) + 16)

static SemaphoreHandle_t s_mutex;
static StaticSemaphore_t s_mutex_buf;
/* Tables live in PSRAM (allocated by sched_init; ~9 KB kept out of internal RAM). Until then, or if
 * the allocation failed, the queue is simply empty. */
typedef char done_id_t[SCHED_ID_MAX + 1];
static done_id_t *s_done;              /* done-set, oldest first */
static size_t s_done_n;
static sched_slot_t *s_slots;          /* current queue */
static bool *s_slot_done;
static size_t s_n;
static int s_active = -1;

static void lock(void)
{
    if (!s_mutex) s_mutex = xSemaphoreCreateMutexStatic(&s_mutex_buf);
    xSemaphoreTake(s_mutex, portMAX_DELAY);
}
static void unlock(void) { xSemaphoreGive(s_mutex); }

/* ------------------------------------------------------------------ windows */

bool sched_parse_hhmm(const char *s, int16_t *minutes)
{
    if (!s || strlen(s) != 5 || s[2] != ':') return false;
    for (int i = 0; i < 5; i++) {
        if (i != 2 && (s[i] < '0' || s[i] > '9')) return false;
    }
    int h = (s[0] - '0') * 10 + (s[1] - '0');
    int m = (s[3] - '0') * 10 + (s[4] - '0');
    if (m > 59 || h > 24 || (h == 24 && m != 0)) return false;
    *minutes = (int16_t)(h * 60 + m);
    return true;
}

bool sched_window_contains(int16_t from, int16_t until, int64_t now, int32_t tz_offset_s)
{
    if (!sched_has_window(from, until)) return true;
    const int f = from == SCHED_NO_WINDOW ? 0 : from;
    const int u = until == SCHED_NO_WINDOW ? 24 * 60 : until;
    const int64_t local = now + tz_offset_s;
    const int m = (int)((((local % 86400) + 86400) % 86400) / 60);
    if (f == u) return true;                  /* rejected by the parser; defensive */
    if (f < u) return m >= f && m < u;
    return m >= f || m < u;                   /* crosses midnight */
}

/* ------------------------------------------------------------------ done-set */

bool sched_id_valid(const char *id)
{
    size_t n = id ? strlen(id) : 0;
    if (n == 0 || n > SCHED_ID_MAX) return false;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)id[i];
        if (c < 0x20 || c > 0x7E) return false;   /* PROTOCOL §4: 1-40 printable characters (ASCII) */
    }
    return true;
}

static int done_index(const char *id)
{
    for (size_t i = 0; i < s_done_n; i++) {
        if (strcmp(s_done[i], id) == 0) return (int)i;
    }
    return -1;
}

static void done_add(const char *id)
{
    if (!s_done || done_index(id) >= 0) return;
    if (s_done_n == SCHED_DONE_MAX) {   /* FIFO: forget the oldest */
        memmove(s_done[0], s_done[1], (SCHED_DONE_MAX - 1) * sizeof s_done[0]);
        s_done_n--;
    }
    strlcpy(s_done[s_done_n++], id, sizeof s_done[0]);
}

static void done_persist(void)
{
    cJSON *arr = cJSON_CreateArray();
    for (size_t i = 0; arr && i < s_done_n; i++) cJSON_AddItemToArray(arr, cJSON_CreateString(s_done[i]));
    char *s = arr ? cJSON_PrintUnformatted(arr) : NULL;
    cJSON_Delete(arr);
    esp_err_t err = s ? storage_write_file(DONE_FILE, s, strlen(s)) : ESP_ERR_NO_MEM;
    cJSON_free(s);
    if (err != ESP_OK) ESP_LOGE(TAG, "cannot persist done-set: %s", esp_err_to_name(err));
}

static void refresh_flags(void)
{
    for (size_t i = 0; i < s_n; i++) s_slot_done[i] = done_index(s_slots[i].id) >= 0;
}

static void *alloc_table(size_t bytes)
{
    void *p = heap_caps_calloc(1, bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    return p ? p : calloc(1, bytes);
}

esp_err_t sched_init(void)
{
    char *buf = NULL;
    size_t len = 0;
    lock();
    if (!s_done) s_done = alloc_table(SCHED_DONE_MAX * sizeof *s_done);
    if (!s_slots) s_slots = alloc_table(SCHED_QUEUE_MAX * sizeof *s_slots);
    if (!s_slot_done) s_slot_done = alloc_table(SCHED_QUEUE_MAX * sizeof *s_slot_done);
    if (!s_done || !s_slots || !s_slot_done) {
        unlock();
        ESP_LOGE(TAG, "no memory for the queue tables: queue disabled");
        return ESP_ERR_NO_MEM;
    }
    s_done_n = 0;
    if (storage_read_file(DONE_FILE, &buf, &len, DONE_FILE_MAX) == ESP_OK) {
        cJSON *arr = cJSON_ParseWithLength(buf, len);
        const cJSON *it;
        if (cJSON_IsArray(arr)) {
            cJSON_ArrayForEach(it, arr) {
                if (cJSON_IsString(it) && sched_id_valid(it->valuestring)) done_add(it->valuestring);
            }
        } else {
            ESP_LOGW(TAG, "%s is corrupt, starting with an empty done-set", DONE_FILE);
        }
        cJSON_Delete(arr);
        free(buf);
    }
    refresh_flags();
    unlock();
    ESP_LOGI(TAG, "%u queue id(s) already done", (unsigned)s_done_n);
    return ESP_OK;
}

/* ------------------------------------------------------------------ queue */

void sched_load(const sched_slot_t *slots, size_t n)
{
    if (n > SCHED_QUEUE_MAX) n = SCHED_QUEUE_MAX;
    lock();
    if (!s_slots || !s_done || !s_slot_done) {   /* sched_init failed: no queue */
        s_n = 0;
        unlock();
        return;
    }
    if (n) memcpy(s_slots, slots, n * sizeof *slots);
    s_n = n;
    s_active = -1;
    /* Forget done-state of ids that are no longer in the document. */
    size_t keep = 0;
    for (size_t i = 0; i < s_done_n; i++) {
        bool present = false;
        for (size_t j = 0; j < n && !present; j++) present = strcmp(s_done[i], slots[j].id) == 0;
        if (present) {
            if (keep != i) memcpy(s_done[keep], s_done[i], sizeof s_done[0]);
            keep++;
        }
    }
    bool pruned = keep != s_done_n;
    if (pruned) {
        ESP_LOGI(TAG, "forgot %u done id(s) not in the new queue", (unsigned)(s_done_n - keep));
        s_done_n = keep;
        done_persist();
    }
    refresh_flags();
    unlock();
}

int sched_poll(int64_t now, bool clock_synced)
{
    if (!clock_synced) return -1;
    int fire = -1;
    bool changed = false;
    lock();
    for (size_t i = 0; i < s_n; i++) {
        if (s_slot_done[i]) continue;
        if (now < s_slots[i].at) break;                       /* sorted: the rest is in the future */
        if (now - s_slots[i].at > SCHED_LATE_MAX_S) {
            ESP_LOGW(TAG, "queue entry %s skipped: %lld s late", s_slots[i].id, (long long)(now - s_slots[i].at));
            done_add(s_slots[i].id);
            s_slot_done[i] = true;
            changed = true;
            continue;
        }
        if (fire < 0) fire = (int)i;
    }
    if (fire >= 0) {
        ESP_LOGI(TAG, "queue entry %s due (%lld s after its time)", s_slots[fire].id, (long long)(now - s_slots[fire].at));
        done_add(s_slots[fire].id);
        s_slot_done[fire] = true;
        changed = true;
    }
    if (changed) done_persist();
    unlock();
    return fire;
}

void sched_mark_done(size_t idx, const char *why)
{
    lock();
    if (idx < s_n && !s_slot_done[idx]) {
        ESP_LOGW(TAG, "queue entry %s marked done (%s)", s_slots[idx].id, why ? why : "-");
        done_add(s_slots[idx].id);
        s_slot_done[idx] = true;
        done_persist();
    }
    unlock();
}

int sched_find(const char *id)
{
    int r = -1;
    lock();
    for (size_t i = 0; i < s_n && r < 0; i++) {
        if (strcmp(s_slots[i].id, id) == 0) r = (int)i;
    }
    unlock();
    return r;
}

void sched_set_active(int idx)
{
    lock();
    s_active = (idx >= 0 && (size_t)idx < s_n) ? idx : -1;
    unlock();
}

void sched_get_status(sched_status_t *out)
{
    memset(out, 0, sizeof *out);
    lock();
    for (size_t i = 0; i < s_n; i++) {
        if (s_slot_done[i]) {
            out->done++;
        } else {
            out->pending++;
            if (out->next_at == 0) out->next_at = s_slots[i].at;
        }
    }
    if (s_active >= 0) strlcpy(out->active, s_slots[s_active].id, sizeof out->active);
    unlock();
}
