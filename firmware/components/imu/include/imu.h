/* imu.h — QMI8658C accelerometer (docs/HARDWARE.md: I2C SCL=GPIO39 SDA=GPIO40, address 0x6B or 0x6A).
 *
 * Accelerometer only (gyro off), ±4 g. A small task samples at 50 Hz while someone holds a
 * reference (imu_acquire, i.e. while a live scene is visible) or a keep-alive is running (GET /imu),
 * at 10 Hz while the background flag is set (orientation "auto"); otherwise the sensor is disabled
 * (CTRL7 = 0) and the task blocks, so the CPU can light-sleep.
 *
 * All vectors are GRAVITY in g in the DISPLAY frame of docs/PROTOCOL.md §5b: +x right, +y down,
 * +z out of the glass — the direction things fall. Upright clip: (0, 1, 0); face up: (0, 0, -1).
 * The chip-to-display mapping is a calibration stored in NVS (POST /imu/calibrate) or, without one,
 * IMU_AXIS_MAP in imu.c corrected with CONFIG_PIXELCLIP_IMU_FLIP_X/Y/Z and CONFIG_PIXELCLIP_IMU_SWAP_XY.
 *
 * Readers never block: the latest sample is published through a sequence counter (single writer).
 * Init failure is non-fatal: every getter then returns the fixed downward gravity (0, 1, 0).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Probe 0x6B then 0x6A, check WHO_AM_I, configure, start the (idle) sampling task. */
esp_err_t imu_init(void);
/* Exclude the I2C pins from the light-sleep GPIO isolation (CONFIG_PM_SLP_DISABLE_GPIO); idempotent. */
void imu_sleep_pins_apply(void);
bool imu_present(void);
uint8_t imu_address(void);          /* 0 if absent */

/* Reference-counted "sample at 50 Hz". Safe from any task. */
void imu_acquire(void);
void imu_release(void);
/* Keep sampling for at least `ms` from now (bench endpoint). */
void imu_keepalive(uint32_t ms);

/* Background sampling at 10 Hz when nobody needs 50 Hz (the orientation detector). Safe from any task. */
void imu_set_background(bool on);
/* Called from the IMU task after every sample with the low-passed gravity (display frame, g). Keep it short
 * and non-blocking (the IMU task has a ~3 KB stack). NULL removes it. */
typedef void (*imu_sample_cb_t)(const float g_lp[3]);
void imu_set_sample_cb(imu_sample_cb_t cb);

/* Latest sample (display frame, g). Returns false and writes (0, 1, 0) if there is none. */
bool imu_get_gravity(float *gx, float *gy, float *gz);
/* Low-passed gravity (~100 ms time constant). Same fallback. */
bool imu_get_gravity_lp(float g[3]);
/* Decaying peak of |sample - low-pass| in g (0 when still, ~1+ when shaken). */
float imu_get_shake(void);
/* Raw chip-frame reading in g (specific force: +1 on the axis pointing up), for bench calibration. */
bool imu_get_raw(float r[3]);
/* Monotonic count of samples taken since boot. */
uint32_t imu_sample_count(void);

/* ---- Axis map (chip reading -> display-frame gravity: g[i] = sum_j m[i][j] * raw[j]) ----------
 * A bench calibration stored in NVS (POST /imu/calibrate, firmware/README "IMU bench check") replaces
 * the compiled IMU_AXIS_MAP + Kconfig flips, which stay the fallback when nothing is stored. */

/* Apply a signed permutation matrix and persist it (NVS namespace "imu"). ESP_ERR_INVALID_ARG if `m`
 * is not a signed permutation; the map is applied even if persisting fails (the error is returned). */
esp_err_t imu_set_axis_map(const int8_t m[3][3]);
/* Forget the stored calibration: back to the compiled map + Kconfig flips. */
esp_err_t imu_clear_axis_map(void);
/* Effective map; returns true if it comes from a stored calibration. */
bool imu_get_axis_map(int8_t m[3][3]);

/* Average the raw chip reading over ~`ms` of 50 Hz samples (starts sampling if needed).
 * ESP_ERR_NOT_FOUND: no IMU; ESP_ERR_INVALID_STATE: the clip moved (an axis spread > 0.1 g);
 * ESP_ERR_TIMEOUT: no samples. `spread` (may be NULL) receives the largest per-axis spread in g. */
esp_err_t imu_capture_still(float raw[3], uint32_t ms, float *spread);

#ifdef __cplusplus
}
#endif
