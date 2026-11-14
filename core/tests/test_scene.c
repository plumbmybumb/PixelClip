/* test_scene.c — live scenes (core/scene.h): registry, params, init/step/render robustness, mass
 * conservation, clipping, balls containment, determinism, incremental-vs-full rendering, axis map.
 * SCENE_TEST_SCALE=N multiplies the step counts (default 1). */
#include "tharness.h"
#include "scene.h"
#include "scene_internal.h"
#include <math.h>

#define FW 536
#define FH 240
#define SENTINEL 0xA55Au
#define ARENA_GUARD 64

static int scale_factor = 1;

static uint64_t fnv(const void *p, size_t n) {
    const uint8_t *b = (const uint8_t *)p;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return h;
}

static float frand(void) { return (float)(th_rand() >> 8) / 16777216.0f; }   /* [0,1) */
static float frands(void) { return frand() * 2.0f - 1.0f; }

/* Arena with a guard band after it; checks the guard is intact on release. */
typedef struct { uint8_t *mem; size_t n; } arena_t;
static void *arena_get(arena_t *a, size_t n) {
    a->n = n;
    a->mem = malloc(n + ARENA_GUARD);
    memset(a->mem + n, 0xEE, ARENA_GUARD);
    return a->mem;
}
static void arena_put(arena_t *a) {
    for (size_t i = 0; i < ARENA_GUARD; i++) CHECK_EQ(a->mem[a->n + i], 0xEE);
    free(a->mem);
}

static int init_kind(scene_t *s, arena_t *a, scene_kind_t k, const scene_params_t *p, int w, int h, uint32_t seed) {
    size_t need = scene_arena_bytes_for(k, p, (uint16_t)w, (uint16_t)h);
    CHECK(need > 0);
    void *mem = arena_get(a, need);
    scene_status_t st = scene_init(s, k, p, (uint16_t)w, (uint16_t)h, seed, mem, need);
    CHECK_EQ(st, SCENE_OK);
    return st == SCENE_OK;
}

/* §5b.1 a test sheet: n frames of FWW x FWH, frame f's ink a box x [10, 10 + 30 + 20 f) y [8, 32) with a hole
 * (black) in its middle; frames listed in `empty` (bit f) are all black. Pixels name frame and position. */
#define FWW 140
#define FWH 40
static uint16_t s_sheet[SCENE_WORDS_MAX][FWW * FWH];
static const uint16_t *s_frames[SCENE_WORDS_MAX];
static int sheet_ink_w(int f) { return 30 + 20 * (f % 5); }
static void make_sheet(int n, uint32_t empty) {
    memset(s_sheet, 0, sizeof s_sheet);
    for (int f = 0; f < n; f++) {
        s_frames[f] = s_sheet[f];
        if (empty & (1u << f)) continue;
        const int w = sheet_ink_w(f);
        for (int y = 8; y < 32; y++)
            for (int x = 10; x < 10 + w; x++) {
                if (y >= 16 && y < 24 && x >= 18 && x < 22) continue;   /* a hole: black passes through */
                s_sheet[f][y * FWW + x] = (uint16_t)(0x0100u * (unsigned)(f + 1) + (unsigned)((x + y) & 0xFF) + 1u);
            }
    }
}

/* A words scene with an n-frame sheet. */
static int init_words(scene_t *s, arena_t *a, const scene_params_t *p, int n, uint32_t empty, int w, int h, uint32_t seed) {
    if (!init_kind(s, a, SCENE_WORDS, p, w, h, seed)) return 0;
    make_sheet(n, empty);
    return scene_words_set_sprites(s, s_frames, n, FWW, FWH) >= 0;
}

static int count_cells(const scene_t *s) {
    int n = 0;
    for (size_t i = 0; i < (size_t)s->gw * s->gh; i++) n += s->cells[i] != 0;
    return n;
}

/* ------------------------------------------------------------------------------------------ */

static void test_registry(void) {
    CHECK_EQ(scene_count(), SCENE_KIND_COUNT);
    CHECK(scene_info(SCENE_KIND_COUNT) == NULL);
    CHECK(scene_find(NULL) == NULL);
    CHECK(scene_find("lava-lamp") == NULL);
    static const char *const ids[] = { "sand", "water", "snow", "fire", "lava", "balls", "words" };
    for (size_t i = 0; i < scene_count(); i++) {
        const scene_info_t *si = scene_info(i);
        CHECK(si != NULL);
        if (!si) continue;
        CHECK_EQ(si->kind, i);
        CHECK(!strcmp(si->id, ids[i]));
        CHECK(si->name && si->name[0] && si->description && si->description[0]);
        CHECK(scene_find(si->id) == si);
        CHECK(si->param_count > 0 && si->param_count <= SCENE_PARAMS_MAX);
        bool has_palette = false;
        for (uint8_t j = 0; j < si->param_count; j++) {
            const scene_param_desc_t *d = &si->params[j];
            CHECK(d->name && d->name[0] && strlen(d->name) < SCENE_PARAM_KEY_CAP);
            CHECK(d->help && d->help[0]);
            for (uint8_t k = 0; k < j; k++) CHECK(strcmp(si->params[k].name, d->name) != 0);
            if (d->type == SCENE_PARAM_ENUM) {
                CHECK(d->values != NULL && d->value_count > 0);
                CHECK(d->def >= 0 && d->def < d->value_count);
                CHECK_EQ(d->min, 0);
                CHECK_EQ(d->max, d->value_count - 1);
                for (uint8_t k = 0; k < d->value_count; k++) {
                    CHECK(d->values[k] && d->values[k][0] && strlen(d->values[k]) < SCENE_PARAM_STR_CAP);
                    for (uint8_t m = 0; m < k; m++) CHECK(strcmp(d->values[m], d->values[k]) != 0);
                    if (!strcmp(d->name, "palette")) CHECK(sc_palette_find(d->values[k]) >= 0);
                }
                if (!strcmp(d->name, "palette")) has_palette = true;
            } else {
                CHECK_EQ(d->type, SCENE_PARAM_INT);
                CHECK(d->values == NULL);
                CHECK(d->min <= d->def && d->def <= d->max);
            }
        }
        CHECK(has_palette == (i != SCENE_WORDS));   /* words: the colours are baked into the sheet */
        /* defaults resolve to the descriptor defaults */
        scene_t s;
        arena_t a;
        if (init_kind(&s, &a, (scene_kind_t)i, NULL, 64, 32, 1)) {
            for (uint8_t j = 0; j < si->param_count; j++) {
                int32_t v = -999;
                CHECK(scene_param_get(&s, si->params[j].name, &v));
                CHECK_EQ(v, si->params[j].def);
            }
            CHECK(!scene_param_get(&s, "nope", NULL));
        }
        arena_put(&a);
    }
    /* palettes required by the spec exist */
    static const char *const pals[] = { "amber", "ocean", "forest", "candy", "mono", "ember", "classic", "blue", "emerald" };
    for (size_t i = 0; i < sizeof pals / sizeof pals[0]; i++) CHECK(sc_palette_find(pals[i]) >= 0);
    CHECK(sc_palette_find("AMBER") >= 0);
    CHECK_EQ(sc_palette_find("plaid"), -1);
    /* brand amber #FFBE00 is on the amber ramp */
    int hit = 0;
    for (int pos = 0; pos < 256; pos++) {
        uint8_t rgb[3];
        sc_palette_rgb(PAL_AMBER, pos, rgb);
        if (rgb[0] == 0xFF && rgb[1] == 0xBE && rgb[2] == 0x00) hit = 1;
    }
    CHECK(hit);
}

