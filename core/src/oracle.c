/* oracle.c — Oracle (tarot) state machine + picker (see include/oracle.h, PROTOCOL §5f, §5f.3, §5f.6, §5f.7, §5f.8). */
#include "oracle.h"

#include <string.h>

/* ---- small helpers ---------------------------------------------------------------------------- */

static uint32_t xs32(uint32_t *s)
{
    uint32_t x = *s ? *s : 0x9E3779B9u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return *s = x;
}

static uint32_t sat_add(uint32_t a, uint32_t b) { return a > UINT32_MAX - b ? UINT32_MAX : a + b; }

/* ---- picker ----------------------------------------------------------------------------------- */

static bool same_set(const int16_t a[3], const int16_t b[3])
{
    if (b[0] < 0) return false;
    for (int i = 0; i < 3; i++) {
        if (a[i] != b[0] && a[i] != b[1] && a[i] != b[2]) return false;
    }
    return true;
}

void or_pick_three(uint16_t cards, const int16_t prev[3], uint32_t *rng, int16_t out[3])
{
    if (cards < 3) cards = 3;
    for (int tries = 0; tries < 64; tries++) {
        for (int s = 0; s < 3; s++) {
            int r = (int)(xs32(rng) % (uint32_t)(cards - s));
            for (int i = 0; i < cards; i++) {
                bool used = false;
                for (int k = 0; k < s; k++) used |= out[k] == i;
                if (used) continue;
                if (r-- == 0) {
                    out[s] = (int16_t)i;
                    break;
                }
            }
        }
        if (cards == 3 || !prev || !same_set(out, prev)) return;   /* 3 cards: the only set there is */
    }
}

/* ---- geometry --------------------------------------------------------------------------------- */

const int16_t or_three_x[3] = { 52, 214, 376 };
const int16_t or_keys_x[3] = { 26, 188, 350 };

uint16_t or_asset_w(or_asset_t a)
{
    static const uint16_t w[OR_ASSETS] = { OR_SCREEN_W, OR_CARD_W, OR_KEY_W, OR_NOTE_W };
    return a < OR_ASSETS ? w[a] : 0;
}

uint16_t or_asset_h(or_asset_t a)
{
    static const uint16_t h[OR_ASSETS] = { OR_SCREEN_H, OR_CARD_H, OR_KEY_H, OR_NOTE_H };
    return a < OR_ASSETS ? h[a] : 0;
}

/* ---- state machine ---------------------------------------------------------------------------- */

void or_init(or_t *o, const or_config_t *cfg, uint32_t seed)
{
    memset(o, 0, sizeof *o);
    o->cfg = *cfg;
    o->cfg.cards = cfg->cards < OR_MIN_CARDS ? OR_MIN_CARDS : cfg->cards > OR_MAX_CARDS ? OR_MAX_CARDS : cfg->cards;
    o->cfg.shake_g = !(cfg->shake_g >= OR_SHAKE_G_MIN) ? OR_SHAKE_G_MIN
                     : cfg->shake_g > OR_SHAKE_G_MAX  ? OR_SHAKE_G_MAX
                                                      : cfg->shake_g;
    o->phase = OR_WAITS;
    o->three[0] = o->three[1] = o->three[2] = -1;
    o->prev[0] = o->prev[1] = o->prev[2] = -1;
    o->shuf[0] = o->shuf[1] = o->shuf[2] = -1;
    for (int k = 0; k < OR_LEAN_SCREENS; k++) o->lean[k] = -1;
    o->shake_ready = true;
    o->rng = seed ? seed : 0x9E3779B9u;
}

/* A random card for slot `s` of shuffle frame k: never that slot's previous shuffle card, nor its chosen card. */
static int16_t shuffle_pick(or_t *o, int s, int chosen, unsigned k)
{
    (void)k;
    const int n = o->cfg.cards, prev = o->shuf[s];
    const int excluded = 1 + (prev >= 0 && prev != chosen ? 1 : 0);
    int r = (int)(xs32(&o->rng) % (uint32_t)(n - excluded));
    for (int i = 0; i < n; i++) {
        if (i == chosen || i == prev) continue;
        if (r-- == 0) return (int16_t)i;
    }
    return 0;   /* not reached */
}

static uint32_t shuffle_k(const or_t *o) { return (uint32_t)((uint64_t)o->t_ms * OR_SHUFFLE_FPS / 1000u); }

