/* ota_gate.h: the button permission for firmware updates (PROTOCOL §4 "Firmware update"), pure: no ESP-IDF,
 * time comes in as a parameter, so it is host-tested (test_host/test_ota_gate.c). The thread-safe wrapper the
 * firmware uses is ota_permission_*() in ota.h.
 *
 * idle --ask--> asking (OTA_GATE_ASK_MS) --short press--> allowed (OTA_GATE_ALLOW_MS) --image accepted--> idle
 * Asking again restarts the asking window; asking while allowed changes nothing. Each window ends on its own
 * (back to idle), and ota_gate_clear() ends either at once (the WiFi session ended, an image was accepted).
 * A failed upload does not touch the gate: the permission runs on until its own expiry. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OTA_GATE_ASK_MS   60000u
#define OTA_GATE_ALLOW_MS 120000u

typedef enum { OTA_GATE_IDLE = 0, OTA_GATE_ASKING, OTA_GATE_ALLOWED } ota_gate_state_t;

typedef struct {
    ota_gate_state_t state;
    uint64_t until_ms;   /* end of the asking / allowed window (exclusive) */
} ota_gate_t;

void ota_gate_init(ota_gate_t *g);
/* The state at `now_ms` (an expired window reads as idle, and is cleared). */
ota_gate_state_t ota_gate_state(ota_gate_t *g, uint64_t now_ms);
/* What is left of the current asking or allowed window: 0 when idle. */
uint32_t ota_gate_ms_left(ota_gate_t *g, uint64_t now_ms);
/* The same in whole seconds, rounded up (60 right after an ask, 0 only when idle). */
uint32_t ota_gate_seconds_left(ota_gate_t *g, uint64_t now_ms);
/* Start or restart the asking window, unless already allowed. Returns the state afterwards. */
ota_gate_state_t ota_gate_ask(ota_gate_t *g, uint64_t now_ms);
/* A short press: true (the press is used up) if it turned asking into allowed, false otherwise. */
bool ota_gate_press(ota_gate_t *g, uint64_t now_ms);
/* Back to idle at once. */
void ota_gate_clear(ota_gate_t *g);

#ifdef __cplusplus
}
#endif
