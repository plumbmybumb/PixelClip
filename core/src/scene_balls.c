/* scene_balls.c — anti-aliased bouncing balls at full resolution.
 *
 * Physics in pixels and seconds, sub-stepped at <= 1/240 s: gravity (scaled so 1 g crosses the
 * screen height in ~0.6 s), restitution from the `bounce` parameter, resting contacts settle, ball
 * pairs collide with impulse + positional correction, shakes add a velocity kick along the knock.
 * A hard wall impact flattens the ball for one rendered frame (squash) to sell the knock.
 * Rendering clears and repaints only the union of the regions that changed.
 */
#include "scene_internal.h"

#define SUBSTEP_MAX_DT (1.0f / 240.0f)
#define G_PER_PIXEL_H 5.8f        /* px/s² per g per pixel of scene height (240 px -> 1392 px/s²) */
#define V_REST 45.0f              /* px/s: slower impacts are absorbed (no micro-bounce) */
#define V_SQUASH 260.0f           /* px/s: impacts above this squash the ball */
#define V_MAX 4000.0f
#define KICK_GAIN 2.5f            /* extra weight of the high-pass residual (knocks feel stronger) */

typedef struct {
    float x, y, vx, vy, r, inv_m;
    float sq;                     /* squash amount for the next render (0 = round) */
    float sq_t;                   /* seconds the squash stays valid (shown once, if rendered in time) */
    int8_t sq_axis;               /* 0 none, 1 horizontal wall (x squashed), 2 vertical wall */
    int8_t sq_side;               /* -1: wall at the low side, +1: high side */
    uint16_t px, px_trail[SC_TRAIL_LEN], px_hi;
    uint8_t rgb[3], rgb_hi[3];
    float tx[SC_TRAIL_LEN], ty[SC_TRAIL_LEN];
    int16_t bb[4];                /* last drawn bbox x0,y0,x1,y1 (exclusive), x0 >= x1 = none */
    uint32_t state;               /* hash of the last drawn geometry */
} sc_ball_t;

typedef struct {
    int n, trail;
    float e, G;
    sc_ball_t b[];
} sc_balls_t;

size_t sc_balls_extra(int gw, int gh, const int32_t *pv) {
    (void)gw; (void)gh;
    return sizeof(sc_balls_t) + (size_t)sc_clampi(pv[PB_COUNT], 1, SC_BALLS_MAX) * sizeof(sc_ball_t);
}

static void be_to_rgb565(uint16_t be, int *r, int *g, int *b) {
    union { uint16_t v; uint8_t b[2]; } u;
    u.v = be;
    unsigned v = ((unsigned)u.b[0] << 8) | u.b[1];
    *r = (int)(v >> 11); *g = (int)((v >> 5) & 63u); *b = (int)(v & 31u);
}
static uint16_t rgb565_to_be(int r, int g, int b) {
    unsigned v = ((unsigned)r << 11) | ((unsigned)g << 5) | (unsigned)b;
    union { uint16_t v; uint8_t b[2]; } u;
    u.b[0] = (uint8_t)(v >> 8);
    u.b[1] = (uint8_t)v;
    return u.v;
}

