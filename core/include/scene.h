/* scene.h — live, motion-reactive scenes (docs/PROTOCOL.md §4 `scene` playlist item, §5b).
 *
 * C11, no allocation, no I/O, no libm. The caller owns all memory: a scene_t (plain struct, can be
 * static) plus one arena whose size scene_arena_bytes() reports. Everything is deterministic given the
 * seed and the sequence of scene_step() inputs (same platform, same compiler flags).
 *
 * Typical firmware loop (see core/README.md "Live scenes"):
 *
 *     scene_params_t p; scene_params_clear(&p);
 *     scene_params_set(&p, "palette", "amber");          // from the playlist item's "params"
 *     scene_params_set_int(&p, "density", 60);
 *     static uint8_t arena[...];                           // >= scene_arena_bytes(kind, 536, 240)
 *     scene_t s;
 *     scene_init(&s, SCENE_SAND, &p, 536, 240, seed, arena, sizeof arena);
 *     every frame:
 *         float g[3]; scene_gravity_from_imu(&SCENE_IMU_AXIS_MAP, ax, ay, az, g);
 *         scene_step(&s, g[0], g[1], g[2], dt_s);
 *         scene_rect_t d; scene_render(&s, fb, 536, 240, &d); flush(d);
 */
#ifndef SCENE_H
#define SCENE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Registry --------------------------------------------------------------------------------- */

typedef enum {
    SCENE_SAND = 0,
    SCENE_WATER,
    SCENE_SNOW,
    SCENE_FIRE,
    SCENE_LAVA,
    SCENE_BALLS,
    SCENE_WORDS,      /* §5b.1: the words of a sheet asset, bouncing with the movement */
    SCENE_KIND_COUNT
} scene_kind_t;

typedef enum { SCENE_PARAM_ENUM = 0, SCENE_PARAM_INT = 1 } scene_param_type_t;

/* One parameter of a scene. ENUM: `values[0..value_count)` are the accepted strings and
 * `values[def]` is the default. INT: accepted range [min, max] (inclusive), default `def`. */
typedef struct {
    const char *name;                 /* JSON key, e.g. "palette" */
    scene_param_type_t type;
    const char *const *values;        /* ENUM only, NULL for INT */
    uint8_t value_count;              /* ENUM only */
    int32_t min, max;                 /* INT only (ENUM: 0 .. value_count-1) */
    int32_t def;                      /* INT: default value; ENUM: index of the default in values[] */
    const char *help;                 /* short English description for UIs */
} scene_param_desc_t;

typedef struct {
    scene_kind_t kind;
    const char *id;                   /* protocol id: "sand", "water", ... */
    const char *name;                 /* display name: "Sand", ... */
    const char *description;          /* one line for pickers */
    const scene_param_desc_t *params;
    uint8_t param_count;
} scene_info_t;

size_t scene_count(void);                              /* == SCENE_KIND_COUNT */
const scene_info_t *scene_info(size_t i);              /* NULL if out of range; index == kind */
const scene_info_t *scene_find(const char *id);        /* by protocol id; NULL if unknown */

/* Write the `GET /scenes` response body (PROTOCOL §4) into buf, NUL-terminated:
 *   {"ok":true,"scenes":[{"id":"sand","name":"Sand","params":{"palette":["amber",...],"density":[10,100],...},
 *                         "defaults":{"palette":"amber","density":50,...}}, ...]}
 * Returns the string length, or 0 if `cap` is too small (buf then holds an empty string). ~1.3 KB today. */
size_t scene_describe_json(char *buf, size_t cap);

/* ---- Parameters ------------------------------------------------------------------------------- */

#define SCENE_PARAMS_MAX 10
#define SCENE_PARAM_KEY_CAP 16        /* including the NUL: keys up to 15 chars */
#define SCENE_PARAM_STR_CAP 16        /* including the NUL: string values up to 15 chars */

typedef struct {
    char key[SCENE_PARAM_KEY_CAP];
    char str[SCENE_PARAM_STR_CAP];    /* string form (for numbers: decimal) */
    int32_t num;                      /* valid when is_num */
    uint8_t is_num;
} scene_kv_t;

/* A flat bag of key/values as received in the playlist item's "params" object. Unknown keys are kept
 * here but ignored by scene_init; bad values fall back to the parameter's default (ints are clamped). */
typedef struct {
    uint8_t count;
    scene_kv_t kv[SCENE_PARAMS_MAX];
} scene_params_t;

void scene_params_clear(scene_params_t *p);
/* Store a string value ("amber", or a numeric string like "60" which is also parsed as a number).
 * Replaces an existing key. Returns false (and stores nothing) if key/value are NULL, empty key, too
 * long, or the bag is full. */
