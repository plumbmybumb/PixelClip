/* imu.c — QMI8658C accelerometer over the I2C master driver, 50 Hz sampling task.
 *
 * Register use (QMI8658C datasheet rev 0.9 and the Waveshare 02_I2C_QMI8658 demo for this board):
 *   0x00 WHO_AM_I = 0x05     0x01 REVISION
 *   0x02 CTRL1   0x60 = address auto-increment + the demo's endianness bit (the demo decodes the data
 *                registers little-endian with this value; see the plausibility check below).
 *                INT1/INT2 output enables (bits 3/4) stay 0: the pins stay high-Z. They are wired to
 *                GPIO45/46, ESP32-S3 strapping pins (VDD_SPI voltage / boot mode): an IMU driving them
 *                during a software reset could brick the boot. Never enable them.
 *   0x03 CTRL2   accelerometer: full scale bits 6:4 (0x10 = ±4 g, 8192 LSB/g), ODR bits 3:0
 *                (0x07 = 62.5 Hz normal mode, 0x0C = 128 Hz low-power mode)
 *   0x06 CTRL5   low-pass filters off (as the demo)
 *   0x08 CTRL7   sensor enable: 0x01 = accelerometer only (gyro off), 0x00 = all off
 *   0x35..0x3A   AX_L..AZ_H (int16)
 *   0x60 RESET   0xB0 = soft reset
 */
#include "imu.h"

#include <string.h>
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/i2c_master.h"
#include "driver/gpio.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "nvs.h"
#include "sdkconfig.h"

static const char *TAG = "imu";

#define PIN_SCL        GPIO_NUM_39
#define PIN_SDA        GPIO_NUM_40
#define I2C_HZ         400000
#define I2C_TIMEOUT_MS 20
#define SAMPLE_MS      20          /* 50 Hz */
#define LP_ALPHA       0.18f       /* ~100 ms time constant at 50 Hz */
#define SHAKE_DECAY    0.92f       /* per sample: ~0.25 s */
#define BG_SAMPLE_MS   100         /* background rate (imu_set_background: orientation detector), 10 Hz */
#define LP_ALPHA_BG    0.63f       /* same ~100 ms time constant at 10 Hz: 1 - e^-1 */
#define SHAKE_DECAY_BG 0.66f       /* 0.92^5 */
#define TASK_STACK     4096   /* the orientation hook (player queue post + log) runs on this stack; keep >= 1.5 KB free */
#define TASK_PRIO      3
#define NVS_NS         "imu"
#define NVS_KEY_MAP    "axis_map"
#define MAP_BLOB_VER   1
#define STILL_SPREAD_G 0.10f       /* imu_capture_still: max per-axis spread while "still" */

#define REG_WHO_AM_I   0x00
#define REG_REVISION   0x01
#define REG_CTRL1      0x02
#define REG_CTRL2      0x03
#define REG_CTRL5      0x06
#define REG_CTRL7      0x08
#define REG_AX_L       0x35
#define REG_RESET      0x60
#define WHO_AM_I_VALUE 0x05
#define CTRL1_VALUE    0x60
#define ACC_FS_4G      0x10
#define ACC_ODR_62HZ   0x07
#define ACC_ODR_LP128  0x0C
#define LSB_PER_G      8192.0f
#if CONFIG_PIXELCLIP_IMU_LOW_POWER
#define ACC_ODR        ACC_ODR_LP128
#define ACC_ODR_STR    "128 Hz low-power"
#else
#define ACC_ODR        ACC_ODR_62HZ
#define ACC_ODR_STR    "62.5 Hz"
#endif
#if CONFIG_PIXELCLIP_IMU_ENABLE
#define IMU_ENABLED 1
#else
#define IMU_ENABLED 0
#endif

