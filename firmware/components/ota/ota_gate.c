/* ota_gate.c: the update permission state machine (ota_gate.h). Pure C: no ESP-IDF. */
#include "ota_gate.h"

void ota_gate_init(ota_gate_t *g)
{
    g->state = OTA_GATE_IDLE;
    g->until_ms = 0;
}

ota_gate_state_t ota_gate_state(ota_gate_t *g, uint64_t now_ms)
{
    if (g->state != OTA_GATE_IDLE && now_ms >= g->until_ms) ota_gate_init(g);
    return g->state;
}

uint32_t ota_gate_ms_left(ota_gate_t *g, uint64_t now_ms)
{
    if (ota_gate_state(g, now_ms) == OTA_GATE_IDLE) return 0;
    return (uint32_t)(g->until_ms - now_ms);   /* at most OTA_GATE_ALLOW_MS */
}

uint32_t ota_gate_seconds_left(ota_gate_t *g, uint64_t now_ms)
{
    return (ota_gate_ms_left(g, now_ms) + 999u) / 1000u;
}

ota_gate_state_t ota_gate_ask(ota_gate_t *g, uint64_t now_ms)
{
    if (ota_gate_state(g, now_ms) == OTA_GATE_ALLOWED) return OTA_GATE_ALLOWED;
    g->state = OTA_GATE_ASKING;
    g->until_ms = now_ms + OTA_GATE_ASK_MS;
    return OTA_GATE_ASKING;
}

bool ota_gate_press(ota_gate_t *g, uint64_t now_ms)
{
    if (ota_gate_state(g, now_ms) != OTA_GATE_ASKING) return false;
    g->state = OTA_GATE_ALLOWED;
    g->until_ms = now_ms + OTA_GATE_ALLOW_MS;
    return true;
}

void ota_gate_clear(ota_gate_t *g)
{
    ota_gate_init(g);
}
