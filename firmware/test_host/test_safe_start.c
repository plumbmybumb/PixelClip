/* test_safe_start.c — host unit test for the safe-start rule (components/health/health_safe.c, health.h):
 * three early crashes in a row start the clip without its stored playlist; nothing else does. */
#include "health_safe.h"

#include <stdio.h>

static int s_fail, s_checks;
#define CHECK(c) do { s_checks++; if (!(c)) { s_fail++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

/* One boot: returns whether it starts safe; *streak is carried from boot to boot (RTC memory on the clip). */
static bool boot(uint32_t *streak, bool crash, bool radio_only, bool prev_known, uint32_t prev_up_s)
{
    const health_safe_in_t in = { .crash = crash, .radio_only = radio_only, .prev_known = prev_known, .prev_up_s = prev_up_s };
    bool safe = true;
    *streak = health_safe_rule(*streak, &in, &safe);
    return safe;
}

#define CRASH(up)   boot(&streak, true, false, true, (up))    /* a panic / watchdog reset of a run that lived `up` s */
#define ORDINARY()  boot(&streak, false, false, true, 3)      /* power-on, RESET key, USB / flashing, OTA restart, ... */

int main(void)
{
    uint32_t streak = 0;

    /* Three early crashes in a row: the third such boot starts safe, and the count starts again. */
    CHECK(!CRASH(2) && streak == 1);
    CHECK(!CRASH(0) && streak == 2);
    CHECK(CRASH(5) && streak == 0);
    /* Still crashing afterwards (it was not the playlist): the next safe start is three crashes away again. */
    CHECK(!CRASH(2) && !CRASH(2) && CRASH(2));

    /* Ordinary resets never trigger it, however many and however short the runs. */
    streak = 0;
    for (int i = 0; i < 50; i++) CHECK(!ORDINARY() && streak == 0);

    /* An ordinary reset between crashes ends the streak (RESET key, a flash, the restart after an OTA). */
    streak = 0;
    CHECK(!CRASH(2) && !CRASH(2) && streak == 2);
    CHECK(!ORDINARY() && streak == 0);
    CHECK(!CRASH(2) && !CRASH(2) && streak == 2);

    /* A healthy run clears it: a crash after HEALTH_SAFE_START_WINDOW_S of life is not "early". */
    CHECK(!CRASH(HEALTH_SAFE_START_WINDOW_S) && streak == 0);
    CHECK(!CRASH(2) && !CRASH(2) && !CRASH(3600) && streak == 0);
    CHECK(!CRASH(HEALTH_SAFE_START_WINDOW_S - 1) && streak == 1);

    /* A watchdog reset blamed only on the radio tasks does not count, and ends the streak. */
    streak = 0;
    CHECK(!CRASH(2) && !CRASH(2));
    CHECK(!boot(&streak, true, true, true, 2) && streak == 0);

    /* No breadcrumbs from the previous run (RTC memory lost: a power loss): not counted. */
    streak = 2;
    CHECK(!boot(&streak, true, false, false, 0) && streak == 0);

    /* A hang at boot that the watchdog ends minutes later: the last sign of life was early, so it counts. */
    streak = 0;
    CHECK(!CRASH(1) && !CRASH(1) && CRASH(1));

    printf("%d checks, %d failed\n", s_checks, s_fail);
    return s_fail ? 1 : 0;
}