bool scene_params_set(scene_params_t *p, const char *key, const char *value);
bool scene_params_set_int(scene_params_t *p, const char *key, int32_t value);

/* ---- Instances -------------------------------------------------------------------------------- */

typedef struct { int16_t x, y, w, h; } scene_rect_t;   /* w == 0 or h == 0: nothing changed */

typedef enum {
    SCENE_OK = 0,
    SCENE_ERR_ARG,            /* NULL pointer, unknown kind, size out of range */
    SCENE_ERR_ARENA,          /* arena too small or misaligned (must be 4-byte aligned) */
} scene_status_t;

#define SCENE_MIN_DIM 8
#define SCENE_MAX_DIM 2048
#define SCENE_LUT_SIZE 256

/* The instance. Plain data so it can live in static storage; fields are private. */
typedef struct scene {
    /* configuration */
    uint8_t kind;
    uint8_t scale;            /* grid scenes: pixels per cell */
    uint8_t smooth;
    uint8_t palette;          /* index into the internal palette table */
    uint16_t w, h;            /* render area in pixels (top-left of the framebuffer) */
    uint16_t gw, gh;          /* simulation grid */
    int32_t pv[SCENE_PARAMS_MAX];   /* resolved parameter values, in scene_info()->params order */
    /* motion input */
    float g_lp[3];            /* low-passed gravity (g) */
    float g_raw[3];           /* last accepted raw sample */
    float hp[3];              /* high-pass residual, dead-zoned */
    float shake;              /* decaying peak of |hp| (g) */
    float ex, ey;             /* effective in-plane gravity incl. face-up drift (g) */
    float drift_angle;        /* radians; face-up wander direction */
    float kick_cooldown;      /* seconds */
    float acc;                /* fractional sub-step accumulator */
    float acc2;               /* secondary accumulator (spawning etc.) */
    float t;                  /* simulated seconds */
    uint32_t rng;             /* xorshift32 state */
    uint32_t frame;           /* render counter */
    uint32_t steps;           /* CA sub-step counter */
    uint8_t parity;           /* CA "moved this step" bit value */
    uint8_t need_full;        /* next render repaints everything */
    uint8_t has_input;
    uint8_t ready;            /* scene_init succeeded */
    int32_t mass;             /* scene-specific counter (filled cells, flakes, ...) */
    /* arena carve-up */
    uint8_t *cells;           /* gw*gh simulation state */
    uint8_t *shade;           /* gw*gh palette indices prepared for rendering */
    uint16_t *line;           /* one render row (gw*scale pixels) */
    void *extra;              /* scene-specific: flakes, blobs, balls, fire source, lava field */
    size_t extra_bytes;
    /* rendering */
    uint32_t lut32[SCENE_LUT_SIZE];   /* palette index -> RGB565BE pixel duplicated in both halves */
    scene_rect_t last_dirty;
} scene_t;

/* Arena bytes needed for `kind` at w×h in the worst case over all parameter values (smallest grid
 * scale, largest counts). 536×240: at most ~128 KB (lava at scale 2; sand/water/snow/fire 64–77 KB,
 * balls 3 KB). One arena of scene_arena_bytes() for the largest kind fits every scene.
 * Returns 0 for invalid arguments. */
size_t scene_arena_bytes(scene_kind_t kind, uint16_t w, uint16_t h);
/* Exact arena bytes for these parameters. 536×240 with defaults: sand 17 KB, water 23 KB, snow 21 KB,
 * fire 22 KB, lava 33 KB, balls 1.3 KB — small enough for internal SRAM. */
size_t scene_arena_bytes_for(scene_kind_t kind, const scene_params_t *p, uint16_t w, uint16_t h);

/* Initialise `s` (w, h in [SCENE_MIN_DIM, SCENE_MAX_DIM]). `p` may be NULL (all defaults). The arena
 * must be 4-byte aligned and stay valid while the scene is used; it is fully overwritten. */
scene_status_t scene_init(scene_t *s, scene_kind_t kind, const scene_params_t *p, uint16_t w, uint16_t h,
                          uint32_t seed, void *arena, size_t arena_bytes);

/* Advance by dt_s seconds (clamped to [0, 0.05]; 0 only updates the filters) with the gravity vector
 * (gx, gy, gz) in g in the display frame: +x right, +y down, +z out of the glass — i.e. the direction
 * things fall. Upright clip: (0, 1, 0). Lying face up: (0, 0, -1). Non-finite samples are ignored,
 * components are clamped to ±8 g. Internally: 100 ms low-pass for the pile direction, high-pass
 * residual (dead-zoned) for shake kicks, gentle wandering drift when there is little in-plane gravity. */
