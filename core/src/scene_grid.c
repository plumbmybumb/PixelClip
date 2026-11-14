/* scene_grid.c — cellular-automaton scenes: sand, water, snow.
 *
 * Cell byte layout (one byte per cell, 0 = empty):
 *   sand / snow : bit7 = step parity, bits0-6 = grain variation 1..127
 *   water       : bit7 = step parity, bit6 = lateral flow direction, bits0-5 = variation 1..63
 * A cell is processed once per CA step: cells whose parity bit already equals the step's parity
 * were moved into place (or visited) during this step and are skipped.
 *
 * Gravity in any direction: the angle is quantised to the 8 compass directions with dithering
 * (the primary move is k0 or k0+1, chosen per cell with the fractional angle as probability), the
 * loop runs downstream-first along the dominant axis, and fallback (diagonal) moves are accepted
 * with a probability that falls from 1 at 45° off gravity to 0 at 67.5° (angle of repose ≈ 45°
 * at any tilt). Water additionally spreads along the two "level" directions, never uphill.
 */
#include "scene_internal.h"

#define SAND_RATE 65.0f      /* CA steps per second at 1 g in-plane */
#define WATER_RATE 50.0f
#define SNOW_RATE 30.0f
#define MAX_SUBSTEPS 4
#define WATER_SPREAD 10
#define WATER_FALL 3

/* ------------------------------------------------------------------------------------------ */
/* Shared                                                                                      */

/* Loop geometry of one CA pass: the outer loop walks the dominant axis, the inner loop the other
 * one; both directions come from sc_flow_make. Cells are visited through a pointer that advances by
 * `pin` per inner step, with (x, y) tracked incrementally for the bounds checks. */
typedef struct {
    int x0, y0;              /* first cell */
    int ox, oy;              /* outer step */
    int ix, iy;              /* inner step */
    int on, in;              /* counts */
    ptrdiff_t pin;           /* pointer step of the inner loop */
} ca_iter_t;

static void ca_iter(const scene_t *s, const sc_flow_t *f, ca_iter_t *it) {
    int gw = s->gw, gh = s->gh;
    int xs = f->desc_x ? -1 : 1, ys = f->desc_y ? -1 : 1;
    it->x0 = f->desc_x ? gw - 1 : 0;
    it->y0 = f->desc_y ? gh - 1 : 0;
    if (f->outer_y) { it->ox = 0; it->oy = ys; it->ix = xs; it->iy = 0; it->on = gh; it->in = gw; }
    else { it->ox = xs; it->oy = 0; it->ix = 0; it->iy = ys; it->on = gw; it->in = gh; }
    it->pin = (ptrdiff_t)it->iy * gw + it->ix;
}

/* xorshift32 on a local copy (the compiler cannot keep s->rng in a register across cell stores) */
static inline uint32_t xs32(uint32_t *r) {
    uint32_t x = *r;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return *r = x;
}

static inline bool cell_free(const uint8_t *cells, int gw, int gh, int x, int y) {
    return (unsigned)x < (unsigned)gw && (unsigned)y < (unsigned)gh && !cells[(size_t)y * gw + x];
}

/* Number of CA sub-steps for this frame given rate and in-plane gravity. */
static int substeps(scene_t *s, float dt, float rate) {
    float m = sc_sqrtf(s->ex * s->ex + s->ey * s->ey);
    s->acc += dt * rate * sc_clampf(m, 0.15f, 1.6f);
    int n = (int)s->acc;
    if (n > MAX_SUBSTEPS) { n = MAX_SUBSTEPS; s->acc = 0.0f; }
    s->acc -= (float)n;
    return n;
}

/* Stamp the new parity into cells created outside the CA pass so they are processed next step. */
static inline uint8_t fresh(const scene_t *s, uint8_t v) { return (uint8_t)((v & 0x7F) | s->parity); }

/* Pick a random cell and walk to the material surface along (ux, uy) = "up": up through material
 * or down through air. True if (x, y) is a filled cell whose up-neighbour is free. */
static bool random_surface(scene_t *s, int ux, int uy, int *px, int *py) {
    int gw = s->gw, gh = s->gh;
    const uint8_t *cells = s->cells;
    int x = (int)sc_randn(s, (uint32_t)gw), y = (int)sc_randn(s, (uint32_t)gh);
    int steps = gw + gh;
    if (cells[(size_t)y * gw + x]) {
        while (steps-- > 0 && (unsigned)(x + ux) < (unsigned)gw && (unsigned)(y + uy) < (unsigned)gh &&
               cells[(size_t)(y + uy) * gw + x + ux]) { x += ux; y += uy; }
    } else {
        while (steps-- > 0 && (unsigned)(x - ux) < (unsigned)gw && (unsigned)(y - uy) < (unsigned)gh &&
               !cells[(size_t)y * gw + x]) { x -= ux; y -= uy; }
    }
    if (!cells[(size_t)y * gw + x] || !cell_free(cells, gw, gh, x + ux, y + uy)) return false;
    *px = x;
    *py = y;
    return true;
}

