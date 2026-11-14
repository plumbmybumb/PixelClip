/* scene.c — live scenes: registry, parameters, palettes, IMU conditioning, grid renderer, axis map.
 * The simulations live in scene_grid.c (sand, water, snow), scene_fire.c (fire, lava), scene_balls.c and
 * scene_words.c. See include/scene.h for the contract and core/README.md for the firmware recipe.
 */
#include "scene_internal.h"

/* ------------------------------------------------------------------------------------------ */
/* Math (no libm: the library promises only string.h/stdint.h/stddef.h/stdbool.h)              */

float sc_sqrtf(float x) {
    if (!(x > 0.0f)) return 0.0f;
    uint32_t i;
    memcpy(&i, &x, 4);
    i = 0x5F375A86u - (i >> 1);
    float y;
    memcpy(&y, &i, 4);
    y = y * (1.5f - 0.5f * x * y * y);
    y = y * (1.5f - 0.5f * x * y * y);
    y = y * (1.5f - 0.5f * x * y * y);
    return x * y;
}

float sc_atan2f(float y, float x) {
    float ax = sc_absf(x), ay = sc_absf(y);
    if (ax < 1e-20f && ay < 1e-20f) return 0.0f;
    float a = (ax < ay) ? ax / ay : ay / ax;
    float s = a * a;
    float r = ((-0.0464964749f * s + 0.15931422f) * s - 0.327622764f) * s * a + a;
    if (ay > ax) r = 1.57079633f - r;
    if (x < 0) r = SC_PI - r;
    if (y < 0) r = -r;
    return r;
}

float sc_sinf(float x) {
    /* range-reduce to [-pi, pi] then a 7th-order odd polynomial (max error ~1e-4) */
    float k = x * (1.0f / SC_TWO_PI);
    int n = (int)(k + (k >= 0 ? 0.5f : -0.5f));
    x -= (float)n * SC_TWO_PI;
    if (x > 1.57079633f) x = SC_PI - x;
    else if (x < -1.57079633f) x = -SC_PI - x;
    float x2 = x * x;
    return x * (1.0f + x2 * (-0.166666667f + x2 * (0.00833333333f + x2 * -0.000198412698f)));
}

/* ------------------------------------------------------------------------------------------ */
/* Palettes: defined once as gradient ramps from black (0) to the brightest tone (255).        */

typedef struct { uint8_t pos, r, g, b; } sc_stop_t;
typedef struct { const char *name; uint8_t n; sc_stop_t st[8]; } sc_pal_t;

static const sc_pal_t k_pal[PAL_COUNT] = {
    /* PixelClip brand amber #FFBE00 family */
    [PAL_AMBER] = { "amber", 6, { { 0, 0, 0, 0 }, { 50, 0x2A, 0x10, 0x00 }, { 115, 0x8A, 0x45, 0x00 },
                                  { 180, 0xE0, 0x96, 0x00 }, { 220, 0xFF, 0xBE, 0x00 }, { 255, 0xFF, 0xEC, 0xA8 } } },
    [PAL_OCEAN] = { "ocean", 6, { { 0, 0, 0, 0 }, { 50, 0x00, 0x12, 0x33 }, { 115, 0x00, 0x42, 0x8C },
                                  { 180, 0x08, 0x86, 0xD8 }, { 220, 0x30, 0xC8, 0xF0 }, { 255, 0xD0, 0xF8, 0xFF } } },
    [PAL_FOREST] = { "forest", 6, { { 0, 0, 0, 0 }, { 50, 0x08, 0x1C, 0x08 }, { 115, 0x1A, 0x5C, 0x18 },
                                    { 180, 0x48, 0xA0, 0x2C }, { 220, 0x8C, 0xD2, 0x46 }, { 255, 0xE8, 0xF8, 0xB0 } } },
    [PAL_CANDY] = { "candy", 7, { { 0, 0, 0, 0 }, { 45, 0x34, 0x08, 0x3C }, { 100, 0xC8, 0x2C, 0x80 },
                                  { 150, 0xFF, 0x6E, 0xB4 }, { 190, 0x96, 0x6E, 0xFF }, { 225, 0x46, 0xE6, 0xC8 },
                                  { 255, 0xFF, 0xF2, 0xA0 } } },
    [PAL_MONO] = { "mono", 4, { { 0, 0, 0, 0 }, { 80, 0x26, 0x28, 0x2E }, { 170, 0x96, 0x9A, 0xA4 },
                                { 255, 0xFF, 0xFF, 0xFF } } },
    [PAL_EMBER] = { "ember", 6, { { 0, 0, 0, 0 }, { 55, 0x30, 0x02, 0x00 }, { 120, 0x9C, 0x12, 0x00 },
                                  { 180, 0xF0, 0x50, 0x00 }, { 225, 0xFF, 0x9A, 0x1E }, { 255, 0xFF, 0xE0, 0x8C } } },
    /* fire palettes (Doom-fire style ramps) */
    [PAL_CLASSIC] = { "classic", 8, { { 0, 0, 0, 0 }, { 35, 0x2F, 0x0F, 0x07 }, { 75, 0x8F, 0x27, 0x07 },
                                      { 115, 0xC7, 0x47, 0x07 }, { 155, 0xDF, 0x6F, 0x07 }, { 195, 0xD7, 0x9F, 0x1F },
                                      { 230, 0xE7, 0xD7, 0x7F }, { 255, 0xFF, 0xFF, 0xF0 } } },
    [PAL_BLUE] = { "blue", 7, { { 0, 0, 0, 0 }, { 40, 0x04, 0x04, 0x2A }, { 90, 0x0A, 0x1A, 0x8C },
                                { 140, 0x1E, 0x50, 0xFF }, { 190, 0x40, 0xA8, 0xFF }, { 230, 0xA8, 0xE8, 0xFF },
                                { 255, 0xFF, 0xFF, 0xFF } } },
    [PAL_EMERALD] = { "emerald", 7, { { 0, 0, 0, 0 }, { 40, 0x02, 0x18, 0x0A }, { 90, 0x04, 0x4C, 0x26 },
                                      { 140, 0x08, 0x9C, 0x4C }, { 190, 0x34, 0xE0, 0x84 }, { 230, 0xB0, 0xFF, 0xD0 },
                                      { 255, 0xFF, 0xFF, 0xFF } } },
};

