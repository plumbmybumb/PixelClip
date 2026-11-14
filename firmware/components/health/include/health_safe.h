/* health_safe.h — the safe-start rule of health_boot_record() (health.h), pure: no ESP-IDF, so it is
 * host-tested (test_host/test_safe_start.c).
 *
 * Safe start: after HEALTH_SAFE_START_CRASHES boots in a row that each followed an early crash, the clip
 * starts without its stored playlist, so stored content that crashes the firmware at every boot cannot keep
 * the clip unreachable. An early crash is a panic or a watchdog reset of a run whose last sign of life was
 * less than HEALTH_SAFE_START_WINDOW_S after its boot. Everything else ends the streak: any boot that is not
 * a crash (power-on, the RESET key, a USB or flashing reset, the restart after an OTA, a deep-sleep wake, a
 * brownout), a crash of a run that lived longer, a watchdog reset blamed only on the radio tasks (httpd, lwIP,
 * BLE: not the content's doing, and it has its own safety valve), and a boot whose previous run left no
 * breadcrumbs (RTC memory lost: a power loss). */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HEALTH_SAFE_START_CRASHES  3
#define HEALTH_SAFE_START_WINDOW_S 120

typedef struct {
    bool crash;          /* this boot follows a panic or a watchdog reset (any of them) */
    bool radio_only;     /* ... a liveness reset blamed only on httpd / lwIP / BLE */
    bool prev_known;     /* the previous run's breadcrumbs survived (RTC memory kept) */
    uint32_t prev_up_s;  /* uptime of the previous run at its last sign of life */
} health_safe_in_t;

/* `streak` = early crashes in a row before this boot. Returns the streak to keep for the next boot and sets
 * *safe_start when this boot must start safe (the streak then starts again at 0). */
uint32_t health_safe_rule(uint32_t streak, const health_safe_in_t *in, bool *safe_start);

#ifdef __cplusplus
}
#endif