static void shuffle_update(or_t *o)
{
    if (o->phase != OR_SHUFFLE) return;
    const uint32_t k = shuffle_k(o);
    if (k >= OR_SHUFFLE_FRAMES) return;   /* the chosen cards */
    if (o->shuf[0] >= 0 && k == o->shuf_k) return;
    for (int s = 0; s < 3; s++) o->shuf[s] = shuffle_pick(o, s, o->three[s], k);
    o->shuf_k = (uint8_t)k;
}

static void enter(or_t *o, or_phase_t ph)
{
    o->phase = ph;
    o->screen = 0;
    o->t_ms = 0;
}

/* A draw: three cards (forced, or random and not the previous set), the shuffle. */
static void start_draw(or_t *o, const int forced[3])
{
    if (forced) {
        for (int i = 0; i < 3; i++) o->three[i] = (int16_t)forced[i];
    } else {
        or_pick_three(o->cfg.cards, o->prev, &o->rng, o->three);
    }
    for (int s = 0; s < OR_LEAN_SCREENS; s++) o->lean[s] = -1;
    o->idle_ms = 0;
    o->draws++;
    enter(o, OR_SHUFFLE);
    o->shuf[0] = o->shuf[1] = o->shuf[2] = -1;
    o->shuf_k = 0;
    shuffle_update(o);
}

static void to_waits(or_t *o) { enter(o, OR_WAITS); }

/* Lean screen s shows: as told (or_lean_screens); not told yet: screen 0 only (provisionally). */
static bool lean_has(const or_t *o, int s) { return o->lean[0] < 0 ? s == 0 : o->lean[s] > 0; }

static bool detail_has(const or_t *o, int i)
{
    const int c = o->three[i];
    return c >= 0 && c < OR_MAX_CARDS && o->cfg.card_detail[c];
}

/* The first (dir > 0) / last (dir < 0) lean screen / detail present from index `from` on; -1 = none. */
static int lean_find(const or_t *o, int from, int dir)
{
    for (int s = from; s >= 0 && s < OR_LEAN_SCREENS; s += dir) {
        if (lean_has(o, s)) return s;
    }
    return -1;
}

static int detail_find(const or_t *o, int from, int dir)
{
    for (int i = from; i >= 0 && i < 3; i += dir) {
        if (detail_has(o, i)) return i;
    }
    return -1;
}

static void enter_at(or_t *o, or_phase_t ph, int screen)
{
    enter(o, ph);
    o->screen = (int8_t)screen;
}

/* Forward from the lean screens past index `from` - 1: the next lean screen, else the first detail, else HOLD. */
static void forward_from_lean(or_t *o, int from)
{
    const int s = lean_find(o, from, +1);
    if (s >= 0) {
        enter_at(o, OR_LEAN, s);
        return;
    }
    const int d = detail_find(o, 0, +1);
    if (d >= 0) enter_at(o, OR_DETAIL, d);
    else enter(o, OR_HOLD);
}

/* Backward from the lean screens before index `from` + 1: the previous lean screen, else THREE. */
static void back_from_lean(or_t *o, int from)
{
    const int s = lean_find(o, from, -1);
    if (s >= 0) enter_at(o, OR_LEAN, s);
    else enter(o, OR_THREE);
}

/* The next screen (a tap, or a screen timer). */
static void go_next(or_t *o)
{
    switch (o->phase) {
    case OR_WAITS: enter(o, OR_ARMED); break;
    case OR_ARMED: start_draw(o, NULL); break;
    case OR_SHUFFLE: break;
    case OR_THREE: forward_from_lean(o, 0); break;
    case OR_LEAN: forward_from_lean(o, o->screen + 1); break;
    case OR_DETAIL: {
        const int d = detail_find(o, o->screen + 1, +1);
        if (d >= 0) enter_at(o, OR_DETAIL, d);
        else enter(o, OR_HOLD);
        break;
    }
    case OR_HOLD: to_waits(o); break;
    }
}

bool or_trigger(or_t *o, const int cards[3])
{
    if (cards) {
        for (int i = 0; i < 3; i++) {
            if (cards[i] < 0 || cards[i] >= (int)o->cfg.cards) return false;
        }
        if (cards[0] == cards[1] || cards[0] == cards[2] || cards[1] == cards[2]) return false;
    }
    start_draw(o, cards);
    return true;
}

bool or_turn(or_t *o)
{
    o->idle_ms = 0;
    if (o->phase == OR_SHUFFLE) return false;
    go_next(o);
    return true;
}