static int lower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
static bool streq_ci(const char *a, const char *b) {
    while (*a && *b) {
        if (lower((unsigned char)*a) != lower((unsigned char)*b)) return false;
        a++, b++;
    }
    return *a == *b;
}

int sc_palette_find(const char *name) {
    if (!name) return -1;
    for (int i = 0; i < PAL_COUNT; i++)
        if (streq_ci(name, k_pal[i].name)) return i;
    return -1;
}

void sc_palette_rgb(int pal, int pos, uint8_t rgb[3]) {
    if (pal < 0 || pal >= PAL_COUNT) pal = PAL_MONO;
    pos = sc_clampi(pos, 0, 255);
    const sc_pal_t *p = &k_pal[pal];
    int i = 0;
    while (i + 2 < p->n && pos > p->st[i + 1].pos) i++;
    const sc_stop_t *a = &p->st[i], *b = &p->st[i + 1];
    int span = b->pos - a->pos;
    int t = span > 0 ? ((pos - a->pos) * 256) / span : 256;
    t = sc_clampi(t, 0, 256);
    rgb[0] = (uint8_t)((a->r * (256 - t) + b->r * t) >> 8);
    rgb[1] = (uint8_t)((a->g * (256 - t) + b->g * t) >> 8);
    rgb[2] = (uint8_t)((a->b * (256 - t) + b->b * t) >> 8);
}

uint16_t sc_rgb_be(unsigned r, unsigned g, unsigned b) {
    unsigned v = (((r * 31u + 127u) / 255u) << 11) | (((g * 63u + 127u) / 255u) << 5) | ((b * 31u + 127u) / 255u);
    union { uint8_t b[2]; uint16_t v; } u;
    u.b[0] = (uint8_t)(v >> 8);
    u.b[1] = (uint8_t)v;
    return u.v;
}

