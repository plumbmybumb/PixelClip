/* scene_fire.c — heat scenes: fire (Doom-fire propagation along any gravity direction) and lava
 * (metaball "lava lamp" blobs that heat at the bottom, rise, cool and sink).
 */
#include "scene_internal.h"

/* ------------------------------------------------------------------------------------------ */
/* Fire                                                                                        */
/* Each step every cell pulls heat from its downstream neighbour (along gravity, dithered between
 * the two bracketing compass directions, with a little sideways wind) minus a random decay.
 * Cells whose downstream neighbour lies outside the grid pull from a flickering source line that
 * runs around the perimeter, so whichever edges face "down" burn: the bottom when upright, the
 * bottom and a side at 45°, a side when the clip lies on its edge. Loop order is upstream-first so
 * the update is in place.                                                                        */

#define FIRE_RATE 38.0f   /* steps per second */

typedef struct {
    int per;           /* perimeter length: 2 * (gw + gh) */
    float flare;       /* extra height after a shake, decays */
    uint8_t cool[64 * 64];  /* smooth noise cooling map, scrolled with the flames */
    uint8_t src[];     /* per perimeter position: current source heat [0, per), target heat [per, 2 per) */
} sc_fire_t;

size_t sc_fire_extra(int gw, int gh, const int32_t *pv) {
    (void)pv;
    return sizeof(sc_fire_t) + (size_t)(4 * (gw + gh));
}

static inline uint32_t xs32f(uint32_t *r) {
    uint32_t x = *r;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return *r = x;
}

/* Perimeter index of an out-of-grid position just outside the grid. */
static inline int perim(int gw, int gh, int x, int y) {
    if (y >= gh) return sc_clampi(x, 0, gw - 1);                          /* bottom, left->right */
    if (x >= gw) return gw + (gh - 1 - sc_clampi(y, 0, gh - 1));          /* right, bottom->top */
    if (y < 0) return gw + gh + (gw - 1 - sc_clampi(x, 0, gw - 1));       /* top, right->left */
    return 2 * gw + gh + sc_clampi(y, 0, gh - 1);                         /* left, top->bottom */
}

/* The source line: each position eases toward a target heat that is re-rolled now and then, so
 * tongues persist for a few tenths of a second (vertical structure) while the random decay makes
 * them flicker. A white-noise source would give horizontal streaks instead. */
static void fire_source(scene_t *s, sc_fire_t *fi) {
    int per = fi->per;
    uint8_t *src = fi->src, *tgt = fi->src + per;
    int base = 200 + (int)(s->pv[P_AMOUNT] * 4 / 5) + (int)(fi->flare * 80.0f);
    if (base > 255) base = 255;
    for (int p = 0; p < per; p++) {
        uint32_t r = sc_rand(s);
        if ((r & 15u) == 0) {
            uint32_t k = (r >> 8) & 255u;
            int t = k < 30 ? (base >> 1) + (int)(k & 31u) : base - (int)((k * 60u) >> 8);   /* ~12% weak spots */
            tgt[p] = (uint8_t)sc_clampi(t, 0, 255);
        }
        int v = src[p];
        v += (tgt[p] - v) / 3;
        src[p] = (uint8_t)sc_clampi(v, 0, 255);
    }
}