void sc_grid_fling(scene_t *s, int n, float strength) {
    int gw = s->gw, gh = s->gh;
    uint8_t *cells = s->cells;
    float ex = s->ex, ey = s->ey;
    float em = sc_sqrtf(ex * ex + ey * ey);
    if (em < 1e-3f) { ex = 0; ey = 1; em = 1; }
    ex /= em; ey /= em;
    float hx = s->hp[0], hy = s->hp[1];
    float hm = sc_sqrtf(hx * hx + hy * hy);
    float dx = -ex, dy = -ey;                    /* default: straight up, against gravity */
    if (hm > 0.05f) {                            /* bias along the knock, but never into the pile */
        dx += 0.8f * hx / hm;
        dy += 0.8f * hy / hm;
        if (dx * ex + dy * ey > -0.2f) { dx -= ex; dy -= ey; }
        float dm = sc_sqrtf(dx * dx + dy * dy);
        if (dm < 1e-3f) { dx = -ex; dy = -ey; dm = 1; }
        dx /= dm; dy /= dm;
    }
    int ux = (int)(-ex * 1.5f), uy = (int)(-ey * 1.5f);   /* rough "above" neighbour */
    if (!ux && !uy) uy = -1;
    int moved = 0;
    for (int tries = 0; tries < n * 3 && moved < n; tries++) {
        int x, y;
        if (!random_surface(s, ux, uy, &x, &y)) continue;
        size_t idx = (size_t)y * gw + x;
        uint8_t c = cells[idx];
        float ja = sc_rands(s) * 0.6f;
        float ca = sc_cosf(ja), sa = sc_sinf(ja);
        float vx = dx * ca - dy * sa, vy = dx * sa + dy * ca;
        int dist = 2 + (int)sc_randn(s, (uint32_t)(3 + strength * 14.0f));
        float fx = (float)x + 0.5f, fy = (float)y + 0.5f;
        size_t best = idx;
        for (int k = 0; k < dist; k++) {
            fx += vx; fy += vy;
            if (fx < 0 || fy < 0) break;
            int cx = (int)fx, cy = (int)fy;
            if (!cell_free(cells, gw, gh, cx, cy)) break;
            best = (size_t)cy * gw + cx;
        }
        if (best != idx) {
            cells[best] = c;
            cells[idx] = 0;
            moved++;
        }
    }
}

/* Fill `n` cells from the bottom edge up, in random order inside each row. */
static void fill_bottom(scene_t *s, int n, uint8_t (*var)(scene_t *)) {
    int gw = s->gw, gh = s->gh;
    for (int y = gh - 1; y >= 0 && n > 0; y--) {
        if (n >= gw) {
            for (int x = 0; x < gw; x++) s->cells[(size_t)y * gw + x] = var(s);
            n -= gw;
        } else {
            while (n > 0) {
                int x = (int)sc_randn(s, (uint32_t)gw);
                uint8_t *c = &s->cells[(size_t)y * gw + x];
                if (!*c) { *c = var(s); n--; }
            }
        }
    }
}

static uint8_t sand_var(scene_t *s) { return (uint8_t)(1 + sc_randn(s, 127)); }
static uint8_t water_var(scene_t *s) { return (uint8_t)(1 + sc_randn(s, 63) + ((sc_rand(s) >> 31) << 6)); }

/* Identity ramp for the scenes whose shade is already a palette position. */
static void lut_ramp(scene_t *s) { sc_lut_build(s, NULL); }

/* ------------------------------------------------------------------------------------------ */
/* Sand                                                                                        */

/* Initial dune: a base layer plus a mound whose slopes stay under 45°, filled column by column. */
static void fill_dune(scene_t *s, int n, uint8_t (*var)(scene_t *)) {
    int gw = s->gw, gh = s->gh;
    if (n > gw * gh) n = gw * gh;
    int peak = (int)(sc_randf(s) * 0.4f * (float)gw + 0.3f * (float)gw);
    /* height(x) = base + max(0, top - |x - peak|), choose base/top to match n */
    int best_base = 0, best_top = 0;
    for (int top = gh; top >= 0; top--) {
        int base = 0;
        long cnt = 0;
        for (int x = 0; x < gw; x++) { int d = x - peak; d = d < 0 ? -d : d; cnt += top - d > 0 ? top - d : 0; }
        if (cnt > n) continue;
        base = (int)((n - cnt) / gw);
        if (base + top > gh) continue;
        best_base = base; best_top = top;
        break;
    }
    int placed = 0;
    for (int x = 0; x < gw; x++) {
        int d = x - peak; d = d < 0 ? -d : d;
        int hgt = best_base + (best_top - d > 0 ? best_top - d : 0);
        if (hgt > gh) hgt = gh;
        for (int k = 0; k < hgt && placed < n; k++) { s->cells[(size_t)(gh - 1 - k) * gw + x] = var(s); placed++; }
    }
    /* remainder: one partial layer on top */
    for (int tries = 0; placed < n && tries < 64 * gw * gh; tries++) {
        int x = (int)sc_randn(s, (uint32_t)gw);
        for (int y = gh - 1; y >= 0; y--) {
            uint8_t *c = &s->cells[(size_t)y * gw + x];
            if (!*c) { *c = var(s); placed++; break; }
        }
    }
}

