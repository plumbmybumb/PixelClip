/* test_ota_gate.c: host unit test for the firmware update permission (components/ota/ota_gate.c, ota_gate.h):
 * an ask opens a 60 s asking window, a short press in it allows updates for 120 s, and every window ends. */
#include "ota_gate.h"

#include <stdio.h>

static int s_fail, s_checks;
#define CHECK(c) do { s_checks++; if (!(c)) { s_fail++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

int main(void)
{
    ota_gate_t g;
    const uint64_t T = 1000000;   /* an arbitrary uptime: nothing may depend on time starting at 0 */

    /* Idle: nothing allowed, no window, a press is not used up. */
    ota_gate_init(&g);
    CHECK(ota_gate_state(&g, T) == OTA_GATE_IDLE);
    CHECK(ota_gate_ms_left(&g, T) == 0 && ota_gate_seconds_left(&g, T) == 0);
    CHECK(!ota_gate_press(&g, T));
    CHECK(ota_gate_state(&g, T) == OTA_GATE_IDLE);

    /* Ask: asking for exactly 60 s (the last millisecond still asking, the 60 000th not). */
    CHECK(ota_gate_ask(&g, T) == OTA_GATE_ASKING);
    CHECK(ota_gate_seconds_left(&g, T) == 60 && ota_gate_ms_left(&g, T) == OTA_GATE_ASK_MS);
    CHECK(ota_gate_seconds_left(&g, T + 1) == 60);
    CHECK(ota_gate_seconds_left(&g, T + 59001) == 1);
    CHECK(ota_gate_state(&g, T + OTA_GATE_ASK_MS - 1) == OTA_GATE_ASKING && ota_gate_ms_left(&g, T + OTA_GATE_ASK_MS - 1) == 1);
    CHECK(ota_gate_state(&g, T + OTA_GATE_ASK_MS) == OTA_GATE_IDLE);
    CHECK(ota_gate_seconds_left(&g, T + OTA_GATE_ASK_MS) == 0);
    /* A press after the asking window ran out is not used up, and allows nothing. */
    CHECK(!ota_gate_press(&g, T + OTA_GATE_ASK_MS));
    CHECK(ota_gate_state(&g, T + OTA_GATE_ASK_MS) == OTA_GATE_IDLE);

    /* Asking again restarts the window from the new ask. */
    ota_gate_init(&g);
    ota_gate_ask(&g, T);
    CHECK(ota_gate_ask(&g, T + 50000) == OTA_GATE_ASKING);
    CHECK(ota_gate_seconds_left(&g, T + 50000) == 60);
    CHECK(ota_gate_state(&g, T + 50000 + OTA_GATE_ASK_MS - 1) == OTA_GATE_ASKING);
    CHECK(ota_gate_state(&g, T + 50000 + OTA_GATE_ASK_MS) == OTA_GATE_IDLE);

    /* A press while asking allows for 120 s from the press; the press is used up. */
    ota_gate_init(&g);
    ota_gate_ask(&g, T);
    CHECK(ota_gate_press(&g, T + OTA_GATE_ASK_MS - 1));   /* the last moment of the asking window still counts */
    const uint64_t P = T + OTA_GATE_ASK_MS - 1;
    CHECK(ota_gate_state(&g, P) == OTA_GATE_ALLOWED && ota_gate_seconds_left(&g, P) == 120);
    /* A second press while allowed is not used up (it keeps its normal meaning) and does not extend anything. */
    CHECK(!ota_gate_press(&g, P + 1000));
    CHECK(ota_gate_ms_left(&g, P + 1000) == OTA_GATE_ALLOW_MS - 1000);
    /* Asking while allowed changes nothing. */
    CHECK(ota_gate_ask(&g, P + 2000) == OTA_GATE_ALLOWED);
    CHECK(ota_gate_ms_left(&g, P + 2000) == OTA_GATE_ALLOW_MS - 2000);
    /* Allowed for exactly 120 s, then idle; an ask after that asks again. */
    CHECK(ota_gate_state(&g, P + OTA_GATE_ALLOW_MS - 1) == OTA_GATE_ALLOWED);
    CHECK(ota_gate_state(&g, P + OTA_GATE_ALLOW_MS) == OTA_GATE_IDLE);
    CHECK(ota_gate_ask(&g, P + OTA_GATE_ALLOW_MS) == OTA_GATE_ASKING);

    /* The session ends (or an image is accepted): back to idle at once, from either window. */
    ota_gate_init(&g);
    ota_gate_ask(&g, T);
    ota_gate_clear(&g);
    CHECK(ota_gate_state(&g, T) == OTA_GATE_IDLE && !ota_gate_press(&g, T + 1));
    ota_gate_ask(&g, T);
    ota_gate_press(&g, T + 10);
    CHECK(ota_gate_state(&g, T + 10) == OTA_GATE_ALLOWED);
    ota_gate_clear(&g);
    CHECK(ota_gate_state(&g, T + 11) == OTA_GATE_IDLE && ota_gate_seconds_left(&g, T + 11) == 0);

    /* A failed upload is not an event of the gate: the permission simply runs on (nothing to call). Checked
     * here as "reading the state many times changes nothing". */
    ota_gate_init(&g);
    ota_gate_ask(&g, T);
    ota_gate_press(&g, T);
    for (uint64_t t = T; t < T + OTA_GATE_ALLOW_MS; t += 7919) CHECK(ota_gate_state(&g, t) == OTA_GATE_ALLOWED);
    CHECK(ota_gate_state(&g, T + OTA_GATE_ALLOW_MS) == OTA_GATE_IDLE);

    printf("%d checks, %d failed\n", s_checks, s_fail);
    return s_fail ? 1 : 0;
}