static void fire_pass(scene_t *s, sc_fire_t *fi) {
    sc_flow_t f;
    sc_flow_make(s, &f, false);   /* upstream first: the source neighbour is still last step's */
    int gw = s->gw, gh = s->gh;
    uint8_t *heat = s->cells;
    fire_source(s, fi);
    /* decay so that flames reach a fraction of the grid extent along gravity */
    float em = sc_sqrtf(s->ex * s->ex + s->ey * s->ey);
    float enx = em > 1e-3f ? sc_absf(s->ex) / em : 0.0f, eny = em > 1e-3f ? sc_absf(s->ey) / em : 1.0f;
    float ext = (enx * (float)gw + eny * (float)gh) / (enx + eny);
    float fh = (0.22f + 0.0055f * (float)s->pv[P_AMOUNT]) * (1.0f + fi->flare);
    float avg = 255.0f / sc_maxf(4.0f, fh * ext);
    uint32_t dmax_q8 = (uint32_t)((2.0f * avg + 1.0f) * 256.0f);
    if (dmax_q8 > 255u * 256u) dmax_q8 = 255u * 256u;
    int jx = sc_dx[(f.knear + 2) & 7], jy = sc_dy[(f.knear + 2) & 7];   /* wind: perpendicular to gravity */
    /* the cooling map moves upstream one cell per step, i.e. with the heat: a parcel keeps its
     * cooling rate while it rises, so weakly cooled columns burn tall (tongues) */
    int up_o = f.outer_y ? (s->ey > 0 ? -1 : 1) : (s->ex > 0 ? -1 : 1);
    int scroll = 256 - up_o * (int)(s->steps & 255u);   /* >= 1: keeps ka non-negative */
    const uint8_t *cool = fi->cool;
    /* the minority direction may draw from the source edge only once the tilt is noticeable */
    bool side_burn = f.p_next > 16384u && f.p_next < 49152u;
    int y0 = f.desc_y ? gh - 1 : 0, ys = f.desc_y ? -1 : 1;
    int x0 = f.desc_x ? gw - 1 : 0, xs = f.desc_x ? -1 : 1;
    int on = f.outer_y ? gh : gw, in = f.outer_y ? gw : gh;
    int ix = f.outer_y ? xs : 0, iy = f.outer_y ? 0 : ys;
    ptrdiff_t pin = (ptrdiff_t)iy * gw + ix, joff = (ptrdiff_t)jy * gw + jx;
    ptrdiff_t off[8];
    for (int k = 0; k < 8; k++) off[k] = (ptrdiff_t)sc_dy[k] * gw + sc_dx[k];
    uint32_t rng = s->rng;
    uint8_t dec[64];
    for (int oi = 0; oi < on; oi++) {
        int x = f.outer_y ? x0 : x0 + oi * xs, y = f.outer_y ? y0 + oi * ys : y0;
        /* this line's decay per position across the flow: cooling map stretched 4x along the flow,
         * interpolated between its rows, scaled by dmax */
        int ka = (f.outer_y ? y : x) + scroll;
        int r0 = (ka >> 2) & 63, fa = ka & 3;
        const uint8_t *c0 = cool + (r0 << 6), *c1 = cool + (((r0 + 1) & 63) << 6);
        for (int k = 0; k < 64; k++)
            dec[k] = (uint8_t)(((uint32_t)(c0[k] * (4 - fa) + c1[k] * fa) * dmax_q8) >> 18);
        uint8_t *pc = heat + (ptrdiff_t)y * gw + x;
        for (int ii = 0; ii < in; ii++, x += ix, y += iy, pc += pin) {
            uint32_t r = xs32f(&rng);
            int p = (r & 0xFFFFu) < f.p_next ? (f.k0 + 1) & 7 : f.k0;
            int bx = x + sc_dx[p], by = y + sc_dy[p];
            const uint8_t *pb = pc + off[p];
            int h;
            bool oob = (unsigned)bx >= (unsigned)gw || (unsigned)by >= (unsigned)gh;
            if (oob && p != f.knear && !side_burn) {
                /* a slight tilt must not light the side wall: use the nearest direction instead */
                int nx = x + sc_dx[f.knear], ny = y + sc_dy[f.knear];
                if ((unsigned)nx < (unsigned)gw && (unsigned)ny < (unsigned)gh) { bx = nx; by = ny; pb = pc + off[f.knear]; oob = false; }
            }
            if (oob) {
                h = fi->src[perim(gw, gh, bx, by)];
            } else {
                /* blend the downstream cell with its two neighbours across the flow (2:1:1) */
                int a = *pb;
                int l = ((unsigned)(bx + jx) < (unsigned)gw && (unsigned)(by + jy) < (unsigned)gh) ? pb[joff] : a;
                int rr = ((unsigned)(bx - jx) < (unsigned)gw && (unsigned)(by - jy) < (unsigned)gh) ? pb[-joff] : a;
                h = (2 * a + l + rr + 2) >> 2;
            }
            h -= dec[(f.outer_y ? x : y) & 63] + (int)((r >> 19) & 1u);
            *pc = (uint8_t)(h > 0 ? h : 0);
        }
    }
    s->rng = rng;
    s->steps++;
}

