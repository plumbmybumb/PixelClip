/* press_seq.h: the hotspot password reset gesture (README "Using the clip"), pure: no ESP-IDF, time comes in
 * as a parameter, so it is host-tested (test_host/test_press_seq.c).
 *
 * PRESS_SEQ_COUNT short presses whose releases fall within PRESS_SEQ_SPAN_MS open a confirmation window of
 * PRESS_SEQ_WINDOW_MS. A long press inside the window confirms; any other press inside it cancels, and so does
 * the window running out. A long press or a hold outside the window starts the count again. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PRESS_SEQ_COUNT     5
#define PRESS_SEQ_SPAN_MS   3000u
#define PRESS_SEQ_WINDOW_MS 10000u

typedef enum {
    PRESS_SEQ_NONE = 0,   /* nothing for the gesture: the press keeps its normal meaning */
    PRESS_SEQ_OPEN,       /* this short press completed the sequence: the window is open */
    PRESS_SEQ_CONFIRM,    /* a long press inside the window: reset the password (the press is used up) */
    PRESS_SEQ_CANCEL,     /* a press inside the window that is not a long press: closed (the press is used up) */
} press_seq_result_t;

typedef struct {
    uint64_t t[PRESS_SEQ_COUNT];   /* release times of the last short presses, oldest first */
    uint8_t n;
    bool open;
    uint64_t until_ms;             /* end of the window (exclusive) */
} press_seq_t;

void press_seq_init(press_seq_t *s);
press_seq_result_t press_seq_short(press_seq_t *s, uint64_t now_ms);
press_seq_result_t press_seq_long(press_seq_t *s, uint64_t now_ms);
/* Any other press (a hold): CANCEL if the window was open. */
press_seq_result_t press_seq_other(press_seq_t *s, uint64_t now_ms);
/* The window is open at `now_ms` (an expired window is closed here). */
bool press_seq_is_open(press_seq_t *s, uint64_t now_ms);
/* Time left in the window, 0 when closed. */
uint32_t press_seq_ms_left(press_seq_t *s, uint64_t now_ms);

#ifdef __cplusplus
}
#endif
