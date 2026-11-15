/* press_seq.c: the password reset gesture detector (press_seq.h). Pure C: no ESP-IDF. */
#include "press_seq.h"

#include <string.h>

void press_seq_init(press_seq_t *s)
{
    memset(s, 0, sizeof *s);
}

bool press_seq_is_open(press_seq_t *s, uint64_t now_ms)
{
    if (s->open && now_ms >= s->until_ms) s->open = false;
    return s->open;
}

uint32_t press_seq_ms_left(press_seq_t *s, uint64_t now_ms)
{
    return press_seq_is_open(s, now_ms) ? (uint32_t)(s->until_ms - now_ms) : 0;
}

press_seq_result_t press_seq_short(press_seq_t *s, uint64_t now_ms)
{
    if (press_seq_is_open(s, now_ms)) {
        press_seq_init(s);
        return PRESS_SEQ_CANCEL;
    }
    if (s->n == PRESS_SEQ_COUNT) {
        memmove(&s->t[0], &s->t[1], sizeof s->t[0] * (PRESS_SEQ_COUNT - 1));
        s->n--;
    }
    s->t[s->n++] = now_ms;
    if (s->n == PRESS_SEQ_COUNT && now_ms - s->t[0] <= PRESS_SEQ_SPAN_MS) {
        press_seq_init(s);
        s->open = true;
        s->until_ms = now_ms + PRESS_SEQ_WINDOW_MS;
        return PRESS_SEQ_OPEN;
    }
    return PRESS_SEQ_NONE;
}

press_seq_result_t press_seq_long(press_seq_t *s, uint64_t now_ms)
{
    const bool open = press_seq_is_open(s, now_ms);
    press_seq_init(s);
    return open ? PRESS_SEQ_CONFIRM : PRESS_SEQ_NONE;
}

press_seq_result_t press_seq_other(press_seq_t *s, uint64_t now_ms)
{
    const bool open = press_seq_is_open(s, now_ms);
    press_seq_init(s);
    return open ? PRESS_SEQ_CANCEL : PRESS_SEQ_NONE;
}