/* ---- Axis mapping -------------------------------------------------------------------------------
 * g_display = FLIPS( SWAP( IMU_AXIS_MAP * reading ) ), reading = chip-frame specific force in g
 * (+1 g on the chip axis pointing UP at rest), g_display = gravity (DOWN) in the display frame
 * (+x right, +y down, +z out of the glass; left-handed).
 *
 * ASSUMPTION — UNVERIFIED until the bench: neither the schematic nor the Waveshare demo documents the
 * QMI8658C's orientation relative to the panel (the demo just prints chip axes, layout 0). The AMOLED
 * covers the whole front, so the IMU sits on the back (component side) with its +Z pointing AWAY from
 * the viewer; we assume its +Y runs along the short edge toward the TOP of the landscape image. The
 * chip frame is right-handed, so +X then points to the viewer's LEFT. In display terms the chip axes
 * are (-x, -y, -z), and turning "up" (specific force) into "down" (gravity) negates once more:
 *     g_display = +reading      → the identity matrix below.
 * Checks: upright reading (0, +1, 0) → g (0, 1, 0) ✓; face up (back toward the floor) reading
 * (0, 0, -1) → g (0, 0, -1) ✓. If the chip is rotated or on the front, CONFIG_PIXELCLIP_IMU_SWAP_XY and
 * CONFIG_PIXELCLIP_IMU_FLIP_X/Y/Z cover every board-parallel orientation (8 in-plane × front/back) without
 * touching this table; the bench procedure is in firmware/README.md ("IMU bench check"). */
static const int8_t IMU_AXIS_MAP[3][3] = {
    { 1, 0, 0 },
    { 0, 1, 0 },
    { 0, 0, 1 },
};

/* Effective map (s_mux): the stored calibration, or IMU_AXIS_MAP with the Kconfig swap/flips folded in. */
static int8_t s_map[3][3];
static bool s_map_calibrated;

/* ---- Published state (seqlock: single writer = the IMU task) ------------------------------------ */
typedef struct {
    float g[3], lp[3], raw[3];
    float shake;
    uint32_t n;
} sample_t;

static volatile uint32_t s_seq;
static sample_t s_pub;

static i2c_master_bus_handle_t s_bus;
static i2c_master_dev_handle_t s_dev;
static uint8_t s_addr;
static bool s_present;
static TaskHandle_t s_task;
static volatile int s_refs;
static volatile int64_t s_keepalive_until;
static volatile bool s_background;
static imu_sample_cb_t volatile s_sample_cb;
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
static bool s_swap_bytes;        /* data registers turned out big-endian (plausibility check) */

static esp_err_t wr(uint8_t reg, uint8_t val)
{
    uint8_t b[2] = { reg, val };
    return i2c_master_transmit(s_dev, b, 2, I2C_TIMEOUT_MS);
}

static esp_err_t rd(uint8_t reg, uint8_t *buf, size_t len)
{
    return i2c_master_transmit_receive(s_dev, &reg, 1, buf, len, I2C_TIMEOUT_MS);
}

static void publish(const sample_t *s)
{
    uint32_t q = s_seq;
    __atomic_store_n(&s_seq, q + 1, __ATOMIC_RELEASE);   /* odd: write in progress */
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    s_pub = *s;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    __atomic_store_n(&s_seq, q + 2, __ATOMIC_RELEASE);
}

static void snapshot(sample_t *out)
{
    for (;;) {
        uint32_t a = __atomic_load_n(&s_seq, __ATOMIC_ACQUIRE);
        if (a & 1) continue;
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        *out = s_pub;
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        if (__atomic_load_n(&s_seq, __ATOMIC_ACQUIRE) == a) return;
    }
}

/* IMU_AXIS_MAP with the Kconfig bench fixes applied as row operations (swap X/Y first, then flips). */
static void kconfig_map(int8_t m[3][3])
{
    memcpy(m, IMU_AXIS_MAP, 9);
#if CONFIG_PIXELCLIP_IMU_SWAP_XY
    int8_t t[3];
    memcpy(t, m[0], 3);
    memcpy(m[0], m[1], 3);
    memcpy(m[1], t, 3);
#endif
    for (int j = 0; j < 3; j++) {
#if CONFIG_PIXELCLIP_IMU_FLIP_X
        m[0][j] = (int8_t)-m[0][j];
#endif
#if CONFIG_PIXELCLIP_IMU_FLIP_Y
        m[1][j] = (int8_t)-m[1][j];
#endif
#if CONFIG_PIXELCLIP_IMU_FLIP_Z
        m[2][j] = (int8_t)-m[2][j];
#endif
    }
}

