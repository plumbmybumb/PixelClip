/* scene_words.c — words that bounce with the movement (PROTOCOL §5b.1).
 *
 * The sprites are the frames of a sheet the app renders (one word per frame, black = transparent), handed over by the
 * caller with scene_words_set_sprites() after scene_init(). Each word is the tight box of its frame's ink: an
 * axis-aligned rectangle that never rotates (text stays upright). Physics in pixels and seconds, sub-stepped at
 * <= 1/240 s like the balls: gravity scaled so 1 g crosses the screen height in ~0.6 s, wall bounces with restitution
 * `bounce`/100, rectangle-rectangle contacts (separation along the axis of least penetration, an impulse with
 * restitution along it, Coulomb friction along the other axis), wall friction, shake kicks. Slow impacts are absorbed
 * and friction holds a word still on a slope it cannot slide down, so the words come to rest, readable, when the clip
 * is still. Rendering: black ground, sprites copied at integer positions (black pixels pass through), the dirty rect is
 * the union of the moved words' old and new rectangles. A drawn position only changes when the word has moved by more
 * than half a pixel past it (no 1-px shimmer of resting words).
 */
#include "scene_internal.h"

#define SUBSTEP_MAX_DT (1.0f / 240.0f)
#define G_PER_PIXEL_H 5.8f    /* as the balls: px/s^2 per g per pixel of scene height (240 px -> 1392 px/s^2) */
#define V_REST 45.0f          /* px/s: slower impacts are absorbed (no micro-bounce) */
#define V_MAX 3000.0f
#define V_SLEEP 12.0f         /* px/s: slower and touching something -> held still (two sub-steps of 1 g) */
#define KICK_GAIN 2.5f
#define MU 0.6f               /* Coulomb friction, wall and word contacts */
#define ITERS 8               /* contact passes per sub-step (stacks converge) */
#define DRAW_HYST 0.6f        /* px: a drawn position moves when the word is this far from it */

typedef struct {
    float x, y, vx, vy;       /* top-left of the ink box, velocity */
    float w, h, inv_m;
    int16_t fx0, fy0;         /* the ink box's top-left inside its frame */
    int16_t dx, dy;           /* drawn position (integer), valid when drawn */
    uint8_t frame, drawn, touching, held;   /* held: the pull is all into supports or cancelled by friction */
    uint8_t sx, sy;           /* supports on that axis from the last contacts: bit 0 the low side, bit 1 the high side */
} sc_word_t;

typedef struct {
    int n;                    /* words with ink */
    float e, G;
    uint16_t sw, sh;          /* the sheet's frame size */
    const uint16_t *frames[SCENE_WORDS_MAX];
    sc_word_t wd[SCENE_WORDS_MAX];
} sc_words_t;

size_t sc_words_extra(int gw, int gh, const int32_t *pv)
{
    (void)gw; (void)gh; (void)pv;
    return sizeof(sc_words_t);
}

void sc_words_init(scene_t *s)
{
    sc_words_t *ws = (sc_words_t *)s->extra;
    memset(ws, 0, sizeof *ws);
    ws->e = (float)s->pv[PW_BOUNCE] / 100.0f;
    ws->G = G_PER_PIXEL_H * (float)s->h;
    s->mass = 0;
}

static bool overlaps(const sc_word_t *a, const sc_word_t *b, float pad)
{
    return a->x < b->x + b->w + pad && b->x < a->x + a->w + pad && a->y < b->y + b->h + pad && b->y < a->y + a->h + pad;
}