bool or_back(or_t *o)
{
    o->idle_ms = 0;
    switch (o->phase) {
    case OR_WAITS:
    case OR_SHUFFLE: return false;   /* waits is the floor; a shuffle runs to its end */
    case OR_ARMED:
    case OR_THREE: to_waits(o); return true;
    case OR_LEAN: back_from_lean(o, o->screen - 1); return true;
    case OR_DETAIL: {
        const int d = detail_find(o, o->screen - 1, -1);
        if (d >= 0) enter_at(o, OR_DETAIL, d);
        else back_from_lean(o, OR_LEAN_SCREENS - 1);
        return true;
    }
    case OR_HOLD: {
        const int d = detail_find(o, 2, -1);
        if (d >= 0) enter_at(o, OR_DETAIL, d);
        else back_from_lean(o, OR_LEAN_SCREENS - 1);
        return true;
    }
    }
    return false;
}

bool or_lean_screens(or_t *o, const bool present[OR_LEAN_SCREENS])
{
    if (!present) return false;
    for (int s = 0; s < OR_LEAN_SCREENS; s++) o->lean[s] = present[s] ? 1 : 0;
    if (o->phase == OR_LEAN && !lean_has(o, o->screen)) forward_from_lean(o, o->screen);   /* shown provisionally */
    return true;
}

/* The screen's own timer (0 = none): face_ms on THREE, page_ms on the lean and detail screens. */
static uint32_t screen_ms(const or_t *o)
{
    switch (o->phase) {
    case OR_THREE: return o->cfg.face_ms;
    case OR_LEAN:
    case OR_DETAIL: return o->cfg.page_ms;
    default: return 0;
    }
}

/* Time transitions (a long dt may cross several screens; the remainder carries over). hold_ms is the idle timeout. */
static void advance(or_t *o, uint32_t dt)
{
    o->t_ms = sat_add(o->t_ms, dt);
    o->idle_ms = sat_add(o->idle_ms, dt);
    if (o->phase != OR_WAITS && o->cfg.hold_ms && o->idle_ms >= o->cfg.hold_ms) {
        to_waits(o);
        return;
    }
    for (int guard = 0; guard < 64; guard++) {
        if (o->phase == OR_WAITS) {
            o->t_ms = 0;
            return;
        }
        if (o->phase == OR_SHUFFLE) {
            if (o->t_ms < OR_SHUFFLE_MS) return;
            const uint32_t rem = o->t_ms - OR_SHUFFLE_MS;
            enter(o, OR_THREE);
            o->prev[0] = o->three[0];
            o->prev[1] = o->three[1];
            o->prev[2] = o->three[2];
            o->shuf[0] = o->shuf[1] = o->shuf[2] = -1;
            o->t_ms = rem;
            continue;
        }
        const uint32_t ms = screen_ms(o);
        if (!ms || o->t_ms < ms) return;
        const uint32_t rem = o->t_ms - ms;
        go_next(o);
        o->t_ms = rem;
    }
}

static void put(or_draw_t *d, or_asset_t a, uint16_t frame, int x, int y)
{
    if (d->n >= OR_MAX_OPS) return;
    d->op[d->n++] = (or_op_t){ .asset = (uint8_t)a, .frame = frame, .x = (int16_t)x, .y = (int16_t)y };
}

static void draw_three(const int16_t cards[3], bool keys, or_draw_t *d)
{
    for (int s = 0; s < 3; s++) put(d, OR_ASSET_DECK, or_deck_card((uint16_t)cards[s]), or_three_x[s], OR_CARD_Y);
    if (!keys) return;
    for (int s = 0; s < 3; s++) put(d, OR_ASSET_KEYS, (uint16_t)cards[s], or_keys_x[s], OR_KEYS_Y);
}

void or_set_flipped(or_t *o, bool flipped) { o->flipped = flipped; }

void or_draw(const or_t *o, or_draw_t *d)
{
    memset(d, 0, sizeof *d);
    switch (o->phase) {
    case OR_WAITS:
        put(d, OR_ASSET_TEXT, 0, 0, 0);
        put(d, OR_ASSET_DECK, 0, or_back_x(o), OR_BACK_Y);
        break;
    case OR_ARMED:
        put(d, OR_ASSET_TEXT, OR_TEXT_ARMED_FRAME, 0, 0);
        put(d, OR_ASSET_DECK, 0, or_back_x(o), OR_BACK_Y);
        break;
    case OR_SHUFFLE: {
        const bool chosen = shuffle_k(o) >= OR_SHUFFLE_FRAMES;
        int16_t c[3];
        for (int s = 0; s < 3; s++) c[s] = (chosen || o->shuf[s] < 0) ? o->three[s] : o->shuf[s];
        draw_three(c, false, d);
        break;
    }
    case OR_THREE:
    case OR_HOLD:
        draw_three(o->three, o->cfg.keys, d);
        break;
    case OR_LEAN:
        put(d, OR_ASSET_TEXT, (uint16_t)(OR_TEXT_LEAN_FRAME + o->screen), 0, 0);
        break;
    case OR_DETAIL: {   /* §5f.10: the card beside its brief when it fits there, else the brief alone at full width */
        const int c = o->three[o->screen];
        put(d, OR_ASSET_TEXT, or_text_detail((uint16_t)c), 0, 0);
        if (c >= 0 && c < OR_MAX_CARDS && o->cfg.card_beside[c]) put(d, OR_ASSET_DECK, or_deck_card((uint16_t)c), or_back_x(o), OR_BACK_Y);
        break;
    }
    }
}