static bool is_signed_permutation(const int8_t m[3][3])
{
    int cols = 0;
    for (int i = 0; i < 3; i++) {
        int nz = 0;
        for (int j = 0; j < 3; j++) {
            if (m[i][j] == 0) continue;
            if (m[i][j] != 1 && m[i][j] != -1) return false;
            nz++;
            cols |= 1 << j;
        }
        if (nz != 1) return false;
    }
    return cols == 7;
}

static void map_axes(const float r[3], float g[3])
{
    int8_t m[3][3];
    portENTER_CRITICAL(&s_mux);
    memcpy(m, s_map, sizeof m);
    portEXIT_CRITICAL(&s_mux);
    for (int i = 0; i < 3; i++) g[i] = m[i][0] * r[0] + m[i][1] * r[1] + m[i][2] * r[2];
}

static void set_map(const int8_t m[3][3], bool calibrated)
{
    portENTER_CRITICAL(&s_mux);
    memcpy(s_map, m, sizeof s_map);
    s_map_calibrated = calibrated;
    portEXIT_CRITICAL(&s_mux);
}

/* Stored calibration (if any) or the compiled map. Needs NVS (initialised before imu_init). */
static void load_map(void)
{
    int8_t m[3][3];
    kconfig_map(m);
    set_map(m, false);
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return;
    uint8_t blob[10];
    size_t len = sizeof blob;
    esp_err_t err = nvs_get_blob(h, NVS_KEY_MAP, blob, &len);
    nvs_close(h);
    if (err != ESP_OK) return;
    memcpy(m, blob + 1, 9);
    if (len != sizeof blob || blob[0] != MAP_BLOB_VER || !is_signed_permutation(m)) {
        ESP_LOGW(TAG, "stored axis map invalid, using the compiled map + Kconfig flips");
        return;
    }
    set_map(m, true);
    ESP_LOGI(TAG, "axis map from bench calibration: [%d %d %d] [%d %d %d] [%d %d %d]", m[0][0], m[0][1], m[0][2],
             m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2]);
}

esp_err_t imu_set_axis_map(const int8_t m[3][3])
{
    if (!is_signed_permutation(m)) return ESP_ERR_INVALID_ARG;
    set_map(m, true);
    uint8_t blob[10] = { MAP_BLOB_VER };
    memcpy(blob + 1, m, 9);
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err == ESP_OK) {
        err = nvs_set_blob(h, NVS_KEY_MAP, blob, sizeof blob);
        if (err == ESP_OK) err = nvs_commit(h);
        nvs_close(h);
    }
    ESP_LOGI(TAG, "axis map calibrated: [%d %d %d] [%d %d %d] [%d %d %d]%s", m[0][0], m[0][1], m[0][2], m[1][0], m[1][1],
             m[1][2], m[2][0], m[2][1], m[2][2], err == ESP_OK ? ", stored" : ", NOT stored");
    return err;
}

esp_err_t imu_clear_axis_map(void)
{
    int8_t m[3][3];
    kconfig_map(m);
    set_map(m, false);
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err == ESP_OK) {
        err = nvs_erase_key(h, NVS_KEY_MAP);
        if (err == ESP_ERR_NVS_NOT_FOUND) err = ESP_OK;
        if (err == ESP_OK) err = nvs_commit(h);
        nvs_close(h);
    }
    ESP_LOGI(TAG, "axis map calibration cleared: compiled map + Kconfig flips");
    return err;
}

bool imu_get_axis_map(int8_t m[3][3])
{
    portENTER_CRITICAL(&s_mux);
    memcpy(m, s_map, 9);
    bool c = s_map_calibrated;
    portEXIT_CRITICAL(&s_mux);
    return c;
}

static float mag3(const float v[3]) { return sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); }