int scene_words_set_sprites(scene_t *s, const uint16_t *const frames[], int n, uint16_t w, uint16_t h)
{
    if (!s || !s->ready || s->kind != SCENE_WORDS || !s->extra || !frames || n < 1 || n > SCENE_WORDS_MAX || !w ||
        !h || w > SCENE_WORDS_MAX_W || h > SCENE_WORDS_MAX_H || (uint32_t)n * w * h > SCENE_WORDS_MAX_PX) {
        return -1;
    }
    for (int f = 0; f < n; f++)
        if (!frames[f]) return -1;
    sc_words_t *ws = (sc_words_t *)s->extra;
    ws->n = 0;
    ws->sw = w;
    ws->sh = h;
    const float W = (float)s->w, H = (float)s->h;
    for (int f = 0; f < n; f++) {
        ws->frames[f] = frames[f];
        int x0 = w, y0 = h, x1 = -1, y1 = -1;
        for (int y = 0; y < h; y++) {
            const uint16_t *row = frames[f] + (size_t)y * w;
            for (int x = 0; x < w; x++) {
                if (!row[x]) continue;
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                y1 = y;
            }
        }
        if (x1 < 0) continue;   /* no ink: skipped */
        sc_word_t *wd = &ws->wd[ws->n++];
        memset(wd, 0, sizeof *wd);
        wd->frame = (uint8_t)f;
        wd->fx0 = (int16_t)x0;
        wd->fy0 = (int16_t)y0;
        wd->w = (float)(x1 - x0 + 1);
        wd->h = (float)(y1 - y0 + 1);
        wd->inv_m = 1.0f / (wd->w * wd->h);
    }
    /* start positions: spread over the screen from the seed, apart when there is room (they fall in) */
    for (int i = 0; i < ws->n; i++) {
        sc_word_t *a = &ws->wd[i];
        const float rx = sc_maxf(0.0f, W - a->w), ry = sc_maxf(0.0f, H - a->h);
        for (int tries = 0; tries < 40; tries++) {
            a->x = sc_randf(s) * rx;
            a->y = sc_randf(s) * ry * 0.7f;   /* the upper part: they fall in */
            bool clear = true;
            for (int j = 0; j < i && clear; j++) clear = !overlaps(a, &ws->wd[j], 2.0f);
            if (clear) break;
        }
        a->vx = sc_rands(s) * 120.0f;
        a->vy = sc_rands(s) * 60.0f;
    }
    s->mass = ws->n;
    s->need_full = 1;
    return ws->n;
}

/* A wall on one axis: clamp, bounce (slow impacts absorbed). Returns the speed taken out along the normal (0: no
 * contact), the friction budget of that contact. */
static float wall(float *pos, float *vel, float lo, float hi, float e)
{
    if (hi < lo) {   /* larger than the screen on this axis: centred, still */
        *pos = (lo + hi) * 0.5f;
        *vel = 0.0f;
        return 0.0f;
    }
    if (*pos < lo) {
        *pos = lo;
        if (*vel < 0.0f) {
            const float imp = -*vel;
            *vel = imp < V_REST ? 0.0f : imp * e;
            return imp;
        }
        return 1e-3f;
    }
    if (*pos > hi) {
        *pos = hi;
        if (*vel > 0.0f) {
            const float imp = *vel;
            *vel = imp < V_REST ? 0.0f : -imp * e;
            return imp;
        }
        return 1e-3f;
    }
    return 0.0f;
}

/* Coulomb friction: take at most mu * dvn off the tangential speed. */
static float friction(float vt, float dvn)
{
    const float cap = MU * dvn;
    return vt > cap ? vt - cap : vt < -cap ? vt + cap : 0.0f;
}

static void walls(sc_word_t *a, float W, float H, float e)
{
    const float nx = wall(&a->x, &a->vx, 0.0f, W - a->w, e);
    if (nx > 0.0f) {
        a->vy = friction(a->vy, nx);
        a->touching = 1;
        a->sx |= a->x > (W - a->w) * 0.5f ? 2 : 1;
    }
    const float ny = wall(&a->y, &a->vy, 0.0f, H - a->h, e);
    if (ny > 0.0f) {
        a->vx = friction(a->vx, ny);
        a->touching = 1;
        a->sy |= a->y > (H - a->h) * 0.5f ? 2 : 1;
    }
}

static void contact(sc_word_t *a, sc_word_t *b, float e)
{
    const float px = sc_minf(a->x + a->w, b->x + b->w) - sc_maxf(a->x, b->x);
    const float py = sc_minf(a->y + a->h, b->y + b->h) - sc_maxf(a->y, b->y);
    if (px <= 0.0f || py <= 0.0f) return;
    const float ws = a->inv_m + b->inv_m;
    /* the axis of least penetration; the normal points from a to b */
    const bool on_x = px < py;
    const float ca = on_x ? a->x + a->w * 0.5f : a->y + a->h * 0.5f, cb = on_x ? b->x + b->w * 0.5f : b->y + b->h * 0.5f;
    const float sgn = cb >= ca ? 1.0f : -1.0f;
    const float pen = (on_x ? px : py) / ws;
    float *ap = on_x ? &a->x : &a->y, *bp = on_x ? &b->x : &b->y;
    *ap -= sgn * pen * a->inv_m;
    *bp += sgn * pen * b->inv_m;
    float *avn = on_x ? &a->vx : &a->vy, *bvn = on_x ? &b->vx : &b->vy;
    float *avt = on_x ? &a->vy : &a->vx, *bvt = on_x ? &b->vy : &b->vx;
    const float vn = (*bvn - *avn) * sgn;   /* < 0: approaching */
    a->touching = b->touching = 1;
    uint8_t *as = on_x ? &a->sx : &a->sy, *bs = on_x ? &b->sx : &b->sy;
    *as |= sgn > 0.0f ? 2 : 1;   /* b is on a's high side when the normal points up the axis */
    *bs |= sgn > 0.0f ? 1 : 2;
    if (vn >= 0.0f) return;
    const float ee = -vn < V_REST ? 0.0f : e;
    const float j = -(1.0f + ee) * vn / ws;   /* impulse along the normal */
    *avn -= sgn * j * a->inv_m;
    *bvn += sgn * j * b->inv_m;
    /* friction on the relative tangential speed, at most mu * j */
    const float vt = *bvt - *avt;
    const float jt_max = MU * j, jt_need = vt / ws;
    const float jt = jt_need > jt_max ? jt_max : jt_need < -jt_max ? -jt_max : jt_need;
    *avt += jt * a->inv_m;
    *bvt -= jt * b->inv_m;
}