bool or_draw_black(const or_draw_t *d) { return d->n == 0 || d->op[0].asset != OR_ASSET_TEXT; }

static bool same_op(const or_op_t *a, const or_op_t *b)
{
    return a->asset == b->asset && a->frame == b->frame && a->x == b->x && a->y == b->y;
}

int or_draw_diff(const or_draw_t *prev, const or_draw_t *next)
{
    if (prev->n != next->n || or_draw_black(prev) != or_draw_black(next)) return -1;
    if (!or_draw_black(next) && !same_op(&prev->op[0], &next->op[0])) return -1;   /* another text screen */
    int mask = 0;
    for (int i = 0; i < next->n; i++) {
        const or_op_t *a = &prev->op[i], *b = &next->op[i];
        if (a->asset != b->asset || a->x != b->x || a->y != b->y) return -1;      /* another layout */
        if (a->frame != b->frame) mask |= 1 << i;
    }
    return mask;
}

static bool same_draw(const or_draw_t *a, const or_draw_t *b)
{
    if (a->n != b->n) return false;
    for (int i = 0; i < a->n; i++) {
        if (!same_op(&a->op[i], &b->op[i])) return false;
    }
    return true;
}

bool or_step(or_t *o, uint32_t dt, float shake, bool press, or_draw_t *d)
{
    advance(o, dt);
    if (!o->shake_ready && shake < o->cfg.shake_g * 0.5f) o->shake_ready = true;
    const bool shaken = o->shake_ready && shake >= o->cfg.shake_g;
    if (shaken) o->shake_ready = false;   /* the edge is used up on every screen */
    if (shaken && o->phase == OR_ARMED) {
        start_draw(o, NULL);        /* §5f.8: a shake deals only on ARMED; a press in the same step is dropped */
    } else if (press) {
        (void)or_turn(o);
    }
    shuffle_update(o);
    or_draw(o, d);
    if (o->have_drawn && same_draw(&o->drawn, d)) return false;
    o->drawn = *d;
    o->have_drawn = true;
    return true;
}

static uint32_t left(uint32_t total, uint32_t t) { return total == 0 ? UINT32_MAX : t < total ? total - t : 1; }

uint32_t or_next_ms(const or_t *o)
{
    uint32_t n;
    if (o->phase == OR_SHUFFLE) {
        const uint32_t k = shuffle_k(o);
        uint32_t at = OR_SHUFFLE_MS;
        if (k < OR_SHUFFLE_FRAMES) at = ((k + 1u) * 1000u + OR_SHUFFLE_FPS - 1u) / OR_SHUFFLE_FPS;   /* next frame */
        n = at > o->t_ms ? at - o->t_ms : 1;
    } else {
        n = left(screen_ms(o), o->t_ms);
    }
    if (o->phase != OR_WAITS && o->cfg.hold_ms) {
        const uint32_t idle = left(o->cfg.hold_ms, o->idle_ms);
        if (idle < n) n = idle;
    }
    return n;
}

const char *or_state_str(const or_t *o)
{
    switch (o->phase) {
    case OR_ARMED: return "armed";
    case OR_SHUFFLE: return "shuffle";
    case OR_THREE: return "three";
    case OR_LEAN: return "lean";
    case OR_DETAIL: return "detail";
    case OR_HOLD: return "hold";
    default: return "waits";
    }
}

void or_status_three(const or_t *o, int out[3])
{
    const bool shown = o->phase != OR_WAITS && o->phase != OR_ARMED && o->phase != OR_SHUFFLE;
    for (int s = 0; s < 3; s++) out[s] = shown ? o->three[s] : -1;
}

int or_status_card(const or_t *o) { return o->phase == OR_DETAIL ? o->three[o->screen] : -1; }

int or_status_page(const or_t *o) { return (o->phase == OR_LEAN || o->phase == OR_DETAIL) ? o->screen : -1; }

bool or_animating(const or_t *o) { return o->phase == OR_SHUFFLE; }