static void decode(const uint8_t b[6], bool big_endian, float r[3])
{
    for (int i = 0; i < 3; i++) {
        uint16_t u = big_endian ? (uint16_t)((b[2 * i] << 8) | b[2 * i + 1]) : (uint16_t)((b[2 * i + 1] << 8) | b[2 * i]);
        r[i] = (float)(int16_t)u / LSB_PER_G;
    }
}

static esp_err_t sensor_enable(bool on)
{
    return wr(REG_CTRL7, on ? 0x01 : 0x00);
}

static void imu_task(void *arg)
{
    sample_t st = { 0 };
    bool enabled = false, have_lp = false;
    int period_ms = 0;               /* sampling period in force (SAMPLE_MS or BG_SAMPLE_MS) */
    int errors = 0;
    uint32_t since_enable = 0, le_ok = 0, be_ok = 0;
    bool endian_decided = false;
    TickType_t last = xTaskGetTickCount();
    for (;;) {
        /* 50 Hz for a scene / keep-alive, else 10 Hz in the background (orientation), else off. */
        const bool fast = s_refs > 0 || esp_timer_get_time() < s_keepalive_until;
        const int want_ms = fast ? SAMPLE_MS : s_background ? BG_SAMPLE_MS : 0;
        const bool want = want_ms != 0;
        if (want && enabled && want_ms != period_ms) {
            ESP_LOGI(TAG, "sampling at %s", fast ? "50 Hz" : "10 Hz (background)");
            last = xTaskGetTickCount();   /* no catch-up burst of 50 Hz samples after a 100 ms wait */
        }
        if (want) period_ms = want_ms;
        if (want != enabled) {
            esp_err_t err = sensor_enable(want);
            if (err != ESP_OK) ESP_LOGW(TAG, "CTRL7 write: %s", esp_err_to_name(err));
            enabled = want;
            ESP_LOGI(TAG, "sampling %s", !enabled ? "off" : fast ? "on (50 Hz)" : "on (10 Hz background)");
            if (enabled) {
                vTaskDelay(pdMS_TO_TICKS(30));   /* first conversion after enabling */
                last = xTaskGetTickCount();
                have_lp = false;
                since_enable = 0;
            }
        }
        if (!enabled) {
            ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
            continue;
        }
        vTaskDelayUntil(&last, pdMS_TO_TICKS(period_ms));
        uint8_t b[6];
        esp_err_t err = rd(REG_AX_L, b, sizeof b);
        if (err != ESP_OK) {
            if (++errors == 25) ESP_LOGE(TAG, "25 consecutive read errors (%s)", esp_err_to_name(err));
            continue;
        }
        errors = 0;
        /* Endianness plausibility (first 10 samples after boot): at rest |a| is ~1 g. The demo's
         * CTRL1 value with little-endian decoding is the known-good combination on this board; only
         * switch if little-endian is clearly wrong and big-endian clearly right. */
        if (!endian_decided) {
            float le[3], be[3];
            decode(b, false, le);
            decode(b, true, be);
            le_ok += mag3(le) > 0.6f && mag3(le) < 1.5f;
            be_ok += mag3(be) > 0.6f && mag3(be) < 1.5f;
            if (++since_enable >= 10) {
                endian_decided = true;
                if (le_ok < 3 && be_ok >= 8) {
                    s_swap_bytes = true;
                    ESP_LOGW(TAG, "data registers read big-endian (|a| implausible as little-endian): switching");
                } else if (le_ok < 8) {
                    ESP_LOGW(TAG, "|a| not ~1 g in %lu/10 samples (moving, or a scaling problem?)", (unsigned long)(10 - le_ok));
                }
            }
        }
        decode(b, s_swap_bytes, st.raw);
        map_axes(st.raw, st.g);
        if (!have_lp) {
            memcpy(st.lp, st.g, sizeof st.lp);
            have_lp = true;
        }
        const bool bg = period_ms != SAMPLE_MS;
        const float alpha = bg ? LP_ALPHA_BG : LP_ALPHA, decay = bg ? SHAKE_DECAY_BG : SHAKE_DECAY;
        float hp[3];
        for (int i = 0; i < 3; i++) {
            st.lp[i] += alpha * (st.g[i] - st.lp[i]);
            hp[i] = st.g[i] - st.lp[i];
        }
        float m = mag3(hp);
        st.shake = m > st.shake * decay ? m : st.shake * decay;
        st.n++;
        publish(&st);
        const imu_sample_cb_t cb = s_sample_cb;
        if (cb) cb(st.lp);
    }
}