static void test_describe_json(void) {
    static char buf[8192];
    size_t n = scene_describe_json(buf, sizeof buf);
    CHECK(n > 100 && n < sizeof buf);
    CHECK_EQ(strlen(buf), n);
    CHECK(!strncmp(buf, "{\"ok\":true,\"scenes\":[", 21));
    int braces = 0, brackets = 0, quotes = 0;
    for (size_t i = 0; i < n; i++) {
        braces += buf[i] == '{' ? 1 : buf[i] == '}' ? -1 : 0;
        brackets += buf[i] == '[' ? 1 : buf[i] == ']' ? -1 : 0;
        quotes += buf[i] == '"';
        CHECK(braces >= 0 && brackets >= 0);
    }
    CHECK_EQ(braces, 0);
    CHECK_EQ(brackets, 0);
    CHECK_EQ(quotes % 2, 0);
    for (size_t i = 0; i < scene_count(); i++) {
        char key[32];
        snprintf(key, sizeof key, "{\"id\":\"%s\"", scene_info(i)->id);
        CHECK(strstr(buf, key) != NULL);
    }
    CHECK(strstr(buf, "\"palette\":[\"amber\",\"ocean\",\"forest\",\"candy\",\"mono\",\"ember\"]") != NULL);
    CHECK(strstr(buf, "\"density\":[10,100]") != NULL);
    CHECK(strstr(buf, "\"defaults\":{\"palette\":\"amber\",\"density\":50") != NULL);
    /* too small: 0 and an empty string, never an overflow */
    for (size_t cap = 1; cap < n + 1; cap += 97) {
        memset(buf, 'x', sizeof buf);
        CHECK_EQ(scene_describe_json(buf, cap), 0);
        CHECK_EQ(buf[0], 0);
        CHECK_EQ(buf[cap], 'x');
    }
    CHECK_EQ(scene_describe_json(buf, n + 1), n);
    CHECK_EQ(scene_describe_json(NULL, 100), 0);
}

static void test_params(void) {
    scene_params_t p;
    scene_params_clear(&p);
    CHECK(scene_params_set(&p, "palette", "ocean"));
    CHECK(scene_params_set(&p, "palette", "forest"));       /* replace, not append */
    CHECK_EQ(p.count, 1);
    CHECK(!strcmp(p.kv[0].str, "forest"));
    CHECK(!p.kv[0].is_num);
    CHECK(scene_params_set(&p, "density", "60"));
    CHECK(p.kv[1].is_num && p.kv[1].num == 60);
    CHECK(scene_params_set(&p, "density", "12.9"));
    CHECK(p.kv[1].is_num && p.kv[1].num == 12);
    CHECK(scene_params_set(&p, "density", "-3"));
    CHECK(p.kv[1].is_num && p.kv[1].num == -3);
    CHECK(scene_params_set(&p, "density", "99999999999"));
    CHECK(p.kv[1].is_num && p.kv[1].num == INT32_MAX);
    CHECK(scene_params_set(&p, "density", "1e3"));
    CHECK(!p.kv[1].is_num);
    CHECK(scene_params_set(&p, "density", "-"));
    CHECK(!p.kv[1].is_num);
    CHECK(scene_params_set_int(&p, "density", -2147483647 - 1));
    CHECK(p.kv[1].is_num && p.kv[1].num == INT32_MIN && !strcmp(p.kv[1].str, "-2147483648"));
    /* rejected: NULLs, empty key, too long key/value */
    CHECK(!scene_params_set(NULL, "a", "b"));
    CHECK(!scene_params_set(&p, NULL, "b"));
    CHECK(!scene_params_set(&p, "a", NULL));
    CHECK(!scene_params_set(&p, "", "b"));
    CHECK(!scene_params_set(&p, "0123456789abcdef", "b"));          /* 16 chars */
    CHECK(scene_params_set(&p, "0123456789abcde", "b"));            /* 15 chars ok */
    CHECK(!scene_params_set(&p, "k", "0123456789abcdef"));
    CHECK(scene_params_set(&p, "k", "0123456789abcde"));
    /* full bag */
    scene_params_clear(&p);
    for (int i = 0; i < SCENE_PARAMS_MAX; i++) {
        char k[8];
        snprintf(k, sizeof k, "k%d", i);
        CHECK(scene_params_set_int(&p, k, i));
    }
    CHECK(!scene_params_set(&p, "extra", "1"));
    CHECK(scene_params_set(&p, "k3", "again"));                     /* replacing still works */
    CHECK_EQ(p.count, SCENE_PARAMS_MAX);

    /* resolution: unknown keys ignored, bad values -> default, ints clamped, case-insensitive enums */
    scene_params_clear(&p);
    scene_params_set(&p, "palette", "PLAID");
    scene_params_set(&p, "density", "5000");
    scene_params_set(&p, "smooth", "true");
    scene_params_set(&p, "scale", "banana");
    scene_params_set(&p, "colour", "red");
    scene_t s;
    arena_t a;
    int32_t v;
    if (init_kind(&s, &a, SCENE_SAND, &p, FW, FH, 7)) {
        CHECK(scene_param_get(&s, "palette", &v) && v == 0);       /* amber (default) */
        CHECK(scene_param_get(&s, "density", &v) && v == 100);     /* clamped */
        CHECK(scene_param_get(&s, "smooth", &v) && v == 1);
        CHECK(scene_param_get(&s, "scale", &v) && v == 4);         /* default */
        CHECK_EQ(s.gw, 134);
        CHECK_EQ(s.gh, 60);
    }
    arena_put(&a);
    scene_params_clear(&p);
    scene_params_set(&p, "palette", "Candy");
    scene_params_set_int(&p, "density", -40);
    scene_params_set(&p, "smooth", "off");
    scene_params_set_int(&p, "scale", 3);
    if (init_kind(&s, &a, SCENE_WATER, &p, 100, 50, 7)) {
        CHECK(scene_param_get(&s, "palette", &v) && v == 3);
        CHECK(scene_param_get(&s, "density", &v) && v == 10);
        CHECK(scene_param_get(&s, "smooth", &v) && v == 0);
        CHECK_EQ(s.scale, 3);
        CHECK_EQ(s.gw, 34);
        CHECK_EQ(s.gh, 17);
    }
    arena_put(&a);
    scene_params_clear(&p);
    scene_params_set(&p, "palette", "amber");                       /* not a fire palette */
    scene_params_set(&p, "intensity", "100.0");
    if (init_kind(&s, &a, SCENE_FIRE, &p, FW, FH, 7)) {
        CHECK(scene_param_get(&s, "palette", &v) && v == 0);       /* classic */
        CHECK(scene_param_get(&s, "intensity", &v) && v == 100);
    }
    arena_put(&a);
    scene_params_clear(&p);
    scene_params_set(&p, "palette", "blue");
    scene_params_set_int(&p, "count", 100);
    scene_params_set_int(&p, "bounce", 10);
    scene_params_set(&p, "trail", "yes");
    if (init_kind(&s, &a, SCENE_BALLS, &p, FW, FH, 7)) {
        CHECK(scene_param_get(&s, "palette", &v) && v == 3);       /* "blue" is fire-only: default candy */
        CHECK(scene_param_get(&s, "count", &v) && v == 24);
        CHECK(scene_param_get(&s, "bounce", &v) && v == 60);
        CHECK(scene_param_get(&s, "trail", &v) && v == 1);
        CHECK_EQ(s.mass, 24);
    }
    arena_put(&a);
}

