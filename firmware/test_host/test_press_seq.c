/* test_press_seq.c: host unit test for the hotspot password reset gesture (components/button/press_seq.c,
 * press_seq.h): five short presses within 3 s open a 10 s window, a long press in it confirms, anything else
 * cancels. */
#include "press_seq.h"

#include <stdio.h>

static int s_fail, s_checks;
#define CHECK(c) do { s_checks++; if (!(c)) { s_fail++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

/* Five short presses at t0, t0 + step, ...: the result of the last one. */
static press_seq_result_t five(press_seq_t *s, uint64_t t0, uint64_t step)
{
    press_seq_result_t r = PRESS_SEQ_NONE;
    for (int i = 0; i < PRESS_SEQ_COUNT; i++) {
        r = press_seq_short(s, t0 + (uint64_t)i * step);
        if (i < PRESS_SEQ_COUNT - 1) CHECK(r == PRESS_SEQ_NONE);
    }
    return r;
}

int main(void)
{
    press_seq_t s;
    const uint64_t T = 5000000;

    /* Nothing open: long presses and holds keep their meaning. */
    press_seq_init(&s);
    CHECK(press_seq_long(&s, T) == PRESS_SEQ_NONE);
    CHECK(press_seq_other(&s, T) == PRESS_SEQ_NONE);
    CHECK(!press_seq_is_open(&s, T) && press_seq_ms_left(&s, T) == 0);

    /* Five within 3 s (exactly 3000 ms from the first release to the fifth) open the window. */
    press_seq_init(&s);
    CHECK(five(&s, T, 750) == PRESS_SEQ_OPEN);
    CHECK(press_seq_is_open(&s, T + 3000) && press_seq_ms_left(&s, T + 3000) == PRESS_SEQ_WINDOW_MS);
    /* A long press inside it confirms, once. */
    CHECK(press_seq_long(&s, T + 3000 + PRESS_SEQ_WINDOW_MS - 1) == PRESS_SEQ_CONFIRM);
    CHECK(!press_seq_is_open(&s, T + 3000 + PRESS_SEQ_WINDOW_MS - 1));
    CHECK(press_seq_long(&s, T + 3000 + PRESS_SEQ_WINDOW_MS) == PRESS_SEQ_NONE);

    /* 3001 ms is too slow: nothing opens. */
    press_seq_init(&s);
    CHECK(five(&s, T, 3001 / 4 + 1) == PRESS_SEQ_NONE);   /* 4 gaps of 751 ms = 3004 ms */
    CHECK(!press_seq_is_open(&s, T + 4000));

    /* A sliding count: a slow start followed by a quick run still opens on the fifth quick press. */
    press_seq_init(&s);
    CHECK(press_seq_short(&s, T) == PRESS_SEQ_NONE);
    CHECK(press_seq_short(&s, T + 5000) == PRESS_SEQ_NONE);
    CHECK(five(&s, T + 10000, 300) == PRESS_SEQ_OPEN);

    /* The window runs out: closed after exactly 10 s, and a long press then keeps its normal meaning. */
    press_seq_init(&s);
    CHECK(five(&s, T, 200) == PRESS_SEQ_OPEN);
    const uint64_t O = T + 800;
    CHECK(press_seq_is_open(&s, O + PRESS_SEQ_WINDOW_MS - 1));
    CHECK(!press_seq_is_open(&s, O + PRESS_SEQ_WINDOW_MS));
    CHECK(press_seq_long(&s, O + PRESS_SEQ_WINDOW_MS) == PRESS_SEQ_NONE);

    /* A short press inside the window cancels it (and is used up); a long press after that does nothing. */
    press_seq_init(&s);
    five(&s, T, 200);
    CHECK(press_seq_short(&s, O + 2000) == PRESS_SEQ_CANCEL);
    CHECK(!press_seq_is_open(&s, O + 2001));
    CHECK(press_seq_long(&s, O + 3000) == PRESS_SEQ_NONE);
    /* The cancelling press does not count towards a new sequence: four more presses are not enough. */
    for (int i = 1; i <= 4; i++) CHECK(press_seq_short(&s, O + 2000 + (uint64_t)i * 100) == PRESS_SEQ_NONE);
    CHECK(press_seq_short(&s, O + 2500) == PRESS_SEQ_OPEN);

    /* A sixth quick press right after the window opened cancels it (the window wants a long press). */
    press_seq_init(&s);
    five(&s, T, 200);
    CHECK(press_seq_short(&s, T + 1000) == PRESS_SEQ_CANCEL);

    /* A hold inside the window cancels it. */
    press_seq_init(&s);
    five(&s, T, 200);
    CHECK(press_seq_other(&s, O + 6000) == PRESS_SEQ_CANCEL);
    CHECK(!press_seq_is_open(&s, O + 6000));

    /* A long press in the middle of the count starts it again. */
    press_seq_init(&s);
    for (int i = 0; i < 4; i++) press_seq_short(&s, T + (uint64_t)i * 100);
    CHECK(press_seq_long(&s, T + 2000) == PRESS_SEQ_NONE);
    /* The four before the long press no longer count: the fifth short press after it opens, not the first. */
    for (int i = 0; i < PRESS_SEQ_COUNT - 1; i++) CHECK(press_seq_short(&s, T + 2100 + (uint64_t)i * 100) == PRESS_SEQ_NONE);
    CHECK(press_seq_short(&s, T + 2500) == PRESS_SEQ_OPEN);

    /* An expired window does not swallow the next short press: it counts as the first of a new sequence. */
    press_seq_init(&s);
    five(&s, T, 200);
    CHECK(press_seq_short(&s, O + PRESS_SEQ_WINDOW_MS) == PRESS_SEQ_NONE);
    for (int i = 1; i < PRESS_SEQ_COUNT - 1; i++) CHECK(press_seq_short(&s, O + PRESS_SEQ_WINDOW_MS + (uint64_t)i * 100) == PRESS_SEQ_NONE);
    CHECK(press_seq_short(&s, O + PRESS_SEQ_WINDOW_MS + 400) == PRESS_SEQ_OPEN);

    printf("%d checks, %d failed\n", s_checks, s_fail);
    return s_fail ? 1 : 0;
}