void sc_balls_init(scene_t *s) {
    sc_balls_t *bs = (sc_balls_t *)s->extra;
    bs->n = sc_clampi(s->pv[PB_COUNT], 1, SC_BALLS_MAX);
    bs->trail = s->pv[PB_TRAIL] != 0;
    bs->e = (float)s->pv[PB_BOUNCE] / 100.0f;
    bs->G = G_PER_PIXEL_H * (float)s->h;
    float W = (float)s->w, H = (float)s->h;
    /* radius: requested, but the balls may cover at most ~30% of the area and fit easily */
    float r = (float)s->pv[PB_SIZE];
    float rfit = sc_sqrtf(0.30f * W * H / (3.14159f * (float)bs->n));
    float rmax = sc_minf(W, H) * 0.22f;
    r = sc_minf(r, sc_minf(rfit, rmax));
    if (r < 2.0f) r = 2.0f;
    /* place on a jittered grid, top part of the screen */
    int cols = sc_clampi((int)(W / (2.4f * r)), 1, 64);
    for (int i = 0; i < bs->n; i++) {
        sc_ball_t *b = &bs->b[i];
        memset(b, 0, sizeof *b);
        b->r = r * (0.8f + 0.4f * sc_randf(s));
        if (2.0f * b->r > sc_minf(W, H)) b->r = 0.5f * sc_minf(W, H) - 0.5f;
        b->inv_m = 1.0f / (b->r * b->r);
        int cx = i % cols, cy = i / cols;
        b->x = sc_clampf((cx + 0.5f) * (W / (float)cols) + sc_rands(s) * r * 0.3f, b->r, W - b->r);
        b->y = sc_clampf(r * 1.2f + (float)cy * 2.3f * r, b->r, H - b->r);
        b->vx = sc_rands(s) * 150.0f;
        b->vy = sc_rands(s) * 80.0f;
        for (int k = 0; k < SC_TRAIL_LEN; k++) { b->tx[k] = b->x; b->ty[k] = b->y; }
        /* colour: spread over the bright half of the palette ramp */
        int pos = 150 + (int)((i * 61u + (sc_rand(s) & 15u)) % 106u);
        sc_palette_rgb(s->palette, pos, b->rgb);
        b->px = sc_rgb_be(b->rgb[0], b->rgb[1], b->rgb[2]);
        for (int c = 0; c < 3; c++) b->rgb_hi[c] = (uint8_t)(b->rgb[c] + ((255 - b->rgb[c]) * 115 >> 8));
        b->px_hi = sc_rgb_be(b->rgb_hi[0], b->rgb_hi[1], b->rgb_hi[2]);
        for (int k = 0; k < SC_TRAIL_LEN; k++) {
            int a = 40 + 26 * k;   /* oldest dimmest */
            b->px_trail[k] = sc_rgb_be((unsigned)(b->rgb[0] * a) >> 8, (unsigned)(b->rgb[1] * a) >> 8,
                                       (unsigned)(b->rgb[2] * a) >> 8);
        }
        b->bb[0] = b->bb[2] = 0;
    }
    s->mass = bs->n;
}

static void wall(sc_ball_t *b, float *pos, float *vel, float lo, float hi, float e, int axis) {
    if (*pos < lo) {
        *pos = lo;
        if (*vel < 0.0f) {
            float imp = -*vel;
            *vel = imp < V_REST ? 0.0f : imp * e;
            if (imp > V_SQUASH) {
                float q = sc_minf(0.22f, imp * (1.0f / 5000.0f));
                if (q > b->sq) { b->sq = q; b->sq_axis = (int8_t)axis; b->sq_side = -1; b->sq_t = 0.06f; }
            }
        }
    } else if (*pos > hi) {
        *pos = hi;
        if (*vel > 0.0f) {
            float imp = *vel;
            *vel = imp < V_REST ? 0.0f : -imp * e;
            if (imp > V_SQUASH) {
                float q = sc_minf(0.22f, imp * (1.0f / 5000.0f));
                if (q > b->sq) { b->sq = q; b->sq_axis = (int8_t)axis; b->sq_side = 1; b->sq_t = 0.06f; }
            }
        }
    }
}

static void keep_inside(sc_ball_t *b, float W, float H) {
    float lo = b->r, hx = W - b->r, hy = H - b->r;
    b->x = hx >= lo ? sc_clampf(b->x, lo, hx) : W * 0.5f;
    b->y = hy >= lo ? sc_clampf(b->y, lo, hy) : H * 0.5f;
}