void sc_lut_build(scene_t *s, const uint8_t *map) {
    for (int i = 0; i < SCENE_LUT_SIZE; i++) {
        uint8_t rgb[3];
        sc_palette_rgb(s->palette, map ? map[i] : i, rgb);
        sc_lut_set(s, i, sc_rgb_be(rgb[0], rgb[1], rgb[2]));
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Registry                                                                                    */

static const char *const k_pal_general[] = { "amber", "ocean", "forest", "candy", "mono", "ember" };
static const char *const k_pal_fire[] = { "classic", "blue", "emerald" };

#define PD_PAL(def) { "palette", SCENE_PARAM_ENUM, k_pal_general, 6, 0, 5, def, "Colour palette" }
#define PD_SMOOTH(def) { "smooth", SCENE_PARAM_INT, NULL, 0, 0, 1, def, "1 = soft bilinear look, 0 = crisp pixel blocks" }
#define PD_SCALE { "scale", SCENE_PARAM_INT, NULL, 0, SC_SCALE_MIN, SC_SCALE_MAX, 4, "Pixels per simulation cell (smaller = finer, slower)" }

static const scene_param_desc_t k_sand_params[] = {
    PD_PAL(0),
    { "density", SCENE_PARAM_INT, NULL, 0, 10, 100, 50, "Amount of sand" },
    PD_SMOOTH(0), PD_SCALE,
};
static const scene_param_desc_t k_water_params[] = {
    PD_PAL(1),
    { "density", SCENE_PARAM_INT, NULL, 0, 10, 100, 50, "Amount of water" },
    PD_SMOOTH(0), PD_SCALE,
};
static const scene_param_desc_t k_snow_params[] = {
    PD_PAL(4),
    { "density", SCENE_PARAM_INT, NULL, 0, 10, 100, 50, "Snowfall strength and drift size" },
    PD_SMOOTH(0), PD_SCALE,
};
static const scene_param_desc_t k_fire_params[] = {
    { "palette", SCENE_PARAM_ENUM, k_pal_fire, 3, 0, 2, 0, "Flame colour: classic, blue gas, emerald" },
    { "intensity", SCENE_PARAM_INT, NULL, 0, 10, 100, 70, "Flame height" },
    PD_SMOOTH(1), PD_SCALE,
};
static const scene_param_desc_t k_lava_params[] = {
    PD_PAL(5),
    { "density", SCENE_PARAM_INT, NULL, 0, 10, 100, 50, "Number of blobs" },
    PD_SMOOTH(1), PD_SCALE,
};
static const scene_param_desc_t k_balls_params[] = {
    PD_PAL(3),
    { "count", SCENE_PARAM_INT, NULL, 0, 6, SC_BALLS_MAX, 12, "Number of balls" },
    { "size", SCENE_PARAM_INT, NULL, 0, 6, 40, 16, "Ball radius in pixels (shrunk to fit)" },
    { "bounce", SCENE_PARAM_INT, NULL, 0, 60, 90, 75, "Restitution in percent" },
    { "trail", SCENE_PARAM_INT, NULL, 0, 0, 1, 0, "1 = short motion trail" },
};
static const scene_param_desc_t k_words_params[] = {
    { "bounce", SCENE_PARAM_INT, NULL, 0, 0, 100, 60, "Restitution in percent" },
};

#define NPARAMS(a) ((uint8_t)(sizeof(a) / sizeof((a)[0])))
static const scene_info_t k_scenes[SCENE_KIND_COUNT] = {
    { SCENE_SAND, "sand", "Sand", "Falling sand that piles up and pours as you tilt", k_sand_params, NPARAMS(k_sand_params) },
    { SCENE_WATER, "water", "Water", "Water that sloshes, levels out and sparkles", k_water_params, NPARAMS(k_water_params) },
    { SCENE_SNOW, "snow", "Snow", "Snowflakes drifting into piles", k_snow_params, NPARAMS(k_snow_params) },
    { SCENE_FIRE, "fire", "Fire", "Flames that lean and climb as you tilt", k_fire_params, NPARAMS(k_fire_params) },
    { SCENE_LAVA, "lava", "Lava", "Slow glowing lava-lamp blobs", k_lava_params, NPARAMS(k_lava_params) },
    { SCENE_BALLS, "balls", "Balls", "Bouncy balls that knock against the edges", k_balls_params, NPARAMS(k_balls_params) },
    { SCENE_WORDS, "words", "Words", "Your words, bouncing with the movement (needs a sheet id)", k_words_params,
      NPARAMS(k_words_params) },
};

size_t scene_count(void) { return SCENE_KIND_COUNT; }
const scene_info_t *scene_info(size_t i) { return i < SCENE_KIND_COUNT ? &k_scenes[i] : NULL; }
const scene_info_t *scene_find(const char *id) {
    if (!id) return NULL;
    for (size_t i = 0; i < SCENE_KIND_COUNT; i++)
        if (!strcmp(id, k_scenes[i].id)) return &k_scenes[i];
    return NULL;
}

/* ------------------------------------------------------------------------------------------ */
/* Parameters                                                                                  */

static size_t bounded_len(const char *s, size_t cap) {
    size_t n = 0;
    while (n < cap && s[n]) n++;
    return n;
}

/* Parse a decimal integer, optionally with a fractional part that is truncated ("60", "-3", "12.5").
 * Saturates at the int32 range. */
static bool parse_num(const char *s, int32_t *out) {
    int neg = 0;
    if (*s == '-' || *s == '+') neg = (*s++ == '-');
    if (*s < '0' || *s > '9') return false;
    int64_t v = 0;
    while (*s >= '0' && *s <= '9') {
        if (v < 4000000000LL) v = v * 10 + (*s - '0');
        s++;
    }
    if (*s == '.') {
        s++;
        while (*s >= '0' && *s <= '9') s++;
    }
    if (*s) return false;
    if (neg) v = -v;
    if (v > INT32_MAX) v = INT32_MAX;
    if (v < INT32_MIN) v = INT32_MIN;
    *out = (int32_t)v;
    return true;
}

static void fmt_int(char *buf, int32_t v) {   /* buf >= 12 bytes */
    char tmp[12];
    int n = 0;
    uint32_t u = v < 0 ? (uint32_t)(-(int64_t)v) : (uint32_t)v;
    do { tmp[n++] = (char)('0' + u % 10u); u /= 10u; } while (u);
    int o = 0;
    if (v < 0) buf[o++] = '-';
    while (n) buf[o++] = tmp[--n];
    buf[o] = 0;
}

void scene_params_clear(scene_params_t *p) {
    if (p) memset(p, 0, sizeof *p);
}

static scene_kv_t *params_slot(scene_params_t *p, const char *key) {
    for (uint8_t i = 0; i < p->count && i < SCENE_PARAMS_MAX; i++)
        if (!strcmp(p->kv[i].key, key)) return &p->kv[i];
    if (p->count >= SCENE_PARAMS_MAX) return NULL;
    scene_kv_t *kv = &p->kv[p->count++];
    memset(kv, 0, sizeof *kv);
    memcpy(kv->key, key, strlen(key) + 1);
    return kv;
}

bool scene_params_set(scene_params_t *p, const char *key, const char *value) {
    if (!p || !key || !value || !key[0]) return false;
    size_t kl = bounded_len(key, SCENE_PARAM_KEY_CAP), vl = bounded_len(value, SCENE_PARAM_STR_CAP);
    if (kl >= SCENE_PARAM_KEY_CAP || vl >= SCENE_PARAM_STR_CAP) return false;
    scene_kv_t *kv = params_slot(p, key);
    if (!kv) return false;
    memcpy(kv->str, value, vl + 1);
    kv->is_num = parse_num(value, &kv->num) ? 1 : 0;
    if (!kv->is_num) kv->num = 0;
    return true;
}

bool scene_params_set_int(scene_params_t *p, const char *key, int32_t value) {
    char buf[12];
    fmt_int(buf, value);
    return scene_params_set(p, key, buf);
}

static const scene_kv_t *params_find(const scene_params_t *p, const char *key) {
    if (!p) return NULL;
    for (uint8_t i = 0; i < p->count && i < SCENE_PARAMS_MAX; i++)
        if (!strcmp(p->kv[i].key, key)) return &p->kv[i];
    return NULL;
}

static void resolve_params(const scene_info_t *info, const scene_params_t *p, int32_t *pv) {
    for (uint8_t i = 0; i < info->param_count && i < SCENE_PARAMS_MAX; i++) {
        const scene_param_desc_t *d = &info->params[i];
        const scene_kv_t *kv = params_find(p, d->name);
        int32_t v = d->def;
        if (kv && d->type == SCENE_PARAM_ENUM) {
            for (uint8_t j = 0; j < d->value_count; j++)
                if (streq_ci(kv->str, d->values[j])) { v = j; break; }
        } else if (kv && d->type == SCENE_PARAM_INT) {
            if (kv->is_num) v = kv->num;
            else if (streq_ci(kv->str, "true") || streq_ci(kv->str, "on") || streq_ci(kv->str, "yes")) v = d->max;
            else if (streq_ci(kv->str, "false") || streq_ci(kv->str, "off") || streq_ci(kv->str, "no")) v = d->min;
            if (v < d->min) v = d->min;
            if (v > d->max) v = d->max;
        }
        pv[i] = v;
    }
}

bool scene_param_get(const scene_t *s, const char *name, int32_t *out) {
    if (!s || !name || s->kind >= SCENE_KIND_COUNT) return false;
    const scene_info_t *info = &k_scenes[s->kind];
    for (uint8_t i = 0; i < info->param_count; i++)
        if (!strcmp(info->params[i].name, name)) {
            if (out) *out = s->pv[i];
            return true;
        }
    return false;
}

/* ------------------------------------------------------------------------------------------ */
/* Arena layout                                                                                */

typedef struct {
    scene_kind_t kind;
    int scale, gw, gh;
    size_t cells, shade, line, extra;
} sc_layout_t;

static bool grid_kind(scene_kind_t k) { return k != SCENE_BALLS && k != SCENE_WORDS; }

bool scene_follows_orientation(scene_kind_t kind) { return kind == SCENE_WORDS; }

void scene_gravity_flipped(float g[3])
{
    if (!g) return;
    g[0] = -g[0];
    g[1] = -g[1];
}

static void layout(scene_kind_t kind, const int32_t *pv, uint16_t w, uint16_t h, sc_layout_t *L) {
    memset(L, 0, sizeof *L);
    L->kind = kind;
    if (grid_kind(kind)) {
        int sc = sc_clampi(pv[P_SCALE], SC_SCALE_MIN, SC_SCALE_MAX);
        L->scale = sc;
        L->gw = (w + sc - 1) / sc;
        L->gh = (h + sc - 1) / sc;
        size_t n = (size_t)L->gw * (size_t)L->gh;
        L->cells = sc_align4(n);
        L->shade = sc_align4(n);
        L->line = sc_align4((size_t)L->gw * (size_t)sc * 2u) + sc_align4((size_t)L->gw * 2u);
    } else {
        L->scale = 1;
        L->gw = w;
        L->gh = h;
    }
    switch (kind) {
    case SCENE_WATER: L->extra = sc_water_extra(L->gw, L->gh, pv); break;
    case SCENE_SNOW: L->extra = sc_snow_extra(L->gw, L->gh, pv); break;
    case SCENE_FIRE: L->extra = sc_fire_extra(L->gw, L->gh, pv); break;
    case SCENE_LAVA: L->extra = sc_lava_extra(L->gw, L->gh, pv); break;
    case SCENE_BALLS: L->extra = sc_balls_extra(L->gw, L->gh, pv); break;
    case SCENE_WORDS: L->extra = sc_words_extra(L->gw, L->gh, pv); break;
    default: L->extra = 0; break;
    }
    L->extra = sc_align4(L->extra);
}

static size_t layout_total(const sc_layout_t *L) { return L->cells + L->shade + L->line + L->extra; }

static bool dims_ok(uint16_t w, uint16_t h) {
    return w >= SCENE_MIN_DIM && h >= SCENE_MIN_DIM && w <= SCENE_MAX_DIM && h <= SCENE_MAX_DIM;
}

size_t scene_arena_bytes_for(scene_kind_t kind, const scene_params_t *p, uint16_t w, uint16_t h) {
    if ((unsigned)kind >= SCENE_KIND_COUNT || !dims_ok(w, h)) return 0;
    int32_t pv[SCENE_PARAMS_MAX] = { 0 };
    resolve_params(&k_scenes[kind], p, pv);
    sc_layout_t L;
    layout(kind, pv, w, h, &L);
    return layout_total(&L);
}

size_t scene_arena_bytes(scene_kind_t kind, uint16_t w, uint16_t h) {
    if ((unsigned)kind >= SCENE_KIND_COUNT || !dims_ok(w, h)) return 0;
    const scene_info_t *info = &k_scenes[kind];
    int32_t pv[SCENE_PARAMS_MAX] = { 0 };
    resolve_params(info, NULL, pv);
    /* worst case: every int parameter at the end of its range that costs most memory */
    for (uint8_t i = 0; i < info->param_count; i++)
        if (info->params[i].type == SCENE_PARAM_INT)
            pv[i] = !strcmp(info->params[i].name, "scale") ? info->params[i].min : info->params[i].max;
    sc_layout_t L;
    layout(kind, pv, w, h, &L);
    return layout_total(&L);
}

/* ------------------------------------------------------------------------------------------ */
/* Init / step / render                                                                        */

scene_status_t scene_init(scene_t *s, scene_kind_t kind, const scene_params_t *p, uint16_t w, uint16_t h,
                          uint32_t seed, void *arena, size_t arena_bytes) {
    if (!s) return SCENE_ERR_ARG;
    memset(s, 0, sizeof *s);
    if ((unsigned)kind >= SCENE_KIND_COUNT || !dims_ok(w, h)) return SCENE_ERR_ARG;
    if (!arena || ((uintptr_t)arena & 3u)) return SCENE_ERR_ARENA;
    resolve_params(&k_scenes[kind], p, s->pv);
    sc_layout_t L;
    layout(kind, s->pv, w, h, &L);
    size_t need = layout_total(&L);
    if (arena_bytes < need) return SCENE_ERR_ARENA;
    memset(arena, 0, need);

    s->kind = (uint8_t)kind;
    s->w = w;
    s->h = h;
    s->gw = (uint16_t)L.gw;
    s->gh = (uint16_t)L.gh;
    s->scale = (uint8_t)L.scale;
    uint8_t *a = (uint8_t *)arena;
    if (grid_kind(kind)) {
        s->smooth = (uint8_t)s->pv[P_SMOOTH];
        const char *pal = k_scenes[kind].params[P_PALETTE].values[s->pv[P_PALETTE]];
        s->palette = (uint8_t)sc_palette_find(pal);
        s->cells = a;
        s->shade = a + L.cells;
        s->line = (uint16_t *)(void *)(a + L.cells + L.shade);
    } else if (kind == SCENE_BALLS) {
        const char *pal = k_scenes[kind].params[PB_PALETTE].values[s->pv[PB_PALETTE]];
        s->palette = (uint8_t)sc_palette_find(pal);
    }
    s->extra = L.extra ? (void *)(a + L.cells + L.shade + L.line) : NULL;
    s->extra_bytes = L.extra;

    /* seed: splitmix-style scramble so nearby seeds diverge; xorshift state must be non-zero */
    uint32_t z = seed + 0x9E3779B9u + (uint32_t)kind * 0x85EBCA6Bu;
    z = (z ^ (z >> 16)) * 0x7FEB352Du;
    z = (z ^ (z >> 15)) * 0x846CA68Bu;
    z ^= z >> 16;
    s->rng = z ? z : 0x6D2B79F5u;

    s->g_lp[1] = s->g_raw[1] = 1.0f;
    s->ey = 1.0f;
    s->drift_angle = 1.57079633f;
    s->need_full = 1;

    switch (kind) {
    case SCENE_SAND: sc_sand_init(s); break;
    case SCENE_WATER: sc_water_init(s); break;
    case SCENE_SNOW: sc_snow_init(s); break;
    case SCENE_FIRE: sc_fire_init(s); break;
    case SCENE_LAVA: sc_lava_init(s); break;
    case SCENE_BALLS: sc_balls_init(s); break;
    case SCENE_WORDS: sc_words_init(s); break;
    default: return SCENE_ERR_ARG;
    }
    s->ready = 1;
    return SCENE_OK;
}

#define LP_TAU 0.10f          /* s: gravity low-pass (pile direction) */
#define HP_DEADZONE 0.06f     /* g: IMU noise floor for the high-pass residual */
#define KICK_THRESHOLD 0.35f  /* g: residual that counts as a shake/knock */
#define KICK_COOLDOWN 0.15f   /* s */
#define FACEUP_ON 0.40f       /* g: in-plane gravity below which drift starts to blend in */
#define FACEUP_FULL 0.10f
#define DRIFT_G 0.30f         /* g: strength of the face-up drift */

void scene_step(scene_t *s, float gx, float gy, float gz, float dt) {
    if (!s || !s->ready) return;
    if (!(dt > 0.0f)) dt = 0.0f;   /* also catches NaN */
    if (dt > 0.05f) dt = 0.05f;
    float in[3] = { gx, gy, gz };
    bool ok = sc_finite(gx) && sc_finite(gy) && sc_finite(gz);
    for (int i = 0; i < 3; i++) {
        in[i] = ok ? sc_clampf(in[i], -8.0f, 8.0f) : s->g_raw[i];
        s->g_raw[i] = in[i];
    }
    if (!s->has_input) {   /* first sample initialises the filter: no start-up "shake" */
        for (int i = 0; i < 3; i++) s->g_lp[i] = in[i];
        s->has_input = 1;
    }
    float alpha = dt / (LP_TAU + dt);
    float hp2 = 0.0f;
    for (int i = 0; i < 3; i++) {
        s->g_lp[i] += (in[i] - s->g_lp[i]) * alpha;
        s->hp[i] = in[i] - s->g_lp[i];
        hp2 += s->hp[i] * s->hp[i];
    }
    float hpm = sc_sqrtf(hp2);
    if (hpm > HP_DEADZONE) {
        float k = 1.0f - HP_DEADZONE / hpm;
        for (int i = 0; i < 3; i++) s->hp[i] *= k;
        hpm -= HP_DEADZONE;
    } else {
        s->hp[0] = s->hp[1] = s->hp[2] = 0.0f;
        hpm = 0.0f;
    }
    s->shake = sc_maxf(s->shake * sc_maxf(0.0f, 1.0f - 3.0f * dt), hpm);
    float kick = 0.0f;
    s->kick_cooldown -= dt;
    if (hpm > KICK_THRESHOLD && s->kick_cooldown <= 0.0f && dt > 0.0f) {
        kick = hpm;
        s->kick_cooldown = KICK_COOLDOWN;
    }

    /* effective in-plane gravity, with a gentle wandering drift when lying flat */
    float lx = s->g_lp[0], ly = s->g_lp[1];
    float m = sc_sqrtf(lx * lx + ly * ly);
    s->drift_angle += sc_rands(s) * dt * 2.5f;
    if (s->kind == SCENE_FIRE || s->kind == SCENE_LAVA)   /* flames keep rising roughly "up" */
        s->drift_angle += (1.57079633f - s->drift_angle) * dt * 0.6f;
    else if (s->drift_angle > 100.0f || s->drift_angle < -100.0f)
        s->drift_angle = 0.0f;
    float wgt = sc_clampf((FACEUP_ON - m) * (1.0f / (FACEUP_ON - FACEUP_FULL)), 0.0f, 1.0f);
    float drift = (s->kind == SCENE_BALLS || s->kind == SCENE_WORDS) ? DRIFT_G * 0.4f : DRIFT_G;   /* 1:1 feel, calm */
    s->ex = lx + wgt * drift * sc_cosf(s->drift_angle);
    s->ey = ly + wgt * drift * sc_sinf(s->drift_angle);
    s->t += dt;
    if (dt <= 0.0f) return;

    switch ((scene_kind_t)s->kind) {
    case SCENE_SAND: sc_sand_step(s, dt, kick); break;
    case SCENE_WATER: sc_water_step(s, dt, kick); break;
    case SCENE_SNOW: sc_snow_step(s, dt, kick); break;
    case SCENE_FIRE: sc_fire_step(s, dt, kick); break;
    case SCENE_LAVA: sc_lava_step(s, dt, kick); break;
    case SCENE_BALLS: sc_balls_step(s, dt, kick); break;
    case SCENE_WORDS: sc_words_step(s, dt, kick); break;
    default: break;
    }
}

void scene_invalidate(scene_t *s) {
    if (s) s->need_full = 1;
}

void scene_render(scene_t *s, uint16_t *fb, uint16_t fb_w, uint16_t fb_h, scene_rect_t *dirty) {
    if (dirty) memset(dirty, 0, sizeof *dirty);
    if (!s || !s->ready || !fb || !fb_w || !fb_h) return;
    if (s->kind == SCENE_BALLS) {
        sc_balls_render(s, fb, fb_w, fb_h, dirty);
    } else if (s->kind == SCENE_WORDS) {
        sc_words_render(s, fb, fb_w, fb_h, dirty);
    } else {
        switch ((scene_kind_t)s->kind) {
        case SCENE_SAND: sc_sand_prepare(s); break;
        case SCENE_WATER: sc_water_prepare(s); break;
        case SCENE_SNOW: sc_snow_prepare(s); break;
        case SCENE_FIRE: sc_fire_prepare(s); break;
        case SCENE_LAVA: sc_lava_prepare(s); break;
        default: return;
        }
        sc_grid_render(s, fb, fb_w, fb_h);
        if (dirty) {
            dirty->w = (int16_t)(s->w < fb_w ? s->w : fb_w);
            dirty->h = (int16_t)(s->h < fb_h ? s->h : fb_h);
        }
    }
    s->frame++;
    s->need_full = 0;
}

/* ------------------------------------------------------------------------------------------ */
/* Flow geometry                                                                               */

const int8_t sc_dx[8] = { 1, 1, 0, -1, -1, -1, 0, 1 };
const int8_t sc_dy[8] = { 0, 1, 1, 1, 0, -1, -1, -1 };

void sc_flow_make(scene_t *s, sc_flow_t *f, bool downstream_first) {
    float ex = s->ex, ey = s->ey;
    float mag = sc_absf(ex) + sc_absf(ey);
    if (mag < 1e-6f) { ex = 0.0f; ey = 1.0f; mag = 1.0f; }
    float a8 = sc_atan2f(ey, ex) * (4.0f / SC_PI);
    if (a8 < 0.0f) a8 += 8.0f;
    if (!(a8 >= 0.0f) || a8 >= 8.0f) a8 = 0.0f;
    int k0 = (int)a8;
    if (k0 > 7) k0 = 7;
    float fr = a8 - (float)k0;
    f->k0 = k0;
    f->p_next = (uint32_t)(fr * 65535.0f);
    f->knear = (fr < 0.5f ? k0 : k0 + 1) & 7;
    f->lat_a = (k0 + 2) & 7;
    f->lat_b = (fr > 0.02f ? k0 - 1 : k0 - 2) & 7;
    f->cone_mask = f->hop_mask = 0;
    for (int k = 0; k < 8; k++) {
        float d = sc_absf((float)k - a8);
        if (d > 4.0f) d = 8.0f - d;               /* circular distance in 45° units */
        f->accept[k] = d < 1.95f ? 65535u : 0u;
        if (d <= 1.15f) f->cone_mask |= (uint8_t)(1u << k);
        else if (d < 1.95f) f->hop_mask |= (uint8_t)(1u << k);
    }
    f->outer_y = sc_absf(ey) >= sc_absf(ex);
    float thr = 0.08f * mag;
    int alt_x = (int)(s->steps & 1u), alt_y = (int)((s->steps >> 1) & 1u);
    if (ey > thr) f->desc_y = downstream_first;
    else if (ey < -thr) f->desc_y = !downstream_first;
    else f->desc_y = alt_y;
    if (ex > thr) f->desc_x = downstream_first;
    else if (ex < -thr) f->desc_x = !downstream_first;
    else f->desc_x = alt_x;
}

/* ------------------------------------------------------------------------------------------ */
/* Grid renderer: one row of blocks is built in s->line (internal RAM if the arena is there),   */
/* then copied to the `scale` framebuffer rows with memcpy (sequential PSRAM writes).           */

static void line_fill_crisp(const scene_t *s, const uint8_t *sr, int ncell) {
    const uint32_t *lut = s->lut32;
    int sc = s->scale;
    if (sc == 4) {
        sc_u32_alias *lw = (sc_u32_alias *)(void *)s->line;
        for (int x = 0; x < ncell; x++) {
            uint32_t p = lut[sr[x]];
            lw[0] = p;
            lw[1] = p;
            lw += 2;
        }
    } else if (!(sc & 1)) {
        sc_u32_alias *lw = (sc_u32_alias *)(void *)s->line;
        int half = sc >> 1;
        for (int x = 0; x < ncell; x++) {
            uint32_t p = lut[sr[x]];
            for (int i = 0; i < half; i++) *lw++ = p;
        }
    } else {
        uint16_t *l = s->line;
        for (int x = 0; x < ncell; x++) {
            uint16_t p = (uint16_t)lut[sr[x]];
            for (int i = 0; i < sc; i++) *l++ = p;
        }
    }
}

/* Smooth: each cell is split into 2×2 sub-blocks whose value is the bilinear blend of the cell and
 * its neighbours at the sub-block centre: (9·c + 3·h + 3·v + d) / 16. `v` holds 3·row + neighbour row. */
static void line_fill_smooth(const scene_t *s, const uint16_t *v, int ncell) {
    const uint32_t *lut = s->lut32;
    int sc = s->scale, a = sc >> 1, b = sc - a;
    int gw = s->gw;
    if (sc == 4) {
        sc_u32_alias *lw = (sc_u32_alias *)(void *)s->line;
        for (int x = 0; x < ncell; x++) {
            unsigned c3 = 3u * v[x];
            unsigned l = v[x > 0 ? x - 1 : 0], r = v[x + 1 < gw ? x + 1 : x];
            lw[0] = lut[(c3 + l) >> 4];
            lw[1] = lut[(c3 + r) >> 4];
            lw += 2;
        }
    } else {
        uint16_t *ln = s->line;
        for (int x = 0; x < ncell; x++) {
            unsigned c3 = 3u * v[x];
            unsigned l = v[x > 0 ? x - 1 : 0], r = v[x + 1 < gw ? x + 1 : x];
            uint16_t pl = (uint16_t)lut[(c3 + l) >> 4], pr = (uint16_t)lut[(c3 + r) >> 4];
            for (int i = 0; i < a; i++) *ln++ = pl;
            for (int i = 0; i < b; i++) *ln++ = pr;
        }
    }
}

void sc_grid_render(scene_t *s, uint16_t *fb, uint16_t fb_w, uint16_t fb_h) {
    int W = s->w < fb_w ? s->w : fb_w;
    int H = s->h < fb_h ? s->h : fb_h;
    int sc = s->scale, gw = s->gw, gh = s->gh;
    int ncell = (W + sc - 1) / sc;   /* once per frame */
    if (ncell > gw) ncell = gw;
    size_t row_bytes = (size_t)W * 2u;
    uint16_t *vrow = (uint16_t *)(void *)((uint8_t *)s->line + sc_align4((size_t)gw * (size_t)sc * 2u));
    for (int gy = 0, y0 = 0; gy < gh && y0 < H; gy++, y0 += sc) {
        const uint8_t *sr = s->shade + (size_t)gy * gw;
        if (!s->smooth) {
            line_fill_crisp(s, sr, ncell);
            int rows = sc < H - y0 ? sc : H - y0;
            for (int r = 0; r < rows; r++) memcpy(fb + (size_t)(y0 + r) * fb_w, s->line, row_bytes);
        } else {
            int a = sc >> 1;
            for (int half = 0; half < 2; half++) {
                int ny = half ? (gy + 1 < gh ? gy + 1 : gy) : (gy > 0 ? gy - 1 : 0);
                const uint8_t *nr = s->shade + (size_t)ny * gw;
                for (int x = 0; x < ncell; x++) vrow[x] = (uint16_t)(3u * sr[x] + nr[x]);
                line_fill_smooth(s, vrow, ncell);
                int ys = y0 + (half ? a : 0);
                int ye = y0 + (half ? sc : a);
                if (ye > H) ye = H;
                for (int y = ys; y < ye; y++) memcpy(fb + (size_t)y * fb_w, s->line, row_bytes);
            }
        }
    }
}

/* ------------------------------------------------------------------------------------------ */
/* GET /scenes JSON                                                                            */

typedef struct { char *b; size_t cap, len; bool ok; } sc_out_t;

static void out_s(sc_out_t *o, const char *s) {
    size_t n = strlen(s);
    if (!o->ok || o->len + n + 1 > o->cap) { o->ok = false; return; }
    memcpy(o->b + o->len, s, n);
    o->len += n;
}
static void out_q(sc_out_t *o, const char *s) { out_s(o, "\""); out_s(o, s); out_s(o, "\""); }
static void out_i(sc_out_t *o, int32_t v) { char t[12]; fmt_int(t, v); out_s(o, t); }

size_t scene_describe_json(char *buf, size_t cap) {
    if (!buf || !cap) return 0;
    sc_out_t o = { buf, cap, 0, true };
    out_s(&o, "{\"ok\":true,\"scenes\":[");
    for (size_t i = 0; i < SCENE_KIND_COUNT; i++) {
        const scene_info_t *si = &k_scenes[i];
        if (i) out_s(&o, ",");
        out_s(&o, "{\"id\":"); out_q(&o, si->id);
        out_s(&o, ",\"name\":"); out_q(&o, si->name);
        out_s(&o, ",\"params\":{");
        for (uint8_t j = 0; j < si->param_count; j++) {
            const scene_param_desc_t *d = &si->params[j];
            if (j) out_s(&o, ",");
            out_q(&o, d->name);
            out_s(&o, ":[");
            if (d->type == SCENE_PARAM_ENUM) {
                for (uint8_t k = 0; k < d->value_count; k++) {
                    if (k) out_s(&o, ",");
                    out_q(&o, d->values[k]);
                }
            } else {
                out_i(&o, d->min); out_s(&o, ","); out_i(&o, d->max);
            }
            out_s(&o, "]");
        }
        out_s(&o, "},\"defaults\":{");
        for (uint8_t j = 0; j < si->param_count; j++) {
            const scene_param_desc_t *d = &si->params[j];
            if (j) out_s(&o, ",");
            out_q(&o, d->name);
            out_s(&o, ":");
            if (d->type == SCENE_PARAM_ENUM) out_q(&o, d->values[d->def]);
            else out_i(&o, d->def);
        }
        out_s(&o, "}}");
    }
    out_s(&o, "]}");
    if (!o.ok) { buf[0] = 0; return 0; }
    buf[o.len] = 0;
    return o.len;
}

/* ------------------------------------------------------------------------------------------ */
/* IMU axis mapping                                                                            */

const scene_axis_map_t SCENE_AXIS_MAP_IDENTITY_FLIP = { { { -1, 0, 0 }, { 0, -1, 0 }, { 0, 0, -1 } } };
/* PLACEHOLDER — replace with the scene_axis_map_calibrate() result measured on a real clip. */
const scene_axis_map_t SCENE_IMU_AXIS_MAP = { { { -1, 0, 0 }, { 0, -1, 0 }, { 0, 0, -1 } } };

void scene_gravity_from_imu(const scene_axis_map_t *map, float ax, float ay, float az, float g_out[3]) {
    if (!g_out) return;
    if (!map) map = &SCENE_AXIS_MAP_IDENTITY_FLIP;
    for (int i = 0; i < 3; i++)
        g_out[i] = (float)map->m[i][0] * ax + (float)map->m[i][1] * ay + (float)map->m[i][2] * az;
}

static int dominant_axis(const float v[3], int *sign) {
    int a = 0;
    for (int i = 1; i < 3; i++)
        if (sc_absf(v[i]) > sc_absf(v[a])) a = i;
    *sign = v[a] < 0 ? -1 : 1;
    return a;
}

bool scene_axis_map_calibrate(const float upright[3], const float face_up[3], scene_axis_map_t *out) {
    if (!upright || !face_up || !out) return false;
    for (int i = 0; i < 3; i++)
        if (!sc_finite(upright[i]) || !sc_finite(face_up[i])) return false;
    int su, sf;
    int a = dominant_axis(upright, &su), b = dominant_axis(face_up, &sf);
    if (a == b || sc_absf(upright[a]) < 0.7f || sc_absf(face_up[b]) < 0.7f) return false;
    int ry[3] = { 0, 0, 0 }, rz[3] = { 0, 0, 0 };
    ry[a] = su;          /* upright reading -> g_y = +1 (falls toward the bottom edge) */
    rz[b] = -sf;         /* face-up reading -> g_z = -1 (falls into the glass) */
    /* rows of M are -(display axes in chip coordinates); display frame is left-handed, so
     * row_x = row_y × row_z */
    int rx[3] = { ry[1] * rz[2] - ry[2] * rz[1], ry[2] * rz[0] - ry[0] * rz[2], ry[0] * rz[1] - ry[1] * rz[0] };
    for (int i = 0; i < 3; i++) {
        out->m[0][i] = (int8_t)rx[i];
        out->m[1][i] = (int8_t)ry[i];
        out->m[2][i] = (int8_t)rz[i];
    }
    return true;
}