void sc_sand_init(scene_t *s) {
    lut_ramp(s);
    int n = (int)((int64_t)s->gw * s->gh * s->pv[P_AMOUNT] / 200);
    fill_dune(s, n, sand_var);
    s->mass = n;
}

/* Can a grain that just rolled to (x,y) keep falling (a free cell within the gravity cone)? */
static inline bool keeps_falling(const uint8_t *cells, int gw, int gh, int x, int y, uint8_t cone) {
    for (int k = 0; k < 8; k++)
        if ((cone >> k) & 1u && cell_free(cells, gw, gh, x + sc_dx[k], y + sc_dy[k])) return true;
    return false;
}

/* Granular step. `fall` (0..65535): probability that a cell tries to move at all this step (snow
 * falls slower than sand); `slide`: probability of taking a free diagonal inside the gravity cone;
 * `hop`: probability of rolling over a neighbour (50°..88° off gravity) when the grain would keep
 * falling from there — this is what makes a slab avalanche once tilted past ~45°; `maxfall`: cells
 * per step in free fall. */
static void granular_pass(scene_t *s, const sc_flow_t *f, uint32_t fall, uint32_t slide, uint32_t hop, int maxfall) {
    uint8_t *cells = s->cells;
    const int gw = s->gw, gh = s->gh;
    s->parity ^= 0x80;
    const uint8_t cur = s->parity;
    const uint8_t cone = f->cone_mask, hops = f->hop_mask;
    ptrdiff_t off[8];
    for (int k = 0; k < 8; k++) off[k] = (ptrdiff_t)sc_dy[k] * gw + sc_dx[k];
    uint32_t rng = s->rng;
    ca_iter_t it;
    ca_iter(s, f, &it);
    for (int oi = 0; oi < it.on; oi++) {
        int x = it.x0 + oi * it.ox, y = it.y0 + oi * it.oy;
        uint8_t *pc = cells + (ptrdiff_t)y * gw + x;
        for (int ii = 0; ii < it.in; ii++, x += it.ix, y += it.iy, pc += it.pin) {
            uint8_t c = *pc;
            if (!c || (c & 0x80) == cur) continue;
            uint8_t v = (uint8_t)((c & 0x7F) | cur);
            uint32_t r = xs32(&rng);
            if ((r >> 16) < fall) {
                int p = (r & 0xFFFFu) < f->p_next ? (f->k0 + 1) & 7 : f->k0;
                int dx = sc_dx[p], dy = sc_dy[p];
                int nx = x + dx, ny = y + dy;
                uint8_t *pn = pc + off[p];
                if ((unsigned)nx < (unsigned)gw && (unsigned)ny < (unsigned)gh && !*pn) {
                    for (int k = 1; k < maxfall && cell_free(cells, gw, gh, nx + dx, ny + dy); k++) { nx += dx; ny += dy; pn += off[p]; }
                    *pn = v;
                    *pc = 0;
                    continue;
                }
                uint32_t r2 = xs32(&rng);
                int side = (r2 & 1u) ? 1 : 7;
                uint8_t *dst = NULL;
                if (((r2 >> 1) & 0xFFFFu) < slide) {
                    for (int t = 0; t < 2 && !dst; t++) {
                        int q = (p + (t ? 8 - side : side)) & 7;
                        if (!((cone >> q) & 1u)) continue;
                        int qx = sc_dx[q], qy = sc_dy[q];
                        nx = x + qx; ny = y + qy;
                        if (cell_free(cells, gw, gh, nx, ny)) {   /* keep sliding down a free slope */
                            dst = pc + off[q];
                            for (int k = 1; k < maxfall && cell_free(cells, gw, gh, nx + qx, ny + qy); k++) { nx += qx; ny += qy; dst += off[q]; }
                        }
                    }
                }
                if (!dst && hops && (r2 >> 17) < hop) {
                    static const int8_t order[4] = { 1, 2, -1, -2 };
                    for (int t = 0; t < 4 && !dst; t++) {
                        int q = (p + 8 + (side == 1 ? order[t] : -order[t])) & 7;
                        if (!((hops >> q) & 1u)) continue;
                        nx = x + sc_dx[q]; ny = y + sc_dy[q];
                        if (cell_free(cells, gw, gh, nx, ny) && keeps_falling(cells, gw, gh, nx, ny, cone)) dst = pc + off[q];
                    }
                }
                if (dst) {
                    *dst = v;
                    *pc = 0;
                    continue;
                }
            }
            *pc = v;
        }
    }
    s->rng = rng;
    s->steps++;
}

void sc_sand_step(scene_t *s, float dt, float kick) {
    if (kick > 0.0f) sc_grid_fling(s, (int)(s->mass * sc_minf(0.25f, kick * 0.08f)) + 4, kick);
    int n = substeps(s, dt, SAND_RATE);
    for (int i = 0; i < n; i++) {
        sc_flow_t f;
        sc_flow_make(s, &f, true);
        granular_pass(s, &f, 65536u, 65536u, 52000u >> 1, 2);
    }
}