void sc_words_step(scene_t *s, float dt, float kick)
{
    sc_words_t *ws = (sc_words_t *)s->extra;
    if (!ws->n) return;
    const float W = (float)s->w, H = (float)s->h, e = ws->e;
    const float ax = ws->G * (s->ex + KICK_GAIN * s->hp[0]);
    const float ay = ws->G * (s->ey + KICK_GAIN * s->hp[1]);
    if (kick > 0.0f) {
        const float hx = s->hp[0], hy = s->hp[1], hm = sc_sqrtf(hx * hx + hy * hy);
        const float kx = hm > 1e-3f ? hx / hm : 0.0f, ky = hm > 1e-3f ? hy / hm : -1.0f;
        const float sp = 220.0f * sc_minf(kick, 3.0f);
        for (int i = 0; i < ws->n; i++) {
            ws->wd[i].vx += kx * sp * (0.7f + 0.6f * sc_randf(s)) + sc_rands(s) * sp * 0.35f;
            ws->wd[i].vy += ky * sp * (0.7f + 0.6f * sc_randf(s)) + sc_rands(s) * sp * 0.35f;
        }
    }
    int n = (int)(dt * (1.0f / SUBSTEP_MAX_DT)) + 1;
    if (n > 16) n = 16;
    const float h = dt / (float)n, drag = 1.0f - 0.12f * h;
    for (int it = 0; it < n; it++) {
        for (int i = 0; i < ws->n; i++) {
            sc_word_t *a = &ws->wd[i];
            /* static friction on a support the acceleration presses into: the tangential pull is held back up to
             * mu times the pressing part (a word on a gentle slope does not creep) */
            const bool py = (ay > 0.0f && (a->sy & 2)) || (ay < 0.0f && (a->sy & 1));   /* pressed into a support */
            const bool px = (ax > 0.0f && (a->sx & 2)) || (ax < 0.0f && (a->sx & 1));
            float axw = ax, ayw = ay;
            if (py) axw = friction(ax, sc_absf(ay));
            if (px) ayw = friction(ay, sc_absf(ax));
            const bool hx = axw == 0.0f || px, hy = ayw == 0.0f || py;
            a->held = hx && hy;
            a->vx = sc_clampf((a->vx + axw * h) * drag, -V_MAX, V_MAX);
            a->vy = sc_clampf((a->vy + ayw * h) * drag, -V_MAX, V_MAX);
            a->x += a->vx * h;
            a->y += a->vy * h;
            a->touching = 0;
            a->sx = a->sy = 0;
        }
        for (int pass = 0; pass < ITERS; pass++) {
            for (int i = 0; i < ws->n; i++)
                for (int j = i + 1; j < ws->n; j++) contact(&ws->wd[i], &ws->wd[j], e);
            for (int i = 0; i < ws->n; i++) walls(&ws->wd[i], W, H, e);
        }
        for (int i = 0; i < ws->n; i++) {   /* a slow word resting on something that holds it is kept still */
            sc_word_t *a = &ws->wd[i];
            if (a->touching && a->held && sc_absf(a->vx) < V_SLEEP && sc_absf(a->vy) < V_SLEEP) a->vx = a->vy = 0.0f;
        }
    }
}

/* ---- rendering ---------------------------------------------------------------------------------------------------- */

typedef struct { int x0, y0, x1, y1; } wbox_t;   /* exclusive max */