static void wake_task(void)
{
    if (s_task) xTaskNotifyGive(s_task);
}

void imu_acquire(void)
{
    portENTER_CRITICAL(&s_mux);
    s_refs++;
    portEXIT_CRITICAL(&s_mux);
    wake_task();
}

void imu_release(void)
{
    portENTER_CRITICAL(&s_mux);
    if (s_refs > 0) s_refs--;
    portEXIT_CRITICAL(&s_mux);
}

void imu_keepalive(uint32_t ms)
{
    int64_t until = esp_timer_get_time() + (int64_t)ms * 1000;
    portENTER_CRITICAL(&s_mux);
    if (until > s_keepalive_until) s_keepalive_until = until;
    portEXIT_CRITICAL(&s_mux);
    wake_task();
}

void imu_set_background(bool on)
{
    s_background = on;
    wake_task();
}

void imu_set_sample_cb(imu_sample_cb_t cb) { s_sample_cb = cb; }

bool imu_present(void) { return s_present; }
uint8_t imu_address(void) { return s_present ? s_addr : 0; }

uint32_t imu_sample_count(void)
{
    sample_t s;
    snapshot(&s);
    return s.n;
}

bool imu_get_gravity(float *gx, float *gy, float *gz)
{
    sample_t s;
    snapshot(&s);
    if (!s_present || s.n == 0) {
        *gx = 0.0f; *gy = 1.0f; *gz = 0.0f;
        return false;
    }
    *gx = s.g[0]; *gy = s.g[1]; *gz = s.g[2];
    return true;
}

bool imu_get_gravity_lp(float g[3])
{
    sample_t s;
    snapshot(&s);
    if (!s_present || s.n == 0) {
        g[0] = 0.0f; g[1] = 1.0f; g[2] = 0.0f;
        return false;
    }
    memcpy(g, s.lp, sizeof s.lp);
    return true;
}

float imu_get_shake(void)
{
    sample_t s;
    snapshot(&s);
    return s_present ? s.shake : 0.0f;
}

bool imu_get_raw(float r[3])
{
    sample_t s;
    snapshot(&s);
    memcpy(r, s.raw, sizeof s.raw);
    return s_present && s.n > 0;
}

esp_err_t imu_capture_still(float raw[3], uint32_t ms, float *spread)
{
    if (spread) *spread = 0.0f;
    if (!s_present) return ESP_ERR_NOT_FOUND;
    imu_keepalive(ms + 2000);
    const int want = (int)(ms / SAMPLE_MS) < 5 ? 5 : (int)(ms / SAMPLE_MS);
    float sum[3] = { 0 }, lo[3] = { 0 }, hi[3] = { 0 };
    int got = 0;
    uint32_t last = imu_sample_count();
    /* Up to 2x the nominal time, plus the sensor's start-up after enabling. */
    for (int tries = 0; got < want && tries < 2 * want + 25; tries++) {
        vTaskDelay(pdMS_TO_TICKS(SAMPLE_MS));
        sample_t s;
        snapshot(&s);
        if (s.n == last) continue;
        last = s.n;
        for (int i = 0; i < 3; i++) {
            sum[i] += s.raw[i];
            if (got == 0 || s.raw[i] < lo[i]) lo[i] = s.raw[i];
            if (got == 0 || s.raw[i] > hi[i]) hi[i] = s.raw[i];
        }
        got++;
    }
    if (got < want) return ESP_ERR_TIMEOUT;
    float sp = 0.0f;
    for (int i = 0; i < 3; i++) {
        raw[i] = sum[i] / (float)got;
        if (hi[i] - lo[i] > sp) sp = hi[i] - lo[i];
    }
    if (spread) *spread = sp;
    ESP_LOGI(TAG, "still reading [%.3f %.3f %.3f] g over %d samples (spread %.3f g)", (double)raw[0], (double)raw[1],
             (double)raw[2], got, (double)sp);
    return sp > STILL_SPREAD_G ? ESP_ERR_INVALID_STATE : ESP_OK;
}