static void test_init_errors(void) {
    static uint32_t arena[70000];
    scene_t s;
    size_t need = scene_arena_bytes_for(SCENE_SAND, NULL, FW, FH);
    CHECK(need > 0 && need <= sizeof arena);
    CHECK_EQ(scene_init(NULL, SCENE_SAND, NULL, FW, FH, 1, arena, need), SCENE_ERR_ARG);
    CHECK_EQ(scene_init(&s, SCENE_KIND_COUNT, NULL, FW, FH, 1, arena, need), SCENE_ERR_ARG);
    CHECK_EQ(scene_init(&s, (scene_kind_t)-1, NULL, FW, FH, 1, arena, need), SCENE_ERR_ARG);
    CHECK_EQ(scene_init(&s, SCENE_SAND, NULL, SCENE_MIN_DIM - 1, FH, 1, arena, need), SCENE_ERR_ARG);
    CHECK_EQ(scene_init(&s, SCENE_SAND, NULL, FW, SCENE_MAX_DIM + 1, 1, arena, need), SCENE_ERR_ARG);
    CHECK_EQ(scene_init(&s, SCENE_SAND, NULL, FW, FH, 1, NULL, need), SCENE_ERR_ARENA);
    CHECK_EQ(scene_init(&s, SCENE_SAND, NULL, FW, FH, 1, (uint8_t *)arena + 2, need), SCENE_ERR_ARENA);
    CHECK_EQ(scene_init(&s, SCENE_SAND, NULL, FW, FH, 1, arena, need - 1), SCENE_ERR_ARENA);
    CHECK(!s.ready);
    /* a failed init leaves an inert scene: step/render are no-ops */
    uint16_t fb[16];
    memset(fb, 0x5A, sizeof fb);
    scene_rect_t d = { 1, 2, 3, 4 };
    scene_step(&s, 0, 1, 0, 0.02f);
    scene_render(&s, fb, 4, 4, &d);
    CHECK(d.w == 0 && d.h == 0);
    CHECK_EQ(fb[0], 0x5A5A);
    CHECK_EQ(scene_init(&s, SCENE_SAND, NULL, FW, FH, 1, arena, need), SCENE_OK);
    scene_step(NULL, 0, 1, 0, 0.02f);
    scene_render(NULL, fb, 4, 4, &d);
    scene_render(&s, NULL, 4, 4, &d);
    scene_render(&s, fb, 0, 4, &d);
    CHECK(d.w == 0);
    CHECK_EQ(scene_arena_bytes(SCENE_KIND_COUNT, FW, FH), 0);
    CHECK_EQ(scene_arena_bytes(SCENE_SAND, 4, FH), 0);
    CHECK_EQ(scene_arena_bytes_for(SCENE_SAND, NULL, FW, 0), 0);
    /* memory budget: worst case over params <= 256 KB for the default screen, defaults much less */
    for (int k = 0; k < SCENE_KIND_COUNT; k++) {
        size_t worst = scene_arena_bytes((scene_kind_t)k, FW, FH);
        size_t def = scene_arena_bytes_for((scene_kind_t)k, NULL, FW, FH);
        CHECK(worst > 0 && worst <= 256u * 1024u);
        CHECK(def > 0 && def <= worst);
        CHECK(def <= 48u * 1024u);
    }
    CHECK(sizeof(scene_t) <= 1536);
}

/* Random, sometimes hostile, IMU input. */
static void hostile_input(int i, float g[3], float *dt) {
    g[0] = frands() * 1.2f; g[1] = frands() * 1.2f; g[2] = frands() * 1.2f;
    *dt = 0.01f + frand() * 0.05f;
    switch (i % 97) {
    case 3: g[0] = NAN; break;
    case 7: g[1] = INFINITY; break;
    case 11: g[2] = -INFINITY; *dt = NAN; break;
    case 13: g[0] = 1e30f; g[1] = -1e30f; break;
    case 17: *dt = 0.0f; break;
    case 19: *dt = -1.0f; break;
    case 23: *dt = 10.0f; break;
    case 29: g[0] = 6.0f * frands(); g[1] = 6.0f * frands(); break;   /* knock */
    case 31: g[0] = g[1] = 0.0f; g[2] = -1.0f; break;                  /* face up */
    default: break;
    }
}

/* Step/render every kind on several geometries with hostile input; the framebuffer is larger than
 * the scene and filled with a sentinel, so any write outside the scene's rectangle is caught; a
 * second, smaller framebuffer checks clipping. Arena guards + ASan catch the rest. */