static void wbox_union(wbox_t *u, wbox_t b)
{
    if (b.x0 >= b.x1 || b.y0 >= b.y1) return;
    if (u->x0 >= u->x1 || u->y0 >= u->y1) {
        *u = b;
        return;
    }
    if (b.x0 < u->x0) u->x0 = b.x0;
    if (b.y0 < u->y0) u->y0 = b.y0;
    if (b.x1 > u->x1) u->x1 = b.x1;
    if (b.y1 > u->y1) u->y1 = b.y1;
}

static int round_i(float v) { return (int)(v + 1024.5f) - 1024; }

/* The drawn position follows the word with a little hysteresis (resting words do not shimmer). */
static int follow(int drawn, float v)
{
    const float d = v - (float)drawn;
    return (d > DRAW_HYST || d < -DRAW_HYST) ? round_i(v) : drawn;
}

void sc_words_render(scene_t *s, uint16_t *fb, uint16_t fb_w, uint16_t fb_h, scene_rect_t *dirty)
{
    sc_words_t *ws = (sc_words_t *)s->extra;
    const int W = s->w < fb_w ? s->w : fb_w, H = s->h < fb_h ? s->h : fb_h;
    wbox_t u = { 0, 0, 0, 0 };
    for (int i = 0; i < ws->n; i++) {
        sc_word_t *a = &ws->wd[i];
        const int nx = a->drawn ? follow(a->dx, a->x) : round_i(a->x), ny = a->drawn ? follow(a->dy, a->y) : round_i(a->y);
        if (!a->drawn || nx != a->dx || ny != a->dy) {
            if (a->drawn) wbox_union(&u, (wbox_t){ a->dx, a->dy, a->dx + (int)a->w, a->dy + (int)a->h });
            wbox_union(&u, (wbox_t){ nx, ny, nx + (int)a->w, ny + (int)a->h });
        }
        a->dx = (int16_t)nx;
        a->dy = (int16_t)ny;
        a->drawn = 1;
    }
    if (s->need_full) u = (wbox_t){ 0, 0, W, H };
    if (u.x0 < 0) u.x0 = 0;
    if (u.y0 < 0) u.y0 = 0;
    if (u.x1 > W) u.x1 = W;
    if (u.y1 > H) u.y1 = H;
    if (u.x0 >= u.x1 || u.y0 >= u.y1) return;
    for (int y = u.y0; y < u.y1; y++) memset(fb + (size_t)y * fb_w + u.x0, 0, (size_t)(u.x1 - u.x0) * 2u);
    for (int i = 0; i < ws->n; i++) {   /* every word inside the cleared box, clipped to it */
        const sc_word_t *a = &ws->wd[i];
        const int ww = (int)a->w, wh = (int)a->h;
        const int x0 = sc_clampi(a->dx, u.x0, u.x1), x1 = sc_clampi(a->dx + ww, u.x0, u.x1);
        const int y0 = sc_clampi(a->dy, u.y0, u.y1), y1 = sc_clampi(a->dy + wh, u.y0, u.y1);
        if (x0 >= x1 || y0 >= y1) continue;
        const uint16_t *src = ws->frames[a->frame];
        for (int y = y0; y < y1; y++) {
            const uint16_t *sr = src + (size_t)(a->fy0 + y - a->dy) * ws->sw + a->fx0 + (x0 - a->dx);
            uint16_t *d = fb + (size_t)y * fb_w + x0;
            for (int x = 0; x < x1 - x0; x++)
                if (sr[x]) d[x] = sr[x];
        }
    }
    if (dirty) {
        dirty->x = (int16_t)u.x0;
        dirty->y = (int16_t)u.y0;
        dirty->w = (int16_t)(u.x1 - u.x0);
        dirty->h = (int16_t)(u.y1 - u.y0);
    }
}

bool sc_words_get(const scene_t *s, int i, float *x, float *y, float *w, float *h)
{
    if (!s || !s->ready || s->kind != SCENE_WORDS || !s->extra) return false;
    const sc_words_t *ws = (const sc_words_t *)s->extra;
    if (i < 0 || i >= ws->n) return false;
    *x = ws->wd[i].x;
    *y = ws->wd[i].y;
    *w = ws->wd[i].w;
    *h = ws->wd[i].h;
    return true;
}

bool sc_words_speed(const scene_t *s, int i, float *vx, float *vy)
{
    if (!s || !s->ready || s->kind != SCENE_WORDS || !s->extra) return false;
    const sc_words_t *ws = (const sc_words_t *)s->extra;
    if (i < 0 || i >= ws->n) return false;
    *vx = ws->wd[i].vx;
    *vy = ws->wd[i].vy;
    return true;
}