static void bus_teardown(void)
{
    if (s_dev) i2c_master_bus_rm_device(s_dev);
    if (s_bus) i2c_del_master_bus(s_bus);
    s_dev = NULL;
    s_bus = NULL;
}

/* Keep SCL/SDA out of the light-sleep GPIO isolation (re-applied after every WiFi session). */
void imu_sleep_pins_apply(void)
{
    gpio_sleep_sel_dis(PIN_SCL);
    gpio_sleep_sel_dis(PIN_SDA);
}

esp_err_t imu_init(void)
{
    load_map();
    if (!IMU_ENABLED) {
        ESP_LOGI(TAG, "disabled in menuconfig: scenes use fixed gravity");
        return ESP_OK;
    }
    i2c_master_bus_config_t bc = {
        .i2c_port = I2C_NUM_0,
        .sda_io_num = PIN_SDA,
        .scl_io_num = PIN_SCL,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,   /* as the Waveshare demo */
    };
    esp_err_t err = i2c_new_master_bus(&bc, &s_bus);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "I2C bus: %s", esp_err_to_name(err));
        s_bus = NULL;
        return err;
    }
    static const uint8_t addrs[] = { 0x6B, 0x6A };   /* demo uses 0x6B; schematic suggests 0x6A */
    for (size_t i = 0; i < sizeof addrs && !s_addr; i++) {
        if (i2c_master_probe(s_bus, addrs[i], 50) == ESP_OK) s_addr = addrs[i];
    }
    if (!s_addr) {
        ESP_LOGE(TAG, "QMI8658C not found at 0x6B or 0x6A: scenes use fixed gravity");
        bus_teardown();
        return ESP_ERR_NOT_FOUND;
    }
    i2c_device_config_t dc = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = s_addr,
        .scl_speed_hz = I2C_HZ,
    };
    err = i2c_master_bus_add_device(s_bus, &dc, &s_dev);
    uint8_t who = 0, rev = 0;
    if (err == ESP_OK) {
        wr(REG_RESET, 0xB0);                      /* soft reset: known register state */
        vTaskDelay(pdMS_TO_TICKS(20));
        for (int i = 0; i < 5 && who != WHO_AM_I_VALUE; i++) {
            err = rd(REG_WHO_AM_I, &who, 1);
            if (who != WHO_AM_I_VALUE) vTaskDelay(pdMS_TO_TICKS(5));
        }
        if (who != WHO_AM_I_VALUE) err = ESP_ERR_INVALID_RESPONSE;
    }
    if (err == ESP_OK) {
        rd(REG_REVISION, &rev, 1);
        err = wr(REG_CTRL1, CTRL1_VALUE);
        if (err == ESP_OK) err = wr(REG_CTRL2, ACC_FS_4G | ACC_ODR);
        if (err == ESP_OK) err = wr(REG_CTRL5, 0x00);
        if (err == ESP_OK) err = sensor_enable(false);   /* off until someone needs samples */
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "QMI8658C at 0x%02X: init failed (%s, WHO_AM_I 0x%02X): scenes use fixed gravity",
                 s_addr, esp_err_to_name(err), who);
        bus_teardown();
        s_addr = 0;
        return err;
    }
    /* Automatic light sleep isolates GPIOs (CONFIG_PM_SLP_DISABLE_GPIO): keep the bus pins pulled up
     * so the chip never sees a falling SDA/SCL (a spurious START) while we sleep. */
    imu_sleep_pins_apply();
    s_present = true;
    if (xTaskCreate(imu_task, "imu", TASK_STACK, NULL, TASK_PRIO, &s_task) != pdPASS) {
        s_present = false;
        ESP_LOGE(TAG, "no memory for the IMU task");
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "QMI8658C at 0x%02X (rev 0x%02X), accel-only +-4 g @ %s, sampled at 50 Hz on demand",
             s_addr, rev, ACC_ODR_STR);
    return ESP_OK;
}