static void run_geometry(scene_kind_t k, int w, int h, const scene_params_t *p, int steps) {
    scene_t s;
    arena_t a;
    if (!init_kind(&s, &a, k, p, w, h, th_rand())) { arena_put(&a); return; }
    if (k == SCENE_WORDS) {
        make_sheet(5, 1u << 3);
        CHECK_EQ(scene_words_set_sprites(&s, s_frames, 5, FWW, FWH), 4);
    }
    int bw = w + 9, bh = h + 5;
    uint16_t *fb = malloc((size_t)bw * bh * 2);
    for (int i = 0; i < bw * bh; i++) fb[i] = SENTINEL;
    int sw = w > 20 ? w / 2 + 1 : w, sh = h > 20 ? h / 2 + 1 : h;     /* clipped framebuffer */
    uint16_t *small = malloc((size_t)(sw + 1) * (sh + 1) * 2);
    for (int i = 0; i < (sw + 1) * (sh + 1); i++) small[i] = SENTINEL;
    int bad = 0;
    for (int i = 0; i < steps; i++) {
        float g[3], dt;
        hostile_input(i, g, &dt);
        scene_step(&s, g[0], g[1], g[2], dt);
        scene_rect_t d;
        if (i % 5 == 0) {
            scene_render(&s, fb, (uint16_t)bw, (uint16_t)bh, &d);
            if (d.w || d.h) {
                if (d.x < 0 || d.y < 0 || d.w < 0 || d.h < 0 || d.x + d.w > w || d.y + d.h > h) bad++;
            }
        }
        if (i % 50 == 25) {
            scene_render(&s, small, (uint16_t)sw, (uint16_t)sh, &d);   /* stride sw, sh rows */
            if (d.x + d.w > sw || d.y + d.h > sh) bad++;
            scene_invalidate(&s);
        }
    }
    CHECK_EQ(bad, 0);
    int outside = 0;
    for (int y = 0; y < bh; y++)
        for (int x = 0; x < bw; x++)
            if ((x >= w || y >= h) && fb[y * bw + x] != SENTINEL) outside++;
    CHECK_EQ(outside, 0);
    for (int i = sw * sh; i < (sw + 1) * (sh + 1); i++) CHECK_EQ(small[i], SENTINEL);
    CHECK(sc_finite(s.g_lp[0]) && sc_finite(s.g_lp[1]) && sc_finite(s.g_lp[2]));
    CHECK(sc_finite(s.ex) && sc_finite(s.ey) && sc_finite(s.shake));
    free(fb);
    free(small);
    arena_put(&a);
}

static void test_all_kinds_geometries(void) {
    int steps = 1500 * scale_factor;
    scene_params_t p2, p3, ps;
    scene_params_clear(&p2);
    scene_params_set_int(&p2, "scale", 2);
    scene_params_set_int(&p2, "density", 100);
    scene_params_set_int(&p2, "count", 24);
    scene_params_set_int(&p2, "trail", 1);
    scene_params_clear(&p3);
    scene_params_set_int(&p3, "scale", 3);
    scene_params_set_int(&p3, "smooth", 1);
    scene_params_clear(&ps);
    scene_params_set_int(&ps, "smooth", 1);
    scene_params_set_int(&ps, "scale", 7);
    scene_params_set_int(&ps, "density", 10);
    for (int k = 0; k < SCENE_KIND_COUNT; k++) {
        run_geometry((scene_kind_t)k, FW, FH, NULL, steps);
        run_geometry((scene_kind_t)k, 100, 50, NULL, steps);
        run_geometry((scene_kind_t)k, FW, FH, &p2, steps / 3);
        run_geometry((scene_kind_t)k, 101, 37, &p3, steps / 2);
        run_geometry((scene_kind_t)k, 37, 211, &ps, steps / 2);
        run_geometry((scene_kind_t)k, SCENE_MIN_DIM, SCENE_MIN_DIM, &p2, steps / 3);
        run_geometry((scene_kind_t)k, 999, 9, NULL, steps / 5);
    }
}

static void test_mass_conservation(void) {
    for (int k = SCENE_SAND; k <= SCENE_WATER; k++) {
        for (int variant = 0; variant < 3; variant++) {
            scene_params_t p;
            scene_params_clear(&p);
            if (variant == 1) { scene_params_set_int(&p, "density", 100); scene_params_set_int(&p, "scale", 2); }
            if (variant == 2) { scene_params_set_int(&p, "density", 10); scene_params_set_int(&p, "scale", 5); }
            scene_t s;
            arena_t a;
            if (!init_kind(&s, &a, (scene_kind_t)k, &p, variant == 2 ? 99 : FW, variant == 2 ? 61 : FH, 42 + variant)) {
                arena_put(&a);
                continue;
            }
            int n0 = count_cells(&s);
            CHECK(n0 > 0);
            CHECK_EQ(n0, s.mass);
            int steps = (variant == 1 ? 400 : 2000) * scale_factor, drift = 0;
            float ang = 0.0f;
            for (int i = 0; i < steps; i++) {
                ang += 0.03f + 0.02f * frands();
                float gx = sinf(ang) * 1.1f, gy = cosf(ang) * 1.1f, dt = 0.04f;
                if (i % 41 == 0) { gx += 3.0f * frands(); gy += 3.0f * frands(); }   /* shakes -> fling */
                if (i % 211 == 0) { gx = NAN; }
                scene_step(&s, gx, gy, 0.1f, dt);
                if (i % 97 == 0 && count_cells(&s) != n0) drift++;
            }
            CHECK_EQ(drift, 0);
            CHECK_EQ(count_cells(&s), n0);
            arena_put(&a);
        }
    }
}

/* Fire must never write outside its rectangle, including when it burns on every edge. */
static void test_fire_rect(void) {
    scene_t s;
    arena_t a;
    const int w = 100, h = 50, bw = 160, bh = 90;
    if (!init_kind(&s, &a, SCENE_FIRE, NULL, w, h, 3)) { arena_put(&a); return; }
    uint16_t *fb = malloc((size_t)bw * bh * 2);
    for (int i = 0; i < bw * bh; i++) fb[i] = SENTINEL;
    float dirs[8][2] = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 1, -1 }, { 0, -1 }, { -1, -1 }, { -1, 0 }, { -1, 1 } };
    for (int i = 0; i < 1600; i++) {
        const float *d = dirs[(i / 100) % 8];
        scene_step(&s, d[0] + 0.05f * frands(), d[1] + 0.05f * frands(), 0.0f, 0.05f);
        if (i % 300 == 150) scene_step(&s, 3.0f, -2.0f, 0.0f, 0.05f);   /* flare */
        scene_rect_t r;
        scene_render(&s, fb, bw, bh, &r);
        CHECK(r.x == 0 && r.y == 0 && r.w == w && r.h == h);
    }
    int outside = 0, lit = 0;
    for (int y = 0; y < bh; y++)
        for (int x = 0; x < bw; x++) {
            uint16_t v = fb[y * bw + x];
            if (x >= w || y >= h) outside += v != SENTINEL;
            else lit += v != 0;
        }
    CHECK_EQ(outside, 0);
    CHECK(lit > w * h / 10);   /* it actually burns */
    /* the perimeter source array stays inside the arena (guard checked by arena_put) */
    free(fb);
    arena_put(&a);
}