void sc_balls_step(scene_t *s, float dt, float kick) {
    sc_balls_t *bs = (sc_balls_t *)s->extra;
    float W = (float)s->w, H = (float)s->h, e = bs->e;
    float ax = bs->G * (s->ex + KICK_GAIN * s->hp[0]);
    float ay = bs->G * (s->ey + KICK_GAIN * s->hp[1]);
    if (kick > 0.0f) {
        float hx = s->hp[0], hy = s->hp[1], hm = sc_sqrtf(hx * hx + hy * hy);
        float kx = hm > 1e-3f ? hx / hm : 0.0f, ky = hm > 1e-3f ? hy / hm : -1.0f;
        float sp = 220.0f * sc_minf(kick, 3.0f);
        for (int i = 0; i < bs->n; i++) {
            bs->b[i].vx += kx * sp * (0.7f + 0.6f * sc_randf(s)) + sc_rands(s) * sp * 0.35f;
            bs->b[i].vy += ky * sp * (0.7f + 0.6f * sc_randf(s)) + sc_rands(s) * sp * 0.35f;
        }
    }
    for (int i = 0; i < bs->n; i++) {   /* a squash nobody rendered in time is dropped */
        sc_ball_t *b = &bs->b[i];
        if (b->sq > 0.0f && (b->sq_t -= dt) <= 0.0f) { b->sq = 0.0f; b->sq_axis = 0; }
    }
    int n = (int)(dt * (1.0f / SUBSTEP_MAX_DT)) + 1;
    if (n > 16) n = 16;
    float h = dt / (float)n;
    float drag = 1.0f - 0.12f * h;
    for (int it = 0; it < n; it++) {
        for (int i = 0; i < bs->n; i++) {
            sc_ball_t *b = &bs->b[i];
            b->vx = sc_clampf((b->vx + ax * h) * drag, -V_MAX, V_MAX);
            b->vy = sc_clampf((b->vy + ay * h) * drag, -V_MAX, V_MAX);
            b->x += b->vx * h;
            b->y += b->vy * h;
        }
        /* ball-ball: positional correction by mass ratio, impulse with restitution */
        for (int i = 0; i < bs->n; i++) {
            sc_ball_t *a = &bs->b[i];
            for (int j = i + 1; j < bs->n; j++) {
                sc_ball_t *b = &bs->b[j];
                float dx = b->x - a->x, dy = b->y - a->y, rr = a->r + b->r;
                float d2 = dx * dx + dy * dy;
                if (d2 >= rr * rr) continue;
                float d = sc_sqrtf(d2);
                float nx, ny;
                if (d < 1e-4f) { nx = 1.0f; ny = 0.0f; d = 0.0f; }
                else { nx = dx / d; ny = dy / d; }
                float wsum = a->inv_m + b->inv_m;
                float pen = (rr - d) / wsum;
                a->x -= nx * pen * a->inv_m; a->y -= ny * pen * a->inv_m;
                b->x += nx * pen * b->inv_m; b->y += ny * pen * b->inv_m;
                float vn = (b->vx - a->vx) * nx + (b->vy - a->vy) * ny;
                if (vn < 0.0f) {
                    float ee = -vn < V_REST ? 0.0f : e;
                    float j_imp = -(1.0f + ee) * vn / wsum;
                    a->vx -= j_imp * a->inv_m * nx; a->vy -= j_imp * a->inv_m * ny;
                    b->vx += j_imp * b->inv_m * nx; b->vy += j_imp * b->inv_m * ny;
                }
            }
        }
        for (int i = 0; i < bs->n; i++) {
            sc_ball_t *b = &bs->b[i];
            if (W >= 2.0f * b->r) wall(b, &b->x, &b->vx, b->r, W - b->r, e, 1);
            if (H >= 2.0f * b->r) wall(b, &b->y, &b->vy, b->r, H - b->r, e, 2);
            keep_inside(b, W, H);
            /* rolling friction while touching the floor/ceiling/walls keeps resting balls calm */
            if (b->y >= H - b->r - 0.01f || b->y <= b->r + 0.01f) b->vx *= 1.0f - 0.6f * h;
            if (b->x >= W - b->r - 0.01f || b->x <= b->r + 0.01f) b->vy *= 1.0f - 0.6f * h;
        }
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Rendering                                                                                   */

typedef struct { int x0, y0, x1, y1; } box_t;   /* exclusive max */

static void box_union(box_t *u, const box_t *b) {
    if (b->x0 >= b->x1 || b->y0 >= b->y1) return;
    if (u->x0 >= u->x1 || u->y0 >= u->y1) { *u = *b; return; }
    if (b->x0 < u->x0) u->x0 = b->x0;
    if (b->y0 < u->y0) u->y0 = b->y0;
    if (b->x1 > u->x1) u->x1 = b->x1;
    if (b->y1 > u->y1) u->y1 = b->y1;
}

static void fill_span(uint16_t *d, uint16_t px, int n) {
    if (n <= 0) return;
    if (((uintptr_t)d & 2u) && n) { *d++ = px; n--; }
    sc_u32_alias *w = (sc_u32_alias *)(void *)d;
    uint32_t pat = (uint32_t)px * 0x00010001u;
    int words = n >> 1;
    for (int i = 0; i < words; i++) w[i] = pat;
    if (n & 1) d[n - 1] = px;
}

static inline uint16_t blend(uint16_t dst, int sr, int sg, int sb, int a /*0..256*/) {
    int dr, dg, db;
    be_to_rgb565(dst, &dr, &dg, &db);
    return rgb565_to_be(dr + (((sr - dr) * a) >> 8), dg + (((sg - dg) * a) >> 8), db + (((sb - db) * a) >> 8));
}

/* Anti-aliased filled axis-aligned ellipse, clipped to `c`. Solid spans use 32-bit stores; only the
 * ~1 px rim is blended (coverage from the normalised radial distance). */
static void draw_ellipse(uint16_t *fb, int stride, const box_t *c, float cx, float cy, float rx, float ry, uint16_t px) {
    if (rx < 0.5f || ry < 0.5f) return;
    int sr, sg, sb;
    be_to_rgb565(px, &sr, &sg, &sb);
    float rmin = sc_minf(rx, ry);
    float irx = 1.0f / rx, iry = 1.0f / ry, half = 0.5f / rmin;
    float qi = sc_maxf(0.0f, 1.0f - half), qo = 1.0f + half;
    float qi2 = qi * qi, qo2 = qo * qo;
    int y0 = sc_clampi((int)(cy - ry - 1.0f), c->y0, c->y1), y1 = sc_clampi((int)(cy + ry + 2.0f), c->y0, c->y1);
    for (int py = y0; py < y1; py++) {
        float dy = ((float)py + 0.5f - cy) * iry, dy2 = dy * dy;
        if (dy2 >= qo2) continue;
        float xo = rx * sc_sqrtf(qo2 - dy2);
        float xi = dy2 < qi2 ? rx * sc_sqrtf(qi2 - dy2) : -1.0f;
        int ax0 = (int)(cx - xo - 0.5f + 1024.0f) - 1024, ax1 = (int)(cx + xo + 0.5f + 1024.0f) - 1024 + 1;
        int sx0 = 1, sx1 = 0;   /* solid span [sx0, sx1) */
        if (xi > 0.0f) {
            sx0 = (int)(cx - xi - 0.5f + 1024.0f) - 1024 + 1;
            sx1 = (int)(cx + xi - 0.5f + 1024.0f) - 1024 + 1;
        }
        if (ax0 < c->x0) ax0 = c->x0;
        if (ax1 > c->x1) ax1 = c->x1;
        uint16_t *row = fb + (size_t)py * stride;
        for (int x = ax0; x < ax1; x++) {
            if (x >= sx0 && x < sx1) {
                int e = sx1 < ax1 ? sx1 : ax1;
                fill_span(row + x, px, e - x);
                x = e - 1;
                continue;
            }
            float dx = ((float)x + 0.5f - cx) * irx;
            float q = sc_sqrtf(dx * dx + dy2);
            float cov = (1.0f - q) * rmin + 0.5f;
            if (cov <= 0.0f) continue;
            if (cov >= 1.0f) row[x] = px;
            else row[x] = blend(row[x], sr, sg, sb, (int)(cov * 256.0f));
        }
    }
}

typedef struct { float cx, cy, rx, ry; } geo_t;

static geo_t ball_geo(const sc_ball_t *b) {
    geo_t g = { b->x, b->y, b->r, b->r };
    if (b->sq > 0.0f) {
        float n = b->r * (1.0f - b->sq), t = b->r * (1.0f + 0.6f * b->sq);
        if (b->sq_axis == 1) { g.rx = n; g.ry = t; g.cx += (float)b->sq_side * (b->r - n); }
        else { g.ry = n; g.rx = t; g.cy += (float)b->sq_side * (b->r - n); }
    }
    return g;
}

static box_t geo_box(const geo_t *g) {
    box_t b = { (int)(g->cx - g->rx) - 2, (int)(g->cy - g->ry) - 2, (int)(g->cx + g->rx) + 3, (int)(g->cy + g->ry) + 3 };
    return b;
}

static uint32_t qf(float v) { return (uint32_t)(int32_t)(v * 8.0f); }

void sc_balls_render(scene_t *s, uint16_t *fb, uint16_t fb_w, uint16_t fb_h, scene_rect_t *dirty) {
    sc_balls_t *bs = (sc_balls_t *)s->extra;
    int W = s->w < fb_w ? s->w : fb_w, H = s->h < fb_h ? s->h : fb_h;
    box_t full = { 0, 0, W, H }, u = { 0, 0, 0, 0 };
    /* light comes from "up" (against gravity): highlight offset */
    float em = sc_sqrtf(s->ex * s->ex + s->ey * s->ey);
    float lx = em > 1e-3f ? -s->ex / em : 0.0f, ly = em > 1e-3f ? -s->ey / em : -1.0f;
    float hlx = (lx * 0.8f - ly * 0.45f) * 0.36f, hly = (ly * 0.8f + lx * 0.45f) * 0.36f;   /* up and a bit left */
    box_t nb[SC_BALLS_MAX];
    for (int i = 0; i < bs->n; i++) {
        sc_ball_t *b = &bs->b[i];
        if (bs->trail) {   /* trail samples: one per rendered frame */
            for (int k = 0; k + 1 < SC_TRAIL_LEN; k++) { b->tx[k] = b->tx[k + 1]; b->ty[k] = b->ty[k + 1]; }
            b->tx[SC_TRAIL_LEN - 1] = b->x;
            b->ty[SC_TRAIL_LEN - 1] = b->y;
        }
        geo_t g = ball_geo(b);
        box_t bx = geo_box(&g);
        uint32_t st = qf(g.cx) * 31u + qf(g.cy) * 1009u + qf(g.rx) * 7u + qf(g.ry) * 13u + qf(hlx * 64) * 3u + qf(hly * 64) * 5u;
        if (bs->trail)
            for (int k = 0; k < SC_TRAIL_LEN - 1; k++) {
                geo_t tg = { b->tx[k], b->ty[k], b->r, b->r };
                box_t tb = geo_box(&tg);
                box_union(&bx, &tb);
                st = st * 17u + qf(b->tx[k]) * 3u + qf(b->ty[k]);
            }
        nb[i] = bx;
        if (s->need_full || st != b->state || b->bb[0] >= b->bb[2]) {
            box_t ob = { b->bb[0], b->bb[1], b->bb[2], b->bb[3] };
            box_union(&u, &ob);
            box_union(&u, &bx);
        }
        b->state = st;
    }
    if (s->need_full) u = full;
    if (u.x0 < 0) u.x0 = 0;
    if (u.y0 < 0) u.y0 = 0;
    if (u.x1 > W) u.x1 = W;
    if (u.y1 > H) u.y1 = H;
    if (u.x0 < u.x1 && u.y0 < u.y1) {
        for (int y = u.y0; y < u.y1; y++) fill_span(fb + (size_t)y * fb_w + u.x0, 0, u.x1 - u.x0);
        if (bs->trail)
            for (int i = 0; i < bs->n; i++) {
                const sc_ball_t *b = &bs->b[i];
                for (int k = 0; k < SC_TRAIL_LEN - 1; k++) {
                    float dx = b->tx[k] - b->x, dy = b->ty[k] - b->y;
                    if (dx * dx + dy * dy < b->r * b->r * 0.09f) continue;
                    float tr = b->r * (0.55f + 0.08f * (float)k);
                    draw_ellipse(fb, fb_w, &u, b->tx[k], b->ty[k], tr, tr, b->px_trail[k]);
                }
            }
        for (int i = 0; i < bs->n; i++) {
            const sc_ball_t *b = &bs->b[i];
            geo_t g = ball_geo(b);
            draw_ellipse(fb, fb_w, &u, g.cx, g.cy, g.rx, g.ry, b->px);
            float hr = b->r * 0.32f;
            draw_ellipse(fb, fb_w, &u, g.cx + hlx * g.rx * 1.25f, g.cy + hly * g.ry * 1.25f, hr * g.rx / b->r,
                         hr * g.ry / b->r, b->px_hi);
        }
        if (dirty) { dirty->x = (int16_t)u.x0; dirty->y = (int16_t)u.y0; dirty->w = (int16_t)(u.x1 - u.x0); dirty->h = (int16_t)(u.y1 - u.y0); }
    }
    for (int i = 0; i < bs->n; i++) {
        sc_ball_t *b = &bs->b[i];
        b->bb[0] = (int16_t)sc_clampi(nb[i].x0, -4096, 4096);
        b->bb[1] = (int16_t)sc_clampi(nb[i].y0, -4096, 4096);
        b->bb[2] = (int16_t)sc_clampi(nb[i].x1, -4096, 4096);
        b->bb[3] = (int16_t)sc_clampi(nb[i].y1, -4096, 4096);
        b->sq = 0.0f;     /* squash lasts exactly one rendered frame */
        b->sq_axis = 0;
    }
}

bool sc_balls_get(const scene_t *s, int i, float *x, float *y, float *r) {
    if (!s || !s->ready || s->kind != SCENE_BALLS || !s->extra) return false;
    const sc_balls_t *bs = (const sc_balls_t *)s->extra;
    if (i < 0 || i >= bs->n) return false;
    *x = bs->b[i].x;
    *y = bs->b[i].y;
    *r = bs->b[i].r;
    return true;
}
