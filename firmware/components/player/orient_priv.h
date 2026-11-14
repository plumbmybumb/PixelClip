/* orient_priv.h — glue between orient.c and player.c (components/player only). */
#pragma once
#include <stdbool.h>
#include <stdint.h>

/* orient.c -> player.c: queue CMD_ORIENT, waiting at most `wait_ms` for room (0 from the IMU task).
 * 1 = queued, 0 = queue full (retry later), -1 = no player task (the caller applies it itself). */
int player_orient_post(uint32_t wait_ms);

/* player.c (player task, CMD_ORIENT) -> orient.c: make the panel show the wanted orientation. */
void orient_apply(bool flipped);   /* player task: set the panel; player.c decides (scenes stay upright) */