static void test_balls_inside(void) {
    for (int variant = 0; variant < 3; variant++) {
        scene_params_t p;
        scene_params_clear(&p);
        scene_params_set_int(&p, "count", variant == 0 ? 24 : 6);
        scene_params_set_int(&p, "size", 40);
        scene_params_set_int(&p, "bounce", 90);
        int w = variant == 2 ? 40 : FW, h = variant == 2 ? 12 : FH;
        scene_t s;
        arena_t a;
        if (!init_kind(&s, &a, SCENE_BALLS, &p, w, h, 9 + variant)) { arena_put(&a); continue; }
        int outside = 0, nonfinite = 0;
        for (int i = 0; i < 3000 * scale_factor; i++) {
            float gx = (i / 7) % 2 ? 4.0f : -4.0f, gy = (i / 11) % 2 ? 4.0f : -4.0f;
            if (i % 13 == 0) { gx = 8.0f * frands(); gy = 8.0f * frands(); }
            float dt = (i % 17 == 0) ? 5.0f : 0.05f;   /* huge dt (clamped internally) */
            scene_step(&s, gx, gy, 0.0f, dt);
            for (int b = 0; b < s.mass; b++) {
                float x, y, r;
                CHECK(sc_balls_get(&s, b, &x, &y, &r));
                if (!sc_finite(x) || !sc_finite(y)) { nonfinite++; continue; }
                if (2 * r <= (float)w && (x < r - 0.01f || x > (float)w - r + 0.01f)) outside++;
                if (2 * r <= (float)h && (y < r - 0.01f || y > (float)h - r + 0.01f)) outside++;
                if (x < 0 || y < 0 || x > (float)w || y > (float)h) outside++;
            }
        }
        CHECK_EQ(outside, 0);
        CHECK_EQ(nonfinite, 0);
        CHECK(!sc_balls_get(&s, s.mass, &(float){ 0 }, &(float){ 0 }, &(float){ 0 }));
        arena_put(&a);
    }
}

/* Resting balls stop producing dirty rectangles; moving ones only repaint where they were/are. */
static void test_balls_dirty(void) {
    scene_t s;
    arena_t a;
    if (!init_kind(&s, &a, SCENE_BALLS, NULL, FW, FH, 5)) { arena_put(&a); return; }
    static uint16_t fb[FW * FH];
    scene_rect_t d;
    scene_render(&s, fb, FW, FH, &d);
    CHECK(d.x == 0 && d.y == 0 && d.w == FW && d.h == FH);   /* first render is full */
    for (int i = 0; i < 1500; i++) scene_step(&s, 0.0f, 1.0f, 0.0f, 0.03f);
    scene_render(&s, fb, FW, FH, &d);
    scene_step(&s, 0.0f, 1.0f, 0.0f, 0.03f);
    scene_render(&s, fb, FW, FH, &d);
    CHECK_EQ(d.w, 0);
    CHECK_EQ(d.h, 0);
    scene_invalidate(&s);
    scene_render(&s, fb, FW, FH, &d);
    CHECK(d.w == FW && d.h == FH);
    arena_put(&a);
}

static uint64_t run_hash(scene_kind_t k, uint32_t seed, int frames, bool full_every_frame, const scene_params_t *p) {
    scene_t s;
    arena_t a;
    if (!init_kind(&s, &a, k, p, FW, FH, seed)) { arena_put(&a); return 0; }
    if (k == SCENE_WORDS) {
        make_sheet(6, 0);
        scene_words_set_sprites(&s, s_frames, 6, FWW, FWH);
    }
    static uint16_t fb[FW * FH];
    memset(fb, 0, sizeof fb);
    uint64_t h = 0;
    uint32_t r = 0xBADC0DEu;
    for (int i = 0; i < frames; i++) {
        r ^= r << 13; r ^= r >> 17; r ^= r << 5;
        float gx = sinf((float)i * 0.05f) * 0.9f + (float)(r & 255) / 4096.0f, gy = cosf((float)i * 0.05f);
        if (i % 37 == 0) gx += 2.5f;
        scene_step(&s, gx, gy, 0.05f, 0.05f);
        if (full_every_frame) scene_invalidate(&s);
        scene_render(&s, fb, FW, FH, NULL);
        h = h * 31u + fnv(fb, sizeof fb);
    }
    arena_put(&a);
    return h;
}

static void test_determinism(void) {
    scene_params_t trail;
    scene_params_clear(&trail);
    scene_params_set_int(&trail, "trail", 1);
    scene_params_set_int(&trail, "smooth", 1);
    for (int k = 0; k < SCENE_KIND_COUNT; k++) {
        uint64_t a = run_hash((scene_kind_t)k, 1234, 120, false, NULL);
        uint64_t b = run_hash((scene_kind_t)k, 1234, 120, false, NULL);
        uint64_t c = run_hash((scene_kind_t)k, 1235, 120, false, NULL);
        CHECK(a != 0);
        CHECK(a == b);          /* same seed + same input => identical frames */
        CHECK(a != c);          /* the seed matters */
        /* incremental (dirty-rect) rendering == full repaint of the same state */
        uint64_t f = run_hash((scene_kind_t)k, 1234, 120, true, NULL);
        CHECK(a == f);
        uint64_t t1 = run_hash((scene_kind_t)k, 77, 90, false, &trail);
        uint64_t t2 = run_hash((scene_kind_t)k, 77, 90, true, &trail);
        CHECK(t1 == t2);
    }
}

static void test_axis_map(void) {
    float g[3];
    scene_gravity_from_imu(&SCENE_AXIS_MAP_IDENTITY_FLIP, 0.1f, -1.0f, 0.2f, g);
    CHECK(g[0] == -0.1f && g[1] == 1.0f && g[2] == -0.2f);
    scene_gravity_from_imu(NULL, 1.0f, 2.0f, 3.0f, g);
    CHECK(g[0] == -1.0f && g[1] == -2.0f && g[2] == -3.0f);
    scene_gravity_from_imu(&SCENE_IMU_AXIS_MAP, 0.0f, 0.0f, 1.0f, g);
    CHECK(sc_finite(g[0]) && sc_finite(g[1]) && sc_finite(g[2]));
    /* chip mounted right-handed: X = display right, Y = display up, Z = out of the glass */
    float up1[3] = { 0.02f, 0.99f, 0.05f }, fu1[3] = { 0.01f, -0.03f, 1.0f };
    scene_axis_map_t m;
    CHECK(scene_axis_map_calibrate(up1, fu1, &m));
    scene_gravity_from_imu(&m, 0.0f, 1.0f, 0.0f, g);          /* upright */
    CHECK(g[0] == 0.0f && g[1] == 1.0f && g[2] == 0.0f);
    scene_gravity_from_imu(&m, 0.0f, 0.0f, 1.0f, g);          /* face up */
    CHECK(g[0] == 0.0f && g[1] == 0.0f && g[2] == -1.0f);
    scene_gravity_from_imu(&m, -1.0f, 0.0f, 0.0f, g);         /* right edge down: chip reads -X up */
    CHECK(g[0] == 1.0f && g[1] == 0.0f && g[2] == 0.0f);
    /* rotated mounting (right-handed): chip X = display down, chip Y = display right, chip Z = out of the glass */
    float up2[3] = { -1.0f, 0.0f, 0.0f }, fu2[3] = { 0.0f, 0.0f, 1.0f };
    CHECK(scene_axis_map_calibrate(up2, fu2, &m));
    scene_gravity_from_imu(&m, 0.0f, -1.0f, 0.0f, g);         /* right edge down: up = display left = -Y */
    CHECK(g[0] == 1.0f && g[1] == 0.0f && g[2] == 0.0f);
    /* each row is a signed unit vector, rows orthogonal */
    for (int i = 0; i < 3; i++) {
        int nz = 0;
        for (int j = 0; j < 3; j++) nz += m.m[i][j] != 0;
        CHECK_EQ(nz, 1);
    }
    /* bad input */
    float same[3] = { 0.0f, 1.0f, 0.0f }, weak[3] = { 0.5f, 0.5f, 0.5f }, nan3[3] = { NAN, 1.0f, 0.0f };
    CHECK(!scene_axis_map_calibrate(same, same, &m));
    CHECK(!scene_axis_map_calibrate(weak, fu1, &m));
    CHECK(!scene_axis_map_calibrate(nan3, fu1, &m));
    CHECK(!scene_axis_map_calibrate(NULL, fu1, &m));
}

/* IMU conditioning: first sample initialises the filter, noise does not trigger kicks, a knock does,
 * face-up keeps a small but non-zero effective gravity. */
static void test_imu_conditioning(void) {
    scene_t s;
    arena_t a;
    if (!init_kind(&s, &a, SCENE_SAND, NULL, FW, FH, 1)) { arena_put(&a); return; }
    scene_step(&s, 0.7f, 0.7f, 0.0f, 0.02f);
    CHECK(fabsf(s.g_lp[0] - 0.7f) < 1e-6f && s.shake == 0.0f);
    for (int i = 0; i < 200; i++) scene_step(&s, 0.7f + 0.03f * frands(), 0.7f + 0.03f * frands(), 0.03f * frands(), 0.02f);
    CHECK(s.shake < 0.05f);
    scene_step(&s, 3.0f, 0.7f, 0.0f, 0.02f);
    CHECK(s.shake > 1.0f);
    for (int i = 0; i < 400; i++) scene_step(&s, 0.01f * frands(), 0.01f * frands(), -1.0f, 0.02f);
    float em = sqrtf(s.ex * s.ex + s.ey * s.ey);
    CHECK(em > 0.1f && em < 0.5f);   /* gentle drift, not frozen, not full gravity */
    arena_put(&a);
}

/* ---- §5b.1 words ---------------------------------------------------------------------------------------------- */

/* Overlap of words i and j (pixels; <= 0: apart). */
static float word_overlap(const scene_t *s, int i, int j) {
    float ax, ay, aw, ah, bx, by, bw, bh;
    sc_words_get(s, i, &ax, &ay, &aw, &ah);
    sc_words_get(s, j, &bx, &by, &bw, &bh);
    const float ox = fminf(ax + aw, bx + bw) - fmaxf(ax, bx), oy = fminf(ay + ah, by + bh) - fmaxf(ay, by);
    return ox > 0.0f && oy > 0.0f ? fminf(ox, oy) : 0.0f;
}

static void steps(scene_t *s, float gx, float gy, float seconds) {
    for (int i = 0; i < (int)(seconds * 30.0f + 0.5f); i++) scene_step(s, gx, gy, 0.0f, 1.0f / 30.0f);
}

static void test_words_sprites(void) {
    scene_t s;
    arena_t a;
    CHECK(scene_follows_orientation(SCENE_WORDS));
    for (int k = 0; k < SCENE_WORDS; k++) CHECK(!scene_follows_orientation((scene_kind_t)k));
    float g[3] = { 0.25f, 1.0f, -0.5f };
    scene_gravity_flipped(g);
    CHECK(g[0] == -0.25f && g[1] == -1.0f && g[2] == -0.5f);
    scene_gravity_flipped(NULL);
    if (!init_kind(&s, &a, SCENE_WORDS, NULL, FW, FH, 3)) { arena_put(&a); return; }
    int32_t v;
    CHECK(scene_param_get(&s, "bounce", &v) && v == 60);
    /* the tight ink boxes; empty frames skipped */
    make_sheet(5, (1u << 1) | (1u << 4));
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, 5, FWW, FWH), 3);
    CHECK_EQ(s.mass, 3);
    static const int fr[3] = { 0, 2, 3 };
    for (int i = 0; i < 3; i++) {
        float x, y, w, h;
        CHECK(sc_words_get(&s, i, &x, &y, &w, &h));
        CHECK(w == (float)sheet_ink_w(fr[i]) && h == 24.0f);
        CHECK(x >= 0.0f && x + w <= FW && y >= 0.0f && y + h <= FH);
        for (int j = 0; j < i; j++) CHECK(word_overlap(&s, i, j) == 0.0f);   /* placed apart */
    }
    CHECK(!sc_words_get(&s, 3, &(float){ 0 }, &(float){ 0 }, &(float){ 0 }, &(float){ 0 }));
    /* rendering: the sprite's pixels at the word's integer position, black passes through (the hole) */
    static uint16_t fb[FW * FH];
    for (int i = 0; i < FW * FH; i++) fb[i] = 0x1234;
    scene_rect_t d;
    scene_render(&s, fb, FW, FH, &d);
    CHECK(d.x == 0 && d.y == 0 && d.w == FW && d.h == FH);
    float x, y, w, h;
    sc_words_get(&s, 1, &x, &y, &w, &h);
    const int dx = (int)lroundf(x), dy = (int)lroundf(y);
    int same = 0, diff = 0;
    for (int yy = 0; yy < 24; yy++)
        for (int xx = 0; xx < (int)w; xx++) {
            const uint16_t want = s_sheet[2][(8 + yy) * FWW + 10 + xx], got = fb[(dy + yy) * FW + dx + xx];
            if (want ? got == want : got == 0) same++;
            else diff++;
        }
    CHECK_EQ(diff, 0);
    CHECK(same == 24 * (int)w);
    CHECK_EQ(fb[(dy + 10) * FW + dx + 9], 0);   /* the hole (frame x 18..21, y 16..23) is black */
    /* all black: no words, a black screen */
    make_sheet(3, 7u);
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, 3, FWW, FWH), 0);
    for (int i = 0; i < FW * FH; i++) fb[i] = 0x1234;
    scene_invalidate(&s);
    steps(&s, 0.0f, 1.0f, 0.5f);
    scene_render(&s, fb, FW, FH, &d);
    int ink = 0;
    for (int i = 0; i < FW * FH; i++) ink += fb[i] != 0;
    CHECK_EQ(ink, 0);
    /* limits and bad arguments */
    make_sheet(SCENE_WORDS_MAX, 0);
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, SCENE_WORDS_MAX, FWW, FWH), SCENE_WORDS_MAX);
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, 0, FWW, FWH), -1);
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, SCENE_WORDS_MAX + 1, FWW, FWH), -1);
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, 1, 537, 10), -1);
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, 1, 10, 241), -1);
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, 1, 0, 10), -1);
    CHECK_EQ(scene_words_set_sprites(&s, s_frames, 12, 536, 81), -1);     /* 520 992 px > 514 560 */
    {   /* exactly at the limit: 12 x 536 x 80 = 514 560 px (all black here: no words) */
        static uint16_t big[SCENE_WORDS_MAX_PX];
        const uint16_t *bf[12];
        for (int f = 0; f < 12; f++) bf[f] = big + (size_t)f * 536 * 80;
        CHECK_EQ(scene_words_set_sprites(&s, bf, 12, 536, 80), 0);
        big[5 * 536 * 80 + 40 * 536 + 300] = 0xFFFF;   /* one ink pixel in frame 5: a 1x1 word */
        CHECK_EQ(scene_words_set_sprites(&s, bf, 12, 536, 80), 1);
        float x, y, w, h;
        CHECK(sc_words_get(&s, 0, &x, &y, &w, &h) && w == 1.0f && h == 1.0f);
    }
    const uint16_t *holes[2] = { s_frames[0], NULL };
    CHECK_EQ(scene_words_set_sprites(&s, holes, 2, FWW, FWH), -1);
    CHECK_EQ(scene_words_set_sprites(&s, NULL, 1, FWW, FWH), -1);
    CHECK_EQ(scene_words_set_sprites(NULL, s_frames, 1, FWW, FWH), -1);
    arena_put(&a);
    scene_t b;
    if (init_kind(&b, &a, SCENE_BALLS, NULL, FW, FH, 3)) CHECK_EQ(scene_words_set_sprites(&b, s_frames, 1, FWW, FWH), -1);
    arena_put(&a);
    /* without sprites a words scene is black and does nothing */
    if (init_kind(&s, &a, SCENE_WORDS, NULL, FW, FH, 4)) {
        steps(&s, 0.3f, 1.0f, 0.5f);
        for (int i = 0; i < FW * FH; i++) fb[i] = 0x1234;
        scene_render(&s, fb, FW, FH, &d);
        CHECK(fb[100 * FW + 100] == 0 && d.w == FW);
    }
    arena_put(&a);
}

/* Under 1 g a word settles on the floor within ~2 s, stays there, and stops repainting. */
static void test_words_settle(void) {
    scene_t s;
    arena_t a;
    if (!init_words(&s, &a, NULL, 1, 0, FW, FH, 11)) { arena_put(&a); return; }
    float x, y, w, h, vx, vy;
    int t_rest = -1;
    for (int i = 0; i < 90; i++) {   /* 3 s at 30 fps */
        scene_step(&s, 0.0f, 1.0f, 0.0f, 1.0f / 30.0f);
        sc_words_get(&s, 0, &x, &y, &w, &h);
        sc_words_speed(&s, 0, &vx, &vy);
        const bool rest = fabsf(y + h - FH) < 0.5f && fabsf(vx) < 1.0f && fabsf(vy) < 1.0f;
        if (rest && t_rest < 0) t_rest = i;
        if (!rest) t_rest = -1;
    }
    CHECK(t_rest >= 0 && t_rest <= 66);   /* at rest on the floor within 2.2 s, and still at 3 s */
    printf("     a word comes to rest on the floor after %.2f s\n", t_rest / 30.0);
    const float x0 = x, y0 = y;
    static uint16_t fb[FW * FH];
    scene_rect_t d;
    scene_render(&s, fb, FW, FH, &d);
    steps(&s, 0.0f, 1.0f, 5.0f);
    sc_words_get(&s, 0, &x, &y, &w, &h);
    CHECK(fabsf(x - x0) < 0.5f && fabsf(y - y0) < 0.5f);
    scene_render(&s, fb, FW, FH, &d);
    CHECK(d.w == 0 && d.h == 0);   /* resting: nothing to repaint */
    /* a tilt it cannot slide down (friction): still; a steep one: it slides to the wall (tilted slowly, as a hand
     * does: a sudden jolt is a knock) */
    for (int i = 0; i <= 30; i++) scene_step(&s, 0.3f * (float)i / 30.0f, 1.0f, 0.0f, 1.0f / 30.0f);
    steps(&s, 0.3f, 1.0f, 2.0f);
    sc_words_get(&s, 0, &x, &y, &w, &h);
    CHECK(fabsf(x - x0) < 1.0f);
    for (int i = 0; i <= 30; i++) scene_step(&s, 0.3f + 0.7f * (float)i / 30.0f, 1.0f - 0.4f * (float)i / 30.0f, 0.0f, 1.0f / 30.0f);
    steps(&s, 1.0f, 0.6f, 3.0f);
    sc_words_get(&s, 0, &x, &y, &w, &h);
    CHECK(fabsf(x + w - FW) < 0.5f && fabsf(y + h - FH) < 0.5f);   /* in the bottom-right corner */
    arena_put(&a);
}