void scene_step(scene_t *s, float gx, float gy, float gz, float dt_s);

/* Draw into `fb` (RGB565BE, fb_w pixels per row, fb_h rows). The scene occupies the top-left
 * min(w,fb_w) × min(h,fb_h) pixels; nothing outside that is written. `dirty` (may be NULL) receives
 * the changed rectangle relative to the previous render into the same buffer (grid scenes: the whole
 * area; balls: the union of moved regions, possibly empty). Call scene_invalidate() if the buffer's
 * contents were changed by someone else (double buffering, transitions, overlays). */
void scene_render(scene_t *s, uint16_t *fb, uint16_t fb_w, uint16_t fb_h, scene_rect_t *dirty);
void scene_invalidate(scene_t *s);

/* ---- Words (PROTOCOL §5b.1) ---------------------------------------------------------------------- */

#define SCENE_WORDS_MAX    12        /* frames of a sheet (one word each) */
#define SCENE_WORDS_MAX_W  536
#define SCENE_WORDS_MAX_H  240
#define SCENE_WORDS_MAX_PX 514560u   /* N * w * h */

/* Hand a SCENE_WORDS instance its sprites, after scene_init(): `n` frames (1..SCENE_WORDS_MAX) of w x h RGB565BE
 * pixels (w <= 536, h <= 240, n*w*h <= SCENE_WORDS_MAX_PX), black (0x0000) transparent. The caller keeps the pixels
 * alive while the scene is used (the scene reads them when rendering). Each frame's tight box of non-black pixels
 * becomes a word (an axis-aligned rectangle that never rotates); frames without ink are skipped. The words are placed
 * over the upper part of the screen from the seed, apart when there is room, and fall in. Returns the number of
 * words (0: all frames black, the scene shows black), -1 for bad arguments / limits / another kind. Without this
 * call a words scene shows black. */
int scene_words_set_sprites(scene_t *s, const uint16_t *const frames[], int n, uint16_t w, uint16_t h);

/* Scenes that follow the decided panel orientation (the panel flips with them, PROTOCOL §5b.1): `words` only (text
 * must read upright); every other scene is shown upright and gets the true gravity. */
bool scene_follows_orientation(scene_kind_t kind);
/* The gravity vector in the display frame of a flipped panel: (-gx, -gy, gz). For a scene that follows the
 * orientation while the panel is flipped (the framebuffer is turned 180 degrees about z). */
void scene_gravity_flipped(float g[3]);

/* Resolved value of parameter `name` (enum: index into its values[]). False if no such parameter. */
bool scene_param_get(const scene_t *s, const char *name, int32_t *out);

/* ---- IMU axis mapping ------------------------------------------------------------------------- */

/* Signed permutation from the raw accelerometer reading (QMI8658 axes, in g, as the chip reports it:
 * +1 g on the axis pointing *up* at rest) to the display-frame gravity scene_step() wants:
 *     g_display[i] = sum_j m[i][j] * reading[j]
 * The sign flip from "specific force" (up) to "gravity" (down) belongs in this matrix. */
typedef struct { int8_t m[3][3]; } scene_axis_map_t;

/* Board mapping the firmware should pass to scene_gravity_from_imu(). PLACEHOLDER — UNVERIFIED: the
 * QMI8658's mounting orientation on the Waveshare ESP32-S3 1.91" AMOLED relative to the landscape
 * display is not documented (docs/HARDWARE.md), so this is the plain sign flip g = -reading. Bring-up:
 * log one reading upright and one face up, run scene_axis_map_calibrate() on them and replace the
 * value in core/src/scene.c with the result (see core/README.md "Axis mapping"). */
extern const scene_axis_map_t SCENE_IMU_AXIS_MAP;
extern const scene_axis_map_t SCENE_AXIS_MAP_IDENTITY_FLIP;  /* g = -reading (chip axes == display axes) */

void scene_gravity_from_imu(const scene_axis_map_t *map, float ax, float ay, float az, float g_out[3]);

/* Derive the map from two still readings: `upright` (display landscape, readable, vertical) and
 * `face_up` (lying flat, glass toward the sky). Returns false if the readings are not close to two
 * distinct axes (|component| > 0.7 g on one axis each). The display frame is left-handed
 * (x right, y down, z out of the glass); the chip frame is assumed right-handed. */
bool scene_axis_map_calibrate(const float upright[3], const float face_up[3], scene_axis_map_t *out);

#ifdef __cplusplus
}
#endif
#endif /* SCENE_H */