/* A rising spark: a hot cell somewhere inside the flames (it is pulled upstream and fades). */
static void fire_sparks(scene_t *s, int n) {
    size_t ncells = (size_t)s->gw * s->gh;
    for (int i = 0; i < n; i++) {
        size_t idx = ((uint64_t)sc_rand(s) * ncells) >> 32;
        if (s->cells[idx] > 60) s->cells[idx] = 255;
    }
}

void sc_fire_init(scene_t *s) {
    /* heat -> palette position: lift the mid tones so the body of the flame reads bright */
    uint8_t map[256];
    for (int i = 0; i < 256; i++) {
        int lin = i, sq = 255 - ((255 - i) * (255 - i) >> 8);   /* 1-(1-x)^2 */
        map[i] = (uint8_t)((lin + sq) >> 1);
    }
    sc_lut_build(s, map);
    sc_fire_t *fi = (sc_fire_t *)s->extra;
    fi->per = 2 * (s->gw + s->gh);
    for (int p = 0; p < 2 * fi->per; p++) fi->src[p] = 220;
    /* cooling map: white noise, 3 wrap-around box blurs, stretched to 0..255 */
    uint8_t *c = fi->cool;
    for (int i = 0; i < 64 * 64; i++) c[i] = (uint8_t)(sc_rand(s) >> 24);
    for (int pass = 0; pass < 3; pass++) {
        uint8_t tmp[64];
        for (int y = 0; y < 64; y++) {   /* horizontal, wide: tongue width */
            for (int x = 0; x < 64; x++)
                tmp[x] = (uint8_t)((c[y * 64 + ((x + 63) & 63)] + 2 * c[y * 64 + x] + c[y * 64 + ((x + 1) & 63)] + 2) >> 2);
            memcpy(c + y * 64, tmp, 64);
        }
        for (int x = 0; x < 64; x++) {   /* vertical: tongue length */
            for (int y = 0; y < 64; y++)
                tmp[y] = (uint8_t)((c[((y + 63) & 63) * 64 + x] + 2 * c[y * 64 + x] + c[((y + 1) & 63) * 64 + x] + 2) >> 2);
            for (int y = 0; y < 64; y++) c[y * 64 + x] = tmp[y];
        }
    }
    int lo = 255, hi = 0;
    for (int i = 0; i < 64 * 64; i++) { if (c[i] < lo) lo = c[i]; if (c[i] > hi) hi = c[i]; }
    for (int i = 0; i < 64 * 64; i++) c[i] = (uint8_t)(hi > lo ? (c[i] - lo) * 255 / (hi - lo) : 128);
    for (int i = 0; i < 40; i++) fire_pass(s, fi);   /* pre-warm: start with flames already up */
}

void sc_fire_step(scene_t *s, float dt, float kick) {
    sc_fire_t *fi = (sc_fire_t *)s->extra;
    if (kick > 0.0f) {
        fi->flare = sc_minf(0.8f, fi->flare + kick * 0.35f);
        fire_sparks(s, 6 + (int)(kick * 40.0f));
    }
    fi->flare = sc_maxf(0.0f, fi->flare - dt * 0.9f);
    s->acc += dt * FIRE_RATE;
    int n = (int)s->acc;
    if (n > 4) { n = 4; s->acc = 0.0f; }
    s->acc -= (float)n;
    for (int i = 0; i < n; i++) {
        fire_pass(s, fi);
        if ((sc_rand(s) & 7u) == 0) fire_sparks(s, 1);
    }
}

void sc_fire_prepare(scene_t *s) { memcpy(s->shade, s->cells, (size_t)s->gw * s->gh); }

/* ------------------------------------------------------------------------------------------ */
/* Lava                                                                                        */
/* Field = pool along the bottom edge (relative to gravity) + Σ blobs K·(1 - d²/R²)², with K growing
 * with the blob's temperature. Iso level T = 256: inside is the lava (rim = cooler crust colour,
 * core = hot), outside a faint glow. Blobs heat in the pool, rise (buoyancy ∝ temperature - 0.45),
 * cool near the top and sink again.                                                              */

#define LAVA_T 256
typedef struct { float x, y, vx, vy, r, t; } sc_blob_t;
typedef struct {
    int n;
    sc_blob_t b[SC_LAVA_BLOBS_MAX];
    uint16_t field[];
} sc_lava_t;