/* Restitution: the first rebound keeps ~bounce % of the impact speed; bounce 0 does not rebound. */
static float first_rebound(int bounce) {
    scene_params_t p;
    scene_params_clear(&p);
    scene_params_set_int(&p, "bounce", bounce);
    scene_t s;
    arena_t a;
    float ratio = -1.0f;
    if (init_words(&s, &a, &p, 1, 0, FW, FH, 21)) {
        float vy, vx, impact = 0.0f;
        for (int i = 0; i < 300; i++) {
            sc_words_speed(&s, 0, &vx, &vy);
            const float before = vy;
            scene_step(&s, 0.0f, 1.0f, 0.0f, 1.0f / 240.0f);   /* one sub-step per call */
            sc_words_speed(&s, 0, &vx, &vy);
            if (before > 100.0f && vy <= 0.0f) {
                impact = before;
                ratio = -vy / impact;
                break;
            }
        }
        CHECK(impact > 300.0f);
    }
    arena_put(&a);
    return ratio;
}

static void test_words_bounce(void) {
    const float r60 = first_rebound(60), r0 = first_rebound(0), r100 = first_rebound(100);
    printf("     first rebound: bounce 0 -> %.2f, 60 -> %.2f, 100 -> %.2f of the impact speed\n", r0, r60, r100);
    CHECK(r0 == 0.0f);
    CHECK(r60 > 0.55f && r60 < 0.62f);
    CHECK(r100 > 0.95f && r100 <= 1.0f);
    /* sideways: gravity to the right, the word ends on the right edge (an edge bounce) */
    scene_t s;
    arena_t a;
    if (init_words(&s, &a, NULL, 1, 0, FW, FH, 5)) {
        steps(&s, 1.0f, 0.0f, 3.0f);
        float x, y, w, h;
        sc_words_get(&s, 0, &x, &y, &w, &h);
        CHECK(fabsf(x + w - FW) < 0.5f);
        steps(&s, -1.0f, 0.0f, 3.0f);
        sc_words_get(&s, 0, &x, &y, &w, &h);
        steps(&s, -1.0f, 0.0f, 3.0f);   /* (the sudden reversal is a hard knock: a few more bounces) */
        sc_words_get(&s, 0, &x, &y, &w, &h);
        CHECK(fabsf(x) < 0.5f);
        steps(&s, 0.0f, -1.0f, 5.0f);   /* the ceiling */
        sc_words_get(&s, 0, &x, &y, &w, &h);
        CHECK(fabsf(y) < 0.5f);
    }
    arena_put(&a);
}

/* Words never overlap once settled (side by side or stacked), stay inside, and come to rest; a shake sends them
 * flying and they settle again; then a flipped panel: they rest at the framebuffer's top (the physical bottom). */
static void test_words_stack(void) {
    for (int n = 2; n <= SCENE_WORDS_MAX; n += 5) {
        scene_t s;
        arena_t a;
        if (!init_words(&s, &a, NULL, n, 0, FW, FH, 100 + (uint32_t)n)) { arena_put(&a); continue; }
        steps(&s, 0.0f, 1.0f, 4.0f);
        float worst = 0.0f, vmax = 0.0f;
        for (int i = 0; i < n; i++) {
            float x, y, w, h, vx, vy;
            sc_words_get(&s, i, &x, &y, &w, &h);
            sc_words_speed(&s, i, &vx, &vy);
            CHECK(x >= -0.01f && y >= -0.01f && x + w <= FW + 0.01f && y + h <= FH + 0.01f);
            vmax = fmaxf(vmax, fmaxf(fabsf(vx), fabsf(vy)));
            for (int j = 0; j < i; j++) worst = fmaxf(worst, word_overlap(&s, i, j));
        }
        printf("     %2d words settled: worst overlap %.3f px, fastest %.2f px/s\n", n, worst, vmax);
        CHECK(worst < 0.5f);
        CHECK(vmax < 1.0f);
        /* a shake: they move, then settle again without overlap */
        float x0, y0, w, h, x1, y1;
        sc_words_get(&s, 0, &x0, &y0, &w, &h);
        scene_step(&s, 0.0f, 1.0f, 0.0f, 1.0f / 30.0f);
        scene_step(&s, 3.0f, -2.0f, 0.0f, 1.0f / 30.0f);
        steps(&s, 0.0f, 1.0f, 0.2f);
        sc_words_get(&s, 0, &x1, &y1, &w, &h);
        CHECK(fabsf(x1 - x0) + fabsf(y1 - y0) > 2.0f);
        steps(&s, 0.0f, 1.0f, 4.0f);
        worst = 0.0f;
        for (int i = 0; i < n; i++)
            for (int j = 0; j < i; j++) worst = fmaxf(worst, word_overlap(&s, i, j));
        CHECK(worst < 0.5f);
        /* flipped panel: the physical bottom is the framebuffer's top */
        float gf[3] = { 0.0f, 1.0f, 0.0f };
        scene_gravity_flipped(gf);
        steps(&s, gf[0], gf[1], 4.0f);
        float ymin = 1e9f;
        for (int i = 0; i < n; i++) {
            float x, y;
            sc_words_get(&s, i, &x, &y, &w, &h);
            ymin = fminf(ymin, y);
            for (int j = 0; j < i; j++) CHECK(word_overlap(&s, i, j) < 0.5f);
        }
        CHECK(ymin < 0.5f);
        arena_put(&a);
    }
}

int main(void) {
    const char *sf = getenv("SCENE_TEST_SCALE");
    if (sf && atoi(sf) > 0) scale_factor = atoi(sf);
    RUN(test_registry);
    RUN(test_describe_json);
    RUN(test_params);
    RUN(test_init_errors);
    RUN(test_all_kinds_geometries);
    RUN(test_mass_conservation);
    RUN(test_fire_rect);
    RUN(test_balls_inside);
    RUN(test_balls_dirty);
    RUN(test_determinism);
    RUN(test_axis_map);
    RUN(test_imu_conditioning);
    RUN(test_words_sprites);
    RUN(test_words_settle);
    RUN(test_words_bounce);
    RUN(test_words_stack);
    return TH_DONE("test_scene");
}
