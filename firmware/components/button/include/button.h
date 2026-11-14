/* button.h — BOOT button on GPIO0 (active low, internal pull-up).
 *
 * Only configured after boot, so the ROM download strap is unaffected. A level interrupt (also a
 * light-sleep wake source) wakes a small task which debounces by sampling every 10 ms while the
 * button is down — no polling while idle.
 *   short press (< 400 ms)          -> BUTTON_EVT_SHORT  (on release)
 *   long press  (1.5 s .. 6 s)      -> BUTTON_EVT_LONG   (on release)
 *   hold        (>= 6 s)            -> BUTTON_EVT_HOLD   (immediately at 6 s, once)
 * Presses between 400 ms and 1.5 s are ignored. Callbacks run in the button task: keep them short.
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { BUTTON_EVT_SHORT, BUTTON_EVT_LONG, BUTTON_EVT_HOLD } button_event_t;
typedef void (*button_cb_t)(button_event_t ev);

#define BUTTON_SHORT_MAX_MS 400
#define BUTTON_LONG_MIN_MS  1500
#define BUTTON_HOLD_MS      6000

esp_err_t button_init(button_cb_t cb);
/* Optional, after button_init: BUTTON_EVT_HOLD after hold_ms instead of BUTTON_HOLD_MS, and held_cb (may be NULL) once
 * per press when it reaches BUTTON_LONG_MIN_MS with the button still down, on the button task. */
typedef void (*button_held_cb_t)(void);
void button_set_hold(uint32_t hold_ms, button_held_cb_t held_cb);
bool button_is_pressed(void);
/* Optional hooks for other projects that reuse this component (this firmware calls none of these):
 *  - button_init_swallow(): as button_init(), except that a press already down at init is not waited for (button_init
 *    blocks up to 3 s): it is swallowed instead, with no event of any kind (no held_cb, no HOLD, nothing at release);
 *  - button_swallow_press(): the press down now (if any) reports nothing more, its release included; a no-op when
 *    the button is up;
 *  - button_set_down_cb(): cb (may be NULL) once at the debounced start of every press, on the button task, before
 *    the press is timed. */
esp_err_t button_init_swallow(button_cb_t cb);
void button_swallow_press(void);
typedef void (*button_down_cb_t)(void);
void button_set_down_cb(button_down_cb_t cb);
/* An optional hook for other projects that reuse this component (a key flight recorder; this firmware does not call
 * it): cb (may be NULL) gets every press's outcome on the button task, also the ones that send no event (a glitch,
 * an ignored press, a swallowed press, the held step, a hold let go), with the press's length in ms so far. */
typedef enum {
    BUTTON_RES_GLITCH = 1,   /* down shorter than the debounce */
    BUTTON_RES_SHORT,
    BUTTON_RES_LONG,
    BUTTON_RES_IGNORED,      /* between short and long */
    BUTTON_RES_HELD,         /* still down at BUTTON_LONG_MIN_MS (held_cb) */
    BUTTON_RES_HOLD,         /* reached the hold (BUTTON_EVT_HOLD) */
    BUTTON_RES_SWALLOWED,    /* a swallowed press, let go */
    BUTTON_RES_HOLD_DONE,    /* a press that reached the hold, let go */
} button_result_t;
typedef void (*button_result_cb_t)(button_result_t res, uint32_t ms);
void button_set_result_cb(button_result_cb_t cb);
/* Block until the button has been released (debounced) or timeout; returns true if released. */
bool button_wait_release(uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif
