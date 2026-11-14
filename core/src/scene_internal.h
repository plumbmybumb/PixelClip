/* scene_internal.h — private helpers shared by scene*.c. Not part of the contract. */
#ifndef SCENE_INTERNAL_H
#define SCENE_INTERNAL_H
#include "scene.h"
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
typedef uint32_t __attribute__((__may_alias__)) sc_u32_alias;
#define SC_LIKELY(x) __builtin_expect(!!(x), 1)
#define SC_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
typedef uint32_t sc_u32_alias;
#define SC_LIKELY(x) (x)
#define SC_UNLIKELY(x) (x)
#endif

#define SC_PI 3.14159265f
#define SC_TWO_PI 6.28318531f

/* Parameter slots (order of the descriptors in scene.c). Grid scenes share the first four. */
enum { P_PALETTE = 0, P_AMOUNT = 1, P_SMOOTH = 2, P_SCALE = 3 };          /* sand water snow fire lava */
enum { PB_PALETTE = 0, PB_COUNT = 1, PB_SIZE = 2, PB_BOUNCE = 3, PB_TRAIL = 4 };  /* balls */
enum { PW_BOUNCE = 0 };                                                    /* words */

#define SC_SCALE_MIN 2
#define SC_SCALE_MAX 8
#define SC_BALLS_MAX 24
#define SC_TRAIL_LEN 5
#define SC_LAVA_BLOBS_MAX 20
#define SC_SNOW_FLAKES_MAX 512

/* ---- PRNG (xorshift32) ---------------------------------------------------------------------- */
static inline uint32_t sc_rand(scene_t *s) {
    uint32_t x = s->rng;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return s->rng = x;
}
static inline float sc_randf(scene_t *s) { return (float)(sc_rand(s) >> 8) * (1.0f / 16777216.0f); }  /* [0,1) */
static inline float sc_rands(scene_t *s) { return sc_randf(s) * 2.0f - 1.0f; }                          /* [-1,1) */
/* Uniform integer in [0, n) without division (n < 65536). */
static inline uint32_t sc_randn(scene_t *s, uint32_t n) { return ((sc_rand(s) >> 16) * n) >> 16; }

/* ---- Small float math without libm ---------------------------------------------------------- */
static inline float sc_absf(float x) { return x < 0 ? -x : x; }
static inline float sc_minf(float a, float b) { return a < b ? a : b; }
static inline float sc_maxf(float a, float b) { return a > b ? a : b; }
static inline float sc_clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
static inline int sc_clampi(int x, int lo, int hi) { return x < lo ? lo : (x > hi ? hi : x); }
static inline bool sc_finite(float x) { float d = x - x; return d == d && d == 0.0f; }
float sc_sqrtf(float x);
float sc_atan2f(float y, float x);
float sc_sinf(float x);
static inline float sc_cosf(float x) { return sc_sinf(x + 1.57079633f); }

/* ---- Compass directions (k * 45°, y down: 0 = +x, 2 = +y (down), 4 = -x, 6 = -y) --------------- */
extern const int8_t sc_dx[8], sc_dy[8];

/* Flow geometry for one CA step, derived from the effective gravity (ex, ey). */
typedef struct {
    int k0;            /* floor(angle / 45°) */
    uint32_t p_next;   /* probability (0..65535) of taking k0+1 instead of k0 as the primary move */
    int knear;         /* nearest compass direction */
    int lat_a, lat_b;  /* lateral (level) directions, never uphill */
    uint16_t accept[8];/* water: 65535 if a move along k is not uphill (< ~88° off gravity), else 0 */
    uint8_t cone_mask; /* bit k: within ~50° of gravity (free fall / slide, always allowed) */
    uint8_t hop_mask;  /* bit k: 50°..88° off gravity (a grain may roll over a neighbour if it keeps falling) */
    int outer_y;       /* 1: rows are the outer loop (dominant axis y) */
    int desc_x, desc_y;/* iterate x / y descending */
} sc_flow_t;
/* `downstream_first`: true for falling materials (sand), false for rising heat (fire). */
void sc_flow_make(scene_t *s, sc_flow_t *f, bool downstream_first);

/* ---- Palettes --------------------------------------------------------------------------------- */
enum { PAL_AMBER, PAL_OCEAN, PAL_FOREST, PAL_CANDY, PAL_MONO, PAL_EMBER, PAL_CLASSIC, PAL_BLUE, PAL_EMERALD, PAL_COUNT };
int sc_palette_find(const char *name);                 /* -1 if unknown */
void sc_palette_rgb(int pal, int pos, uint8_t rgb[3]); /* pos 0..255 along the ramp */
uint16_t sc_rgb_be(unsigned r, unsigned g, unsigned b);/* RGB888 -> in-memory RGB565BE */
/* lut32[i] = palette(pal, map[i]) for i in 0..255 (map NULL: identity). */
void sc_lut_build(scene_t *s, const uint8_t *map);
static inline void sc_lut_set(scene_t *s, int i, uint16_t px) { s->lut32[i] = (uint32_t)px * 0x00010001u; }

/* ---- Grid helpers ----------------------------------------------------------------------------- */
/* Render s->shade (gw*gh palette indices) through s->lut32, crisp blocks or smooth. */
void sc_grid_render(scene_t *s, uint16_t *fb, uint16_t fb_w, uint16_t fb_h);

/* ---- Per-kind entry points -------------------------------------------------------------------- */
/* Bytes of the scene-specific `extra` area for a gw×gh grid and resolved params pv[]. */
size_t sc_water_extra(int gw, int gh, const int32_t *pv);
size_t sc_snow_extra(int gw, int gh, const int32_t *pv);
size_t sc_fire_extra(int gw, int gh, const int32_t *pv);
size_t sc_lava_extra(int gw, int gh, const int32_t *pv);
size_t sc_balls_extra(int gw, int gh, const int32_t *pv);
size_t sc_words_extra(int gw, int gh, const int32_t *pv);

void sc_sand_init(scene_t *s);
void sc_water_init(scene_t *s);
void sc_snow_init(scene_t *s);
void sc_fire_init(scene_t *s);
void sc_lava_init(scene_t *s);
void sc_balls_init(scene_t *s);
void sc_words_init(scene_t *s);

/* dt already clamped; s->ex/ey/hp/shake updated. `kick` > 0 on a fresh shake event (strength in g). */
void sc_sand_step(scene_t *s, float dt, float kick);
void sc_water_step(scene_t *s, float dt, float kick);
void sc_snow_step(scene_t *s, float dt, float kick);
void sc_fire_step(scene_t *s, float dt, float kick);
void sc_lava_step(scene_t *s, float dt, float kick);
void sc_balls_step(scene_t *s, float dt, float kick);
void sc_words_step(scene_t *s, float dt, float kick);

/* fill s->shade */
void sc_sand_prepare(scene_t *s);
void sc_water_prepare(scene_t *s);
void sc_snow_prepare(scene_t *s);
void sc_fire_prepare(scene_t *s);
void sc_lava_prepare(scene_t *s);
void sc_balls_render(scene_t *s, uint16_t *fb, uint16_t fb_w, uint16_t fb_h, scene_rect_t *dirty);
/* Test hook: centre and radius of ball i (false if out of range or not a balls scene). */
bool sc_balls_get(const scene_t *s, int i, float *x, float *y, float *r);
void sc_words_render(scene_t *s, uint16_t *fb, uint16_t fb_w, uint16_t fb_h, scene_rect_t *dirty);
/* Test hooks: word i's ink box (top-left, size) and velocity (false if out of range or not a words scene). */
bool sc_words_get(const scene_t *s, int i, float *x, float *y, float *w, float *h);
bool sc_words_speed(const scene_t *s, int i, float *vx, float *vy);

/* Shared by sand/water/snow: fling up to `n` surface cells along the shake direction. */
void sc_grid_fling(scene_t *s, int n, float strength);

static inline size_t sc_align4(size_t n) { return (n + 3u) & ~(size_t)3u; }

#endif /* SCENE_INTERNAL_H */