/* Upstream neighbour offsets for the "surface" test: the nearest compass direction against gravity. */
static void upstream(const scene_t *s, int *ux, int *uy) {
    float a8 = sc_atan2f(s->ey, s->ex) * (4.0f / SC_PI);
    if (a8 < 0) a8 += 8.0f;
    int k = ((int)(a8 + 0.5f)) & 7;
    *ux = -sc_dx[k];
    *uy = -sc_dy[k];
}

void sc_sand_prepare(scene_t *s) {
    int gw = s->gw, gh = s->gh, ux, uy;
    upstream(s, &ux, &uy);
    const uint8_t *cells = s->cells;
    uint8_t *sh = s->shade;
    for (int y = 0; y < gh; y++) {
        int yu = y + uy;
        bool yu_in = (unsigned)yu < (unsigned)gh;
        const uint8_t *row = cells + (size_t)y * gw;
        const uint8_t *urow = cells + (size_t)(yu_in ? yu : y) * gw;
        uint8_t *srow = sh + (size_t)y * gw;
        for (int x = 0; x < gw; x++) {
            uint8_t c = row[x];
            if (!c) { srow[x] = 0; continue; }
            unsigned v = 140u + (((unsigned)(c & 0x7F) * 85u) >> 7);
            int xu = x + ux;
            bool top = !yu_in || (unsigned)xu >= (unsigned)gw || !urow[xu];
            if (top) v += 28u;
            srow[x] = (uint8_t)(v > 255u ? 255u : v);
        }
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Water                                                                                       */

void sc_water_init(scene_t *s) {
    lut_ramp(s);
    int n = (int)((int64_t)s->gw * s->gh * s->pv[P_AMOUNT] / 200);
    fill_bottom(s, n, water_var);
    s->mass = n;
}

static void water_pass(scene_t *s, const sc_flow_t *f) {
    uint8_t *cells = s->cells;
    const int gw = s->gw, gh = s->gh;
    s->parity ^= 0x80;
    const uint8_t cur = s->parity;
    const int kd = f->knear;
    ptrdiff_t off[8];
    for (int k = 0; k < 8; k++) off[k] = (ptrdiff_t)sc_dy[k] * gw + sc_dx[k];
    uint32_t rng = s->rng;
    ca_iter_t it;
    ca_iter(s, f, &it);
    for (int oi = 0; oi < it.on; oi++) {
        int x = it.x0 + oi * it.ox, y = it.y0 + oi * it.oy;
        uint8_t *pc = cells + (ptrdiff_t)y * gw + x;
        for (int ii = 0; ii < it.in; ii++, x += it.ix, y += it.iy, pc += it.pin) {
            uint8_t c = *pc;
            if (!c || (c & 0x80) == cur) continue;
            uint8_t v = (uint8_t)((c & 0x7F) | cur);
            uint32_t r = xs32(&rng);
            int p = (r & 0xFFFFu) < f->p_next ? (f->k0 + 1) & 7 : f->k0;
            int dx = sc_dx[p], dy = sc_dy[p];
            int nx = x + dx, ny = y + dy;
            if ((unsigned)nx < (unsigned)gw && (unsigned)ny < (unsigned)gh && !pc[off[p]]) {
                uint8_t *pn = pc + off[p];
                for (int k = 1; k < WATER_FALL && cell_free(cells, gw, gh, nx + dx, ny + dy); k++) { nx += dx; ny += dy; pn += off[p]; }
                *pn = v;
                *pc = 0;
                continue;
            }
            int side = (r & 0x10000u) ? 1 : 7;
            int q1 = (p + side) & 7, q2 = (p + 8 - side) & 7;
            if (f->accept[q1] && cell_free(cells, gw, gh, x + sc_dx[q1], y + sc_dy[q1])) {
                pc[off[q1]] = v;
                *pc = 0;
                continue;
            }
            if (f->accept[q2] && cell_free(cells, gw, gh, x + sc_dx[q2], y + sc_dy[q2])) {
                pc[off[q2]] = v;
                *pc = 0;
                continue;
            }
            /* lateral spread along the level directions, in the cell's remembered direction */
            uint8_t *dst = NULL;
            for (int attempt = 0; attempt < 2 && !dst; attempt++) {
                int lat = (v & 0x40) ? f->lat_a : f->lat_b;
                int lx = sc_dx[lat], ly = sc_dy[lat];
                int cx = x, cy = y;
                for (int k = 0; k < WATER_SPREAD; k++) {
                    if (!cell_free(cells, gw, gh, cx + lx, cy + ly)) break;
                    cx += lx; cy += ly;
                    dst = cells + (ptrdiff_t)cy * gw + cx;
                    if (cell_free(cells, gw, gh, cx + sc_dx[kd], cy + sc_dy[kd])) break;  /* found a drop */
                }
                if (!dst) v ^= 0x40;   /* blocked: turn around */
            }
            if (dst) {
                *dst = v;
                *pc = 0;
            } else {
                *pc = v;
            }
        }
    }
    s->rng = rng;
    s->steps++;
}

/* Communicating-vessels leveling. A CA moves water only at its surface, which makes bulk flow
 * (sloshing to the other side after a tilt) take seconds. Since the inside of the water is uniform,
 * moving a cell from the highest surface point (lowest potential along gravity) straight to the
 * lowest free resting spot is visually the same as flow through the body. Up to `budget` such
 * transfers per frame, only while the level difference exceeds WL_THRESH cells (calm surface).
 * Candidates are bucketed by potential (counting sort), so this is two linear passes. */
#define WL_BUCKETS 1024
#define WL_MAX 192
#define WL_RATE 2600.0f          /* max cells per second at 1 g */
#define WL_THRESH_Q8 (3 * 256)   /* level difference (cells, Q8) below which nothing is moved */

typedef struct {
    uint16_t hs[WL_BUCKETS], hd[WL_BUCKETS];
    uint32_t src[WL_MAX], dst[WL_MAX];
    float flow_acc;
} sc_water_t;

size_t sc_water_extra(int gw, int gh, const int32_t *pv) {
    (void)gw; (void)gh; (void)pv;
    return sizeof(sc_water_t);
}

static void water_level(scene_t *s, int budget) {
    sc_water_t *wt = (sc_water_t *)s->extra;
    if (budget > WL_MAX) budget = WL_MAX;
    if (budget <= 0) return;
    int gw = s->gw, gh = s->gh;
    uint8_t *cells = s->cells;
    float em = sc_sqrtf(s->ex * s->ex + s->ey * s->ey);
    if (em < 1e-3f) return;
    int32_t ex8 = (int32_t)(s->ex / em * 256.0f), ey8 = (int32_t)(s->ey / em * 256.0f);
    float a8 = sc_atan2f(s->ey, s->ex) * (4.0f / SC_PI);
    if (a8 < 0) a8 += 8.0f;
    int kd = ((int)(a8 + 0.5f)) & 7, dx = sc_dx[kd], dy = sc_dy[kd];
    int32_t pmin = (ex8 < 0 ? ex8 * (gw - 1) : 0) + (ey8 < 0 ? ey8 * (gh - 1) : 0);
    int32_t pmax = (ex8 > 0 ? ex8 * (gw - 1) : 0) + (ey8 > 0 ? ey8 * (gh - 1) : 0);
    int sh = 7;
    while (((pmax - pmin) >> sh) >= WL_BUCKETS) sh++;
    int nb = ((pmax - pmin) >> sh) + 1;
    memset(wt->hs, 0, sizeof wt->hs);
    memset(wt->hd, 0, sizeof wt->hd);
    /* pass 1: histogram of surface cells (water below air) and resting holes (air on water/wall) */
    for (int y = 0; y < gh; y++) {
        int32_t pr = y * ey8 - pmin;
        bool up_in = (unsigned)(y - dy) < (unsigned)gh, dn_in = (unsigned)(y + dy) < (unsigned)gh;
        for (int x = 0; x < gw; x++) {
            size_t idx = (size_t)y * gw + x;
            int b = (pr + x * ex8) >> sh;
            if (cells[idx]) {
                int ux = x - dx;
                if (up_in && (unsigned)ux < (unsigned)gw && !cells[idx - (ptrdiff_t)dy * gw - dx]) wt->hs[b]++;
            } else {
                int nx = x + dx;
                if (!dn_in || (unsigned)nx >= (unsigned)gw || cells[idx + (ptrdiff_t)dy * gw + dx]) wt->hd[b]++;
            }
        }
    }
    /* turn the extreme ends of the histograms into counting-sort offsets */
    int thr_s = -1, thr_d = nb, cum = 0;
    for (int b = 0; b < nb; b++) {
        int c = wt->hs[b];
        wt->hs[b] = (uint16_t)cum;
        cum += c;
        thr_s = b;
        if (cum >= budget) break;
    }
    int ns = cum < budget ? cum : budget;
    cum = 0;
    for (int b = nb - 1; b >= 0; b--) {
        int c = wt->hd[b];
        wt->hd[b] = (uint16_t)cum;
        cum += c;
        thr_d = b;
        if (cum >= budget) break;
    }
    int nd = cum < budget ? cum : budget;
    if (!ns || !nd || thr_s < 0) return;
    /* pass 2: collect, sorted by bucket (sources ascending, holes descending potential) */
    for (int y = 0; y < gh; y++) {
        int32_t pr = y * ey8 - pmin;
        bool up_in = (unsigned)(y - dy) < (unsigned)gh, dn_in = (unsigned)(y + dy) < (unsigned)gh;
        for (int x = 0; x < gw; x++) {
            int b = (pr + x * ex8) >> sh;
            if (b > thr_s && b < thr_d) continue;
            size_t idx = (size_t)y * gw + x;
            if (cells[idx]) {
                if (b > thr_s) continue;
                int ux = x - dx;
                if (up_in && (unsigned)ux < (unsigned)gw && !cells[idx - (ptrdiff_t)dy * gw - dx]) {
                    int pos = wt->hs[b]++;
                    if (pos < budget) wt->src[pos] = (uint32_t)idx;
                }
            } else {
                if (b < thr_d) continue;
                int nx = x + dx;
                if (!dn_in || (unsigned)nx >= (unsigned)gw || cells[idx + (ptrdiff_t)dy * gw + dx]) {
                    int pos = wt->hd[b]++;
                    if (pos < budget) wt->dst[pos] = (uint32_t)idx;
                }
            }
        }
    }
    int n = ns < nd ? ns : nd;
    for (int i = 0; i < n; i++) {
        uint32_t si = wt->src[i], di = wt->dst[i];
        int32_t ps = (int32_t)(si % (uint32_t)gw) * ex8 + (int32_t)(si / (uint32_t)gw) * ey8;
        int32_t pd = (int32_t)(di % (uint32_t)gw) * ex8 + (int32_t)(di / (uint32_t)gw) * ey8;
        if (pd - ps <= WL_THRESH_Q8) break;
        if (!cells[si] || cells[di]) continue;
        cells[di] = cells[si];
        cells[si] = 0;
    }
}

void sc_water_step(scene_t *s, float dt, float kick) {
    sc_water_t *wt = (sc_water_t *)s->extra;
    if (kick > 0.0f) sc_grid_fling(s, (int)(s->mass * sc_minf(0.3f, kick * 0.1f)) + 4, kick);
    float m = sc_sqrtf(s->ex * s->ex + s->ey * s->ey);
    wt->flow_acc += dt * WL_RATE * sc_clampf(m, 0.2f, 1.5f);
    int budget = (int)wt->flow_acc;
    wt->flow_acc -= (float)budget;
    if (budget > WL_MAX) budget = WL_MAX;
    water_level(s, budget);
    int n = substeps(s, dt, WATER_RATE);
    for (int i = 0; i < n; i++) {
        sc_flow_t f;
        sc_flow_make(s, &f, true);
        water_pass(s, &f);
    }
}

static inline uint32_t hash32(uint32_t x) {
    x ^= x >> 16; x *= 0x7FEB352Du; x ^= x >> 15; x *= 0x846CA68Bu; x ^= x >> 16;
    return x;
}

void sc_water_prepare(scene_t *s) {
    int gw = s->gw, gh = s->gh, ux, uy;
    upstream(s, &ux, &uy);
    const uint8_t *cells = s->cells;
    uint8_t *sh = s->shade;
    /* pass 1: depth below the surface along gravity (upstream-first order), 255 = empty */
    int ydesc = uy > 0, xdesc = ux > 0;   /* upstream neighbour must already be computed */
    bool rows_outer = uy != 0;
    int on = rows_outer ? gh : gw, in = rows_outer ? gw : gh;
    for (int oi = 0; oi < on; oi++) {
        for (int ii = 0; ii < in; ii++) {
            int x, y;
            if (rows_outer) { y = ydesc ? gh - 1 - oi : oi; x = xdesc ? gw - 1 - ii : ii; }
            else { x = xdesc ? gw - 1 - oi : oi; y = ydesc ? gh - 1 - ii : ii; }
            size_t idx = (size_t)y * gw + x;
            if (!cells[idx]) { sh[idx] = 255; continue; }
            int xu = x + ux, yu = y + uy;
            uint8_t d = 0;
            if ((unsigned)xu < (unsigned)gw && (unsigned)yu < (unsigned)gh) {
                uint8_t du = sh[(size_t)yu * gw + xu];
                if (du != 255) d = du < 250 ? (uint8_t)(du + 1) : 250;
            }
            sh[idx] = d;
        }
    }
    /* pass 2: depth -> palette position, with sparkles near the surface */
    uint32_t tick = s->frame >> 2;
    size_t total = (size_t)gw * gh;
    for (size_t i = 0; i < total; i++) {
        uint8_t d = sh[i];
        if (d == 255) { sh[i] = 0; continue; }
        int v = d == 0 ? 225 : 196 - 6 * (int)d;
        if (v < 108) v = 108;
        v += (int)(cells[i] & 7u) - 3;   /* per-cell texture moves with the water */
        if (d <= 3 && (hash32((uint32_t)i * 2654435761u + tick * 40503u) >> 26) == 0) v = 255;
        sh[i] = (uint8_t)sc_clampi(v, 1, 255);
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Snow: free flakes (float particles with wobble) settle into a sticky granular layer.          */

typedef struct { float x, y, vx, vy, ph, sp; } sc_flake_t;
typedef struct {
    int count, cap, settle_cap;
    float spawn_acc, melt_acc;
    sc_flake_t f[];
} sc_snow_t;

static int snow_cap(int gw, int gh, const int32_t *pv) {
    int c = (int)((int64_t)gw * gh * pv[P_AMOUNT] / 2400);
    return sc_clampi(c, 16, SC_SNOW_FLAKES_MAX);
}

size_t sc_snow_extra(int gw, int gh, const int32_t *pv) {
    return sizeof(sc_snow_t) + (size_t)snow_cap(gw, gh, pv) * sizeof(sc_flake_t);
}

static void snow_spawn(scene_t *s, sc_snow_t *sn, bool anywhere) {
    if (sn->count >= sn->cap) return;
    int gw = s->gw, gh = s->gh;
    float ex = s->ex, ey = s->ey, em = sc_sqrtf(ex * ex + ey * ey);
    if (em < 1e-3f) { ex = 0; ey = 1; em = 1; }
    ex /= em; ey /= em;
    float x, y;
    if (anywhere) {
        x = sc_randf(s) * (float)gw;
        y = sc_randf(s) * (float)gh;
    } else {
        /* enter through the edges facing against gravity, weighted by length × incidence */
        float wt = sc_maxf(0, ey) * gw, wb = sc_maxf(0, -ey) * gw, wl = sc_maxf(0, ex) * gh, wr = sc_maxf(0, -ex) * gh;
        float r = sc_randf(s) * (wt + wb + wl + wr);
        float t = sc_randf(s);
        if ((r -= wt) < 0) { x = t * gw; y = 0.01f; }
        else if ((r -= wb) < 0) { x = t * gw; y = (float)gh - 0.01f; }
        else if ((r -= wl) < 0) { x = 0.01f; y = t * gh; }
        else { x = (float)gw - 0.01f; y = t * gh; }
    }
    int cx = sc_clampi((int)x, 0, gw - 1), cy = sc_clampi((int)y, 0, gh - 1);
    if (s->cells[(size_t)cy * gw + cx]) return;
    sc_flake_t *f = &sn->f[sn->count++];
    f->x = x; f->y = y;
    f->sp = 0.6f + 0.8f * sc_randf(s);
    f->vx = ex * 3.0f * f->sp; f->vy = ey * 3.0f * f->sp;
    f->ph = sc_randf(s) * SC_TWO_PI;
}

static uint8_t snow_var(scene_t *s) { return (uint8_t)(1 + sc_randn(s, 127)); }

/* Soft rolling drift: height(x) = base + two random cosines, scaled to hold `n` cells. */
static void fill_drift(scene_t *s, int n) {
    int gw = s->gw, gh = s->gh;
    float p1 = sc_randf(s) * SC_TWO_PI, p2 = sc_randf(s) * SC_TWO_PI;
    float f1 = SC_TWO_PI * (0.8f + 0.6f * sc_randf(s)) / (float)gw, f2 = SC_TWO_PI * (2.0f + 1.5f * sc_randf(s)) / (float)gw;
    float sum = 0.0f;
    for (int x = 0; x < gw; x++) sum += 1.0f + 0.45f * sc_cosf(f1 * (float)x + p1) + 0.2f * sc_cosf(f2 * (float)x + p2);
    float k = sum > 0.0f ? (float)n / sum : 0.0f;
    int placed = 0;
    for (int x = 0; x < gw && placed < n; x++) {
        int hgt = (int)(k * (1.0f + 0.45f * sc_cosf(f1 * (float)x + p1) + 0.2f * sc_cosf(f2 * (float)x + p2)) + 0.5f);
        hgt = sc_clampi(hgt, 0, gh);
        for (int y = 0; y < hgt && placed < n; y++, placed++) s->cells[(size_t)(gh - 1 - y) * gw + x] = snow_var(s);
    }
    s->mass = placed;
}

void sc_snow_init(scene_t *s) {
    lut_ramp(s);
    sc_snow_t *sn = (sc_snow_t *)s->extra;
    sn->cap = snow_cap(s->gw, s->gh, s->pv);
    sn->settle_cap = (int)((int64_t)s->gw * s->gh * s->pv[P_AMOUNT] * 30 / 10000);
    fill_drift(s, sn->settle_cap * 3 / 5);
    for (int i = 0; i < sn->cap * 2 / 3; i++) snow_spawn(s, sn, true);
}

static void snow_melt(scene_t *s, int n) {
    int gw = s->gw, ux, uy;
    upstream(s, &ux, &uy);
    for (int tries = 0; tries < n * 4 && n > 0; tries++) {
        int x, y;
        if (!random_surface(s, ux, uy, &x, &y)) continue;
        s->cells[(size_t)y * gw + x] = 0;
        s->mass--;
        n--;
    }
}

/* Shake: knock surface snow back into the air as flakes. */
static void snow_puff(scene_t *s, sc_snow_t *sn, int n, float strength) {
    int gw = s->gw, ux, uy;
    upstream(s, &ux, &uy);
    for (int tries = 0; tries < n * 4 && n > 0 && sn->count < sn->cap; tries++) {
        int x, y;
        if (!random_surface(s, ux, uy, &x, &y)) continue;
        s->cells[(size_t)y * gw + x] = 0;
        s->mass--;
        n--;
        sc_flake_t *f = &sn->f[sn->count++];
        f->x = (float)(x + ux) + 0.5f;
        f->y = (float)(y + uy) + 0.5f;
        f->sp = 0.6f + 0.8f * sc_randf(s);
        f->vx = (float)ux * (4.0f + 8.0f * strength) + s->hp[0] * 10.0f + sc_rands(s) * 4.0f;
        f->vy = (float)uy * (4.0f + 8.0f * strength) + s->hp[1] * 10.0f + sc_rands(s) * 4.0f;
        f->ph = sc_randf(s) * SC_TWO_PI;
    }
}

#define FLAKE_VMAX 14.0f   /* cells/s; with dt <= 50 ms a flake never skips a cell */

void sc_snow_step(scene_t *s, float dt, float kick) {
    sc_snow_t *sn = (sc_snow_t *)s->extra;
    int gw = s->gw, gh = s->gh;
    uint8_t *cells = s->cells;
    float ex = s->ex, ey = s->ey, em = sc_sqrtf(ex * ex + ey * ey);
    float enx = em > 1e-3f ? ex / em : 0.0f, eny = em > 1e-3f ? ey / em : 1.0f;
    float px = -eny, py = enx;
    float vt = 2.5f + 4.5f * sc_minf(em, 1.5f);
    float blend = sc_minf(1.0f, dt * 2.5f);
    if (kick > 0.0f) snow_puff(s, sn, 6 + (int)(kick * 30.0f), kick);
    for (int i = 0; i < sn->count;) {
        sc_flake_t *f = &sn->f[i];
        f->ph += dt * (1.3f + f->sp);
        float wob = sc_sinf(f->ph) * 2.2f * f->sp;
        float tx = enx * vt * f->sp + px * wob, ty = eny * vt * f->sp + py * wob;
        f->vx += (tx - f->vx) * blend + s->hp[0] * 45.0f * dt;
        f->vy += (ty - f->vy) * blend + s->hp[1] * 45.0f * dt;
        f->vx = sc_clampf(f->vx, -FLAKE_VMAX, FLAKE_VMAX);
        f->vy = sc_clampf(f->vy, -FLAKE_VMAX, FLAKE_VMAX);
        int cx = (int)f->x, cy = (int)f->y;
        float nx = f->x + f->vx * dt, ny = f->y + f->vy * dt;
        bool oob = nx < 0.0f || ny < 0.0f || nx >= (float)gw || ny >= (float)gh;
        int ncx = oob ? -1 : (int)nx, ncy = oob ? -1 : (int)ny;
        bool blocked = oob || ((ncx != cx || ncy != cy) && cells[(size_t)ncy * gw + ncx]);
        if (!blocked) {
            f->x = nx; f->y = ny;
            i++;
            continue;
        }
        if (f->vx * enx + f->vy * eny > 0.0f) {
            /* landed: becomes part of the drift (or vanishes if its own cell got buried) */
            cx = sc_clampi(cx, 0, gw - 1); cy = sc_clampi(cy, 0, gh - 1);
            size_t idx = (size_t)cy * gw + cx;
            if (!cells[idx]) { cells[idx] = fresh(s, snow_var(s)); s->mass++; }
            sn->f[i] = sn->f[--sn->count];
            continue;
        }
        /* moving sideways/up into an obstacle: bounce off softly */
        f->vx = -f->vx * 0.3f; f->vy = -f->vy * 0.3f;
        i++;
    }
    /* keep the snowfall going: spawn while the drifts are below their cap, melt above */
    float fill = sn->settle_cap > 0 ? (float)s->mass / (float)sn->settle_cap : 1.0f;
    float spawn_rate = (float)sn->cap * 0.5f * sc_clampf((1.1f - fill) * 3.0f, 0.15f, 1.0f);
    sn->spawn_acc += dt * spawn_rate;
    while (sn->spawn_acc >= 1.0f) { sn->spawn_acc -= 1.0f; snow_spawn(s, sn, false); }
    if (fill > 0.7f) {
        sn->melt_acc += dt * (float)sn->settle_cap * 0.04f * sc_minf(2.0f, (fill - 0.7f) * 4.0f);
        int m = (int)sn->melt_acc;
        sn->melt_acc -= (float)m;
        if (m) snow_melt(s, m);
    }
    int n = substeps(s, dt, SNOW_RATE);
    for (int i = 0; i < n; i++) {
        sc_flow_t fl;
        sc_flow_make(s, &fl, true);
        granular_pass(s, &fl, 65536u, 20000u, 12000u >> 1, 2);   /* sticky: slides reluctantly, but unsupported snow drops */
    }
}

void sc_snow_prepare(scene_t *s) {
    int gw = s->gw, gh = s->gh, ux, uy;
    upstream(s, &ux, &uy);
    const uint8_t *cells = s->cells;
    uint8_t *sh = s->shade;
    for (int y = 0; y < gh; y++) {
        int yu = y + uy;
        bool yu_in = (unsigned)yu < (unsigned)gh;
        const uint8_t *row = cells + (size_t)y * gw;
        const uint8_t *urow = cells + (size_t)(yu_in ? yu : y) * gw;
        uint8_t *srow = sh + (size_t)y * gw;
        for (int x = 0; x < gw; x++) {
            uint8_t c = row[x];
            if (!c) { srow[x] = 0; continue; }
            unsigned v = 165u + (((unsigned)(c & 0x7F) * 40u) >> 7);
            int xu = x + ux;
            if (!yu_in || (unsigned)xu >= (unsigned)gw || !urow[xu]) v += 45u;
            srow[x] = (uint8_t)(v > 255u ? 255u : v);
        }
    }
    sc_snow_t *sn = (sc_snow_t *)s->extra;
    for (int i = 0; i < sn->count; i++) {
        const sc_flake_t *f = &sn->f[i];
        int cx = (int)f->x, cy = (int)f->y;
        if ((unsigned)cx >= (unsigned)gw || (unsigned)cy >= (unsigned)gh) continue;
        unsigned v = 150u + (unsigned)(f->sp * 75.0f);
        uint8_t *d = &sh[(size_t)cy * gw + cx];
        if (v > *d) *d = (uint8_t)(v > 255u ? 255u : v);
    }
}
