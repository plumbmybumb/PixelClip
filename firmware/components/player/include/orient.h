/* orient.h — 180° screen flip (PROTOCOL §4 "Orientation"): config `orientation` = auto | normal | flipped.
 *
 * auto: the low-passed display-frame gravity (imu_get_gravity_lp, PROTOCOL §5b) with gy < -0.5 for 1 s
 * continuously flips the screen, gy > +0.5 for 1 s flips it back, anything in between keeps the current
 * state. The detector runs as the IMU task's per-sample hook (no task of its own): 10 Hz background
 * sampling while the mode is auto, 50 Hz while a scene or GET /imu holds the IMU. A decision is handed to
 * the player task (one queue command), which turns the panel over between two frames
 * (display_set_flipped: MADCTL + one full re-send of the framebuffer). The framebuffer never changes. */
#pragma once
#include <stdbool.h>
#include "appcfg.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Boot, after display_init() and imu_init(), before anything is drawn: applies `mode`. In auto it takes a
 * ~0.1 s gravity reading first and starts flipped if gy < -0.5 already ("boot starts normal unless gravity
 * already says otherwise"). */
void orient_init(appcfg_orientation_t mode);

/* PUT /config (HTTP and BLE fast lane): apply a new mode at once. auto keeps the current orientation until
 * gravity decides; normal / flipped force it. */
void orient_set_mode(appcfg_orientation_t mode);
appcfg_orientation_t orient_mode(void);

/* The orientation decided now (true = turned 180°), as /status and GET /imu report it. The panel follows
 * within a frame (the player applies it); scenes use display_is_flipped(), what the panel really shows. */
bool orient_flipped(void);

#ifdef __cplusplus
}
#endif