static int lava_blobs(const int32_t *pv) { return sc_clampi(4 + (int)pv[P_AMOUNT] * 12 / 100, 4, SC_LAVA_BLOBS_MAX); }

size_t sc_lava_extra(int gw, int gh, const int32_t *pv) {
    (void)pv;
    return sizeof(sc_lava_t) + (size_t)gw * gh * 2u;
}

void sc_lava_init(scene_t *s) {
    uint8_t map[256];
    for (int i = 0; i < 256; i++) {
        int pos;
        if (i < 100) pos = (i * 120) >> 8;                        /* outside: faint glow 0..46 */
        else pos = 105 + ((i - 100) * 150) / 155;                 /* crust 105 -> hot core 255 */
        map[i] = (uint8_t)sc_clampi(pos, 0, 255);
    }
    sc_lut_build(s, map);
    sc_lava_t *lv = (sc_lava_t *)s->extra;
    lv->n = lava_blobs(s->pv);
    float base = (float)(s->gh < s->gw ? s->gh : s->gw) * 0.12f;
    for (int i = 0; i < lv->n; i++) {
        sc_blob_t *b = &lv->b[i];
        b->r = base * (0.6f + 0.9f * sc_randf(s));
        b->x = b->r + sc_randf(s) * ((float)s->gw - 2.0f * b->r);
        /* half start resting in the pool (cool), the others already on their way */
        b->y = (i & 1) ? (float)s->gh - b->r * 0.6f : b->r + sc_randf(s) * ((float)s->gh - 2.0f * b->r);
        b->t = (i & 1) ? 0.2f * sc_randf(s) : sc_randf(s);
        b->vx = sc_rands(s) * 2.0f;
        b->vy = sc_rands(s) * 2.0f;
    }
}

/* Height range of the grid projected on `up`. */
static void lava_extent(const scene_t *s, float ux, float uy, float *hmin, float *hmax) {
    float c[4] = { 0.0f, ux * (float)s->gw, uy * (float)s->gh, ux * (float)s->gw + uy * (float)s->gh };
    *hmin = *hmax = c[0];
    for (int i = 1; i < 4; i++) {
        if (c[i] < *hmin) *hmin = c[i];
        if (c[i] > *hmax) *hmax = c[i];
    }
}

void sc_lava_step(scene_t *s, float dt, float kick) {
    sc_lava_t *lv = (sc_lava_t *)s->extra;
    float em = sc_sqrtf(s->ex * s->ex + s->ey * s->ey);
    float ux = em > 1e-3f ? -s->ex / em : 0.0f, uy = em > 1e-3f ? -s->ey / em : -1.0f;
    float gs = sc_clampf(em, 0.3f, 1.5f);
    float hmin, hmax;
    lava_extent(s, ux, uy, &hmin, &hmax);
    float H = hmax - hmin;
    float gw = (float)s->gw, gh = (float)s->gh;
    for (int i = 0; i < lv->n; i++) {
        sc_blob_t *b = &lv->b[i];
        float h = b->x * ux + b->y * uy - hmin;
        if (h < b->r * 1.3f) b->t += dt * (0.25f + 0.25f * sc_randf(s));
        else b->t -= dt * 0.09f;
        if (h > H - b->r * 1.6f) b->t -= dt * 0.35f;
        if (kick > 0.0f) {
            b->vx += s->hp[0] * 18.0f * kick + sc_rands(s) * 4.0f * kick;
            b->vy += s->hp[1] * 18.0f * kick + sc_rands(s) * 4.0f * kick;
            b->t += 0.12f;
        }
        b->t = sc_clampf(b->t, 0.0f, 1.0f);
        float buoy = (b->t - 0.45f) * 26.0f * gs;
        b->vx += (ux * buoy + sc_rands(s) * 3.0f + s->hp[0] * 20.0f) * dt;
        b->vy += (uy * buoy + sc_rands(s) * 3.0f + s->hp[1] * 20.0f) * dt;
        float drag = 1.0f - 0.9f * dt;
        b->vx *= drag;
        b->vy *= drag;
        b->vx = sc_clampf(b->vx, -30.0f, 30.0f);
        b->vy = sc_clampf(b->vy, -30.0f, 30.0f);
        b->x += b->vx * dt;
        b->y += b->vy * dt;
        float m = b->r * 0.4f;
        if (b->x < m) { b->x = m; b->vx = sc_absf(b->vx) * 0.3f; }
        if (b->x > gw - m) { b->x = gw - m; b->vx = -sc_absf(b->vx) * 0.3f; }
        if (b->y < m) { b->y = m; b->vy = sc_absf(b->vy) * 0.3f; }
        if (b->y > gh - m) { b->y = gh - m; b->vy = -sc_absf(b->vy) * 0.3f; }
    }
    /* mild repulsion so the blobs merge visually but do not collapse into one lump */
    for (int i = 0; i < lv->n; i++)
        for (int j = i + 1; j < lv->n; j++) {
            sc_blob_t *a = &lv->b[i], *b = &lv->b[j];
            float dx = b->x - a->x, dy = b->y - a->y, d2 = dx * dx + dy * dy;
            float rr = 0.8f * (a->r + b->r);
            if (d2 < rr * rr && d2 > 1e-4f) {
                float d = sc_sqrtf(d2), push = (rr - d) / d * 1.5f * dt;
                a->vx -= dx * push; a->vy -= dy * push;
                b->vx += dx * push; b->vy += dy * push;
            }
        }
}

void sc_lava_prepare(scene_t *s) {
    sc_lava_t *lv = (sc_lava_t *)s->extra;
    int gw = s->gw, gh = s->gh;
    uint16_t *fld = lv->field;
    float em = sc_sqrtf(s->ex * s->ex + s->ey * s->ey);
    float ux = em > 1e-3f ? -s->ex / em : 0.0f, uy = em > 1e-3f ? -s->ey / em : -1.0f;
    float hmin, hmax;
    lava_extent(s, ux, uy, &hmin, &hmax);
    /* pool: P0 - Pk*h in fixed point (Q8 heights), iso (T) at ~2.5 cells, zero at ~6 */
    const int32_t P0 = 900, PK = 110;   /* field units, per cell: surface ~5.9 cells, glow to ~8 */
    int32_t ux8 = (int32_t)(ux * 256.0f), uy8 = (int32_t)(uy * 256.0f);
    int32_t h0 = (int32_t)((0.5f * ux + 0.5f * uy - hmin) * 256.0f);
    for (int y = 0; y < gh; y++) {
        int32_t h = h0 + y * uy8;
        uint16_t *row = fld + (size_t)y * gw;
        for (int x = 0; x < gw; x++, h += ux8) {
            int32_t v = P0 - ((h * PK) >> 8);
            row[x] = (uint16_t)(v > 0 ? v : 0);
        }
    }
    for (int i = 0; i < lv->n; i++) {
        const sc_blob_t *b = &lv->b[i];
        float R = b->r * 1.42f, inv = 1.0f / (R * R);
        float K = 650.0f + 650.0f * b->t;
        int x0 = sc_clampi((int)(b->x - R), 0, gw - 1), x1 = sc_clampi((int)(b->x + R) + 1, 0, gw - 1);
        int y0 = sc_clampi((int)(b->y - R), 0, gh - 1), y1 = sc_clampi((int)(b->y + R) + 1, 0, gh - 1);
        for (int y = y0; y <= y1; y++) {
            float dy = (float)y + 0.5f - b->y, dy2 = dy * dy * inv;
            if (dy2 >= 1.0f) continue;
            uint16_t *row = fld + (size_t)y * gw;
            for (int x = x0; x <= x1; x++) {
                float dx = (float)x + 0.5f - b->x;
                float q = dx * dx * inv + dy2;
                if (q >= 1.0f) continue;
                float w = (1.0f - q) * (1.0f - q);
                int32_t v = row[x] + (int32_t)(K * w);
                row[x] = (uint16_t)(v > 65535 ? 65535 : v);
            }
        }
    }
    size_t total = (size_t)gw * gh;
    uint8_t *sh = s->shade;
    for (size_t i = 0; i < total; i++) {
        uint32_t v = fld[i];
        uint32_t o;
        if (v < LAVA_T) o = (v * 99u) >> 8;                       /* 0 .. 98 glow */
        else {
            o = 100u + (((v - LAVA_T) * 155u) >> 10);             /* crust at the edge, hot core */
            if (o > 255u) o = 255u;
        }
        sh[i] = (uint8_t)o;
    }
}
