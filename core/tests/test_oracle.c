/* test_oracle.c — Oracle (tarot): the §5f.6 state machine (three cards for the person's question), composed frames
 * (paste ops + text screens), the lean screen list paged by hand (§5f.3, §5f.7), arming and the shake gate (§5f.8),
 * the picker
 * (include/oracle.h, PROTOCOL §5f). */
#include "tharness.h"
#include "oracle.h"
#include <time.h>

static or_config_t cfg_of(uint16_t cards, uint32_t face, uint32_t page, uint32_t hold)
{
    return (or_config_t){ .cards = cards, .shake_g = 0.9f, .face_ms = face, .page_ms = page, .hold_ms = hold };
}

/* Step `ms` in `step`-ms ticks, no input; returns the number of changed draws, the last one in *d. */
static int run(or_t *o, uint32_t ms, uint32_t step, or_draw_t *d)
{
    int changes = 0;
    or_draw_t x;
    for (uint32_t t = 0; t < ms; t += step) changes += or_step(o, step, 0.0f, false, &x);
    if (d) *d = x;
    return changes;
}

static bool op_is(const or_draw_t *d, int i, or_asset_t a, int frame, int x, int y)
{
    return i < d->n && d->op[i].asset == a && d->op[i].frame == frame && d->op[i].x == x && d->op[i].y == y;
}

/* TEXT[text] + D[deck] at the back's place (normal orientation: x 8, y 17) */
static bool slot_draw(const or_draw_t *d, int text, int deck)
{
    return d->n == 2 && op_is(d, 0, OR_ASSET_TEXT, text, 0, 0) && op_is(d, 1, OR_ASSET_DECK, deck, OR_BACK_X_UP, OR_BACK_Y);
}

/* The three, centred (§5f.12), with their keyword row when `keys` */
static bool three_draw(const or_draw_t *d, const int16_t c[3], bool keys)
{
    if (d->n != (keys ? 6 : 3) || !or_draw_black(d)) return false;
    for (int s = 0; s < 3; s++) {
        if (!op_is(d, s, OR_ASSET_DECK, 1 + c[s], or_three_x[s], OR_CARD_Y)) return false;
        if (keys && !op_is(d, 3 + s, OR_ASSET_KEYS, c[s], or_keys_x[s], OR_KEYS_Y)) return false;
    }
    return true;
}

/* A draw that has reached THREE. */
static void to_three(or_t *o, const int *forced)
{
    or_draw_t d;
    or_trigger(o, forced);
    run(o, OR_SHUFFLE_MS, 50, &d);
}

static void test_frame_math(void)
{
    /* §5f.12: cards 108 x 206; the three at y 0 (x 52 / 214 / 376, 54 px gaps, equal margins), their keys at y 206
     * under them (160 x 34 at x 26 / 188 / 350, centred, not overlapping, ending at the bottom edge); the back / detail
     * card at y 17 (centred), x 8 (normal) or 420 (flipped); all clear of the BOOT corner (x 512..535 y 0..15 normally,
     * x 0..23 y 224..239 flipped) */
    CHECK(OR_CARD_W == 108 && OR_CARD_H == 206 && OR_CARD_Y == 0 && OR_KEYS_Y == OR_CARD_H);
    CHECK(OR_KEY_W == 160 && OR_KEY_H == 34);
    CHECK(or_three_x[0] == 52 && or_three_x[1] == 214 && or_three_x[2] == 376);
    CHECK(or_keys_x[0] == 26 && or_keys_x[1] == 188 && or_keys_x[2] == 350);
    CHECK_EQ(or_three_x[1] - (or_three_x[0] + OR_CARD_W), 54);
    CHECK_EQ(or_three_x[2] - (or_three_x[1] + OR_CARD_W), 54);
    CHECK_EQ(or_three_x[0], OR_SCREEN_W - (or_three_x[2] + OR_CARD_W));
    for (int s = 0; s < 3; s++) CHECK_EQ(or_keys_x[s] + OR_KEY_W / 2, or_three_x[s] + OR_CARD_W / 2);
    for (int s = 0; s < 2; s++) CHECK(or_keys_x[s] + OR_KEY_W <= or_keys_x[s + 1]);   /* whole tiles, no overlap */
    CHECK_EQ(OR_KEYS_Y + OR_KEY_H, OR_SCREEN_H);
    CHECK(OR_KEY_INK_X + OR_KEY_INK_W <= OR_KEY_W && OR_KEY_INK_Y + OR_KEY_INK_H <= OR_KEY_H);
    CHECK(or_three_x[2] + OR_CARD_W <= OR_SCREEN_W - 24 && or_keys_x[2] + OR_KEY_W <= OR_SCREEN_W - 24);   /* normal */
    CHECK(or_keys_x[0] >= 24);                                                                              /* flipped */
    CHECK_EQ(OR_BACK_Y, (OR_SCREEN_H - OR_CARD_H) / 2);
    CHECK(OR_BACK_X_UP + OR_CARD_W <= OR_SCREEN_W - 24 && OR_BACK_X_FLIP >= 24);
    CHECK_EQ(OR_BACK_X_UP, 8);
    CHECK_EQ(OR_BACK_X_FLIP + OR_CARD_W, OR_SCREEN_W - 8);   /* mirrored: 8 px from the far edge */
    CHECK_EQ(or_deck_frames(22), 23u);
    CHECK_EQ(or_deck_card(0), 1);
    uint16_t c;
    for (uint16_t i = 0; i < OR_MAX_CARDS; i++) {
        CHECK_EQ(or_text_screen(or_text_detail(i), &c), OR_TEXT_DETAIL);
        CHECK_EQ(c, i);
    }
    CHECK_EQ(or_text_screen(0, &c), OR_TEXT_WAITS);
    CHECK_EQ(or_text_screen(OR_TEXT_ARMED_FRAME, &c), OR_TEXT_ARMED);
    for (uint16_t s = 0; s < OR_LEAN_SCREENS; s++) {
        CHECK_EQ(or_text_screen((uint16_t)(OR_TEXT_LEAN_FRAME + s), &c), OR_TEXT_LEAN);
        CHECK_EQ(c, s);
    }
    CHECK_EQ(or_asset_w(OR_ASSET_DECK), OR_CARD_W);
    CHECK_EQ(or_asset_h(OR_ASSET_NOTES), OR_NOTE_H);
    CHECK_EQ(or_asset_w(OR_ASSETS), 0);
}

static void test_init_waits(void)
{
    or_t o;
    or_config_t c = cfg_of(1, 0, 0, 0);   /* clamped to 3 cards */
    c.shake_g = 9.0f;
    or_init(&o, &c, 0);
    CHECK_EQ(o.cfg.cards, OR_MIN_CARDS);
    CHECK(o.cfg.shake_g == OR_SHAKE_G_MAX);
    CHECK(o.rng != 0);
    or_draw_t d;
    CHECK(or_step(&o, 0, 0.0f, false, &d));   /* the first step always reports */
    CHECK(slot_draw(&d, 0, 0));
    CHECK(!or_draw_black(&d));
    CHECK(!strcmp(or_state_str(&o), "waits"));
    int t[3];
    or_status_three(&o, t);
    CHECK(t[0] == -1 && t[1] == -1 && t[2] == -1);
    CHECK_EQ(or_status_card(&o), -1);
    CHECK_EQ(or_status_page(&o), -1);
    CHECK_EQ(or_next_ms(&o), UINT32_MAX);
    CHECK(!or_step(&o, 1000, 0.0f, false, &d));
    CHECK(!or_back(&o));                       /* waits is the floor, a double tap does nothing (§5f.6) */
    CHECK_EQ(o.phase, OR_WAITS);
    c = cfg_of(200, 0, 0, 0);
    or_init(&o, &c, 1);
    CHECK_EQ(o.cfg.cards, OR_MAX_CARDS);
}

/* The shuffle: 12 fps, three slots, each never its previous card nor its chosen one, then A, B, C; THREE with keys. */
static void test_shuffle(void)
{
    or_t o;
    or_config_t c = cfg_of(22, 0, 0, 0);
    or_init(&o, &c, 77);
    or_draw_t d, prev;
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(or_turn(&o));                        /* a tap in waits arms (§5f.8) */
    CHECK_EQ(o.phase, OR_ARMED);
    CHECK(or_turn(&o));                        /* a tap on armed deals */
    CHECK_EQ(o.phase, OR_SHUFFLE);
    CHECK(!strcmp(or_state_str(&o), "shuffle"));
    CHECK(or_animating(&o));
    const int16_t A = o.three[0], B = o.three[1], C = o.three[2];
    CHECK(A != B && B != C && A != C);
    int st[3];
    or_status_three(&o, st);
    CHECK(st[0] == -1);                        /* not shown yet */
    CHECK(!or_turn(&o));                       /* taps and backs do nothing during a shuffle */
    CHECK(!or_back(&o));
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(or_draw_black(&d) && d.n == 3);
    prev = d;
    uint32_t t = 0;
    int frames = 1;
    while (o.phase == OR_SHUFFLE) {
        const uint32_t n = or_next_ms(&o);
        t += n;
        or_step(&o, n, 0.0f, false, &d);
        if (o.phase != OR_SHUFFLE) break;
        const int m = or_draw_diff(&prev, &d);
        CHECK(m > 0 && m <= 7);
        const int16_t chosen[3] = { A, B, C };
        for (int s = 0; s < 3; s++) {
            if (t * 12 / 1000 < OR_SHUFFLE_FRAMES) {
                CHECK(d.op[s].frame != 1 + chosen[s]);
                CHECK(d.op[s].frame != prev.op[s].frame);
            }
        }
        if (t * 12 / 1000 >= OR_SHUFFLE_FRAMES) CHECK(three_draw(&d, chosen, false));
        frames++;
        prev = d;
    }
    CHECK_EQ(frames, (int)OR_SHUFFLE_FRAMES + 1);
    CHECK_EQ(o.phase, OR_THREE);
    const int16_t abc[3] = { A, B, C };
    CHECK(three_draw(&d, abc, false));   /* (no keys in this config) */
    CHECK_EQ(or_draw_diff(&prev, &d), 0);     /* §5f.10: the last shuffle frame is the three (the caller adds the arrow) */
    or_status_three(&o, st);
    CHECK(st[0] == A && st[1] == B && st[2] == C);
    CHECK_EQ(or_status_card(&o), -1);
    CHECK(!or_animating(&o));
}

/* The screen of `o` as a short string. */
static const char *scr(const or_t *o, char *buf)
{
    switch (o->phase) {
    case OR_LEAN: snprintf(buf, 16, "L%d", o->screen); return buf;
    case OR_DETAIL: snprintf(buf, 16, "D%d", o->screen); return buf;
    default: return or_state_str(o);
    }
}

/* The whole list forward (telling the lean screens when first reached) and backward. */
static void walk(or_t *o, const bool lean[OR_LEAN_SCREENS], const char *const *want, int n)
{
    char b[16];
    char seen[32][16];
    int k = 0;
    snprintf(seen[k++], 16, "%s", scr(o, b));
    while (o->phase != OR_HOLD && k < 32) {
        or_turn(o);
        if (o->phase == OR_LEAN && o->lean[0] < 0) or_lean_screens(o, lean);
        snprintf(seen[k++], 16, "%s", scr(o, b));
    }
    CHECK_EQ(k, n);
    for (int i = 0; i < k && i < n; i++) {
        const bool ok = !strcmp(seen[i], want[i]);
        CHECK(ok);
        if (!ok) fprintf(stderr, "  forward %d: %s, want %s\n", i, seen[i], want[i]);
    }
    for (int i = n - 2; i >= 0; i--) {
        CHECK(or_back(o));
        const bool ok = !strcmp(scr(o, b), want[i]);
        CHECK(ok);
        if (!ok) fprintf(stderr, "  back %d: %s, want %s\n", i, scr(o, b), want[i]);
    }
    CHECK(or_back(o));   /* three -> waits */
    CHECK_EQ(o->phase, OR_WAITS);
    CHECK(!or_back(o));
}

/* §5f.7: the lean list (three, lean 0-4, detail A B C, hold), next and back, skipped screens. */
static void test_screens(void)
{
    or_t o;
    or_draw_t d;
    or_config_t c = cfg_of(22, 0, 0, OR_HOLD_DEF_MS);
    c.card_detail[4] = c.card_detail[9] = c.card_detail[13] = true;
    or_init(&o, &c, 5);
    const int row[3] = { 4, 9, 13 };
    to_three(&o, row);
    CHECK_EQ(o.phase, OR_THREE);
    static const char *const all[] = { "three", "L0", "L1", "L2", "L3", "L4", "D0", "D1", "D2", "hold" };
    const bool every[5] = { true, true, true, true, true };
    walk(&o, every, all, (int)(sizeof all / sizeof all[0]));
    /* the frames: lean screens are TEXT screens, details TEXT + the card in the slot */
    to_three(&o, row);
    or_turn(&o);
    CHECK_EQ(o.phase, OR_LEAN);
    CHECK_EQ(o.lean[0], -1);                  /* a new draw: not told yet (screen 0 provisionally) */
    or_lean_screens(&o, every);
    or_turn(&o);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(d.n == 1 && d.op[0].asset == OR_ASSET_TEXT && d.op[0].frame == OR_TEXT_LEAN_FRAME + 1);
    CHECK(!strcmp(or_state_str(&o), "lean"));
    CHECK_EQ(or_status_page(&o), 1);
    CHECK_EQ(or_status_card(&o), -1);
    int t[3];
    or_status_three(&o, t);
    CHECK(t[0] == 4 && t[1] == 9 && t[2] == 13);
    while (o.phase != OR_DETAIL) or_turn(&o);
    or_turn(&o);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(d.n == 1 && op_is(&d, 0, OR_ASSET_TEXT, or_text_detail(9), 0, 0));
    CHECK(!strcmp(or_state_str(&o), "detail"));
    CHECK_EQ(or_status_card(&o), 9);
    CHECK_EQ(or_status_page(&o), 1);
    or_turn(&o);
    or_turn(&o);
    CHECK_EQ(o.phase, OR_HOLD);
    or_step(&o, 0, 0.0f, false, &d);
    const int16_t r16[3] = { 4, 9, 13 };
    CHECK(three_draw(&d, r16, false));
    CHECK(!strcmp(or_state_str(&o), "hold"));
    CHECK(or_turn(&o));                        /* the end of the list -> waits */
    CHECK_EQ(o.phase, OR_WAITS);
    /* screens without text are skipped both ways; details only for cards with a brief */
    or_config_t c2 = c;
    c2.card_detail[9] = false;
    or_init(&o, &c2, 6);
    to_three(&o, row);
    static const char *const sparse[] = { "three", "L1", "L2", "L4", "D0", "D2", "hold" };
    const bool some[5] = { false, true, true, false, true };
    or_turn(&o);
    or_lean_screens(&o, some);                 /* told while screen 0 shows provisionally: moved on to screen 1 */
    CHECK(!strcmp(scr(&o, (char[16]){ 0 }), "L1"));
    or_back(&o);
    CHECK_EQ(o.phase, OR_THREE);
    walk(&o, some, sparse, (int)(sizeof sparse / sizeof sparse[0]));
    /* no lean screen and no brief at all: three -> hold */
    or_config_t c0 = cfg_of(22, 0, 0, 0);
    or_init(&o, &c0, 8);
    to_three(&o, row);
    static const char *const bare[] = { "three", "hold" };
    const bool none[5] = { false, false, false, false, false };
    walk(&o, none, bare, 2);
}

/* §5f.11 the orientation moves the back (waits / armed) and the detail card to the end away from the BOOT corner; the
 * three and the shuffle slots stay centred; the lean screens do not move. */
static void test_flip(void)
{
    or_t o;
    or_draw_t d, prev;
    or_config_t c = cfg_of(22, 0, 0, 0);
    c.card_detail[3] = c.card_detail[7] = c.card_detail[11] = true;
    c.card_beside[3] = c.card_beside[11] = true;   /* card 7's brief does not fit beside it */
    c.keys = true;                                  /* §5f.12: the keyword row under the three */
    or_init(&o, &c, 21);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(slot_draw(&d, 0, 0));
    prev = d;
    or_set_flipped(&o, true);
    CHECK(or_step(&o, 0, 0.0f, false, &d));    /* waits: the back moves to x 402 */
    CHECK(d.n == 2 && op_is(&d, 1, OR_ASSET_DECK, 0, OR_BACK_X_FLIP, OR_BACK_Y));
    CHECK_EQ(or_draw_diff(&prev, &d), -1);      /* another layout: a full repaint */
    or_turn(&o);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(d.n == 2 && op_is(&d, 0, OR_ASSET_TEXT, OR_TEXT_ARMED_FRAME, 0, 0) && op_is(&d, 1, OR_ASSET_DECK, 0, OR_BACK_X_FLIP, OR_BACK_Y));
    const int row[3] = { 3, 7, 11 };
    or_trigger(&o, row);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK_EQ(d.n, 3);                          /* the shuffle: no keyword row */
    for (int s = 0; s < 3; s++) CHECK(d.op[s].y == OR_CARD_Y && d.op[s].x == or_three_x[s]);   /* shuffle slots */
    run(&o, OR_SHUFFLE_MS, 50, &d);
    CHECK_EQ(o.phase, OR_THREE);
    const int16_t r16[3] = { 3, 7, 11 };
    CHECK(three_draw(&d, r16, true));
    prev = d;
    or_set_flipped(&o, false);                 /* the three do not move */
    CHECK(!or_step(&o, 0, 0.0f, false, &d));
    CHECK(three_draw(&d, r16, true));
    /* detail: the card beside its brief at the far end, or the brief alone */
    const bool every[5] = { true, true, true, true, true };
    while (o.phase != OR_DETAIL) {
        or_turn(&o);
        if (o.phase == OR_LEAN && o.lean[0] < 0) or_lean_screens(&o, every);
    }
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(d.n == 2 && op_is(&d, 0, OR_ASSET_TEXT, or_text_detail(3), 0, 0) &&
          op_is(&d, 1, OR_ASSET_DECK, or_deck_card(3), OR_BACK_X_UP, OR_BACK_Y));
    or_set_flipped(&o, true);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(op_is(&d, 1, OR_ASSET_DECK, or_deck_card(3), OR_BACK_X_FLIP, OR_BACK_Y));
    or_turn(&o);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(d.n == 1 && op_is(&d, 0, OR_ASSET_TEXT, or_text_detail(7), 0, 0));   /* no card: the brief alone */
    or_turn(&o);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(d.n == 2 && op_is(&d, 1, OR_ASSET_DECK, or_deck_card(11), OR_BACK_X_FLIP, OR_BACK_Y));
    CHECK_EQ(or_back_x(&o), OR_BACK_X_FLIP);
    /* the lean screens do not move */
    to_three(&o, row);
    or_turn(&o);
    or_lean_screens(&o, every);
    or_step(&o, 0, 0.0f, false, &d);
    prev = d;
    or_set_flipped(&o, false);
    CHECK(!or_step(&o, 0, 0.0f, false, &d));
    CHECK_EQ(or_draw_diff(&prev, &d), 0);
}

/* No timers by default; non-zero face_ms / page_ms still advance; hold_ms is the idle timeout. */
static void test_timers(void)
{
    or_t o;
    or_draw_t d;
    or_config_t c = cfg_of(22, 0, 0, 0);
    c.card_detail[1] = c.card_detail[2] = c.card_detail[3] = true;
    or_init(&o, &c, 3);
    const int row[3] = { 1, 2, 3 };
    to_three(&o, row);
    CHECK_EQ(or_next_ms(&o), UINT32_MAX);
    CHECK_EQ(run(&o, 3600000, 60000, &d), 0);  /* an hour on the three */
    CHECK_EQ(o.phase, OR_THREE);
    or_turn(&o);
    const bool every[5] = { true, true, true, true, true };
    or_lean_screens(&o, every);
    run(&o, 60000, 60000, &d);
    CHECK_EQ(run(&o, 3600000, 60000, &d), 0);
    CHECK_EQ(o.phase, OR_LEAN);
    /* auto-advance with non-zero timers: face_ms on three, page_ms on every lean / detail screen */
    c.face_ms = 9000;
    c.page_ms = 12000;
    c.hold_ms = 300000;
    or_init(&o, &c, 4);
    to_three(&o, row);
    CHECK_EQ(or_next_ms(&o), 9000);
    run(&o, 9000, 10, &d);
    CHECK_EQ(o.phase, OR_LEAN);
    or_lean_screens(&o, every);
    run(&o, 5 * 12000, 10, &d);
    CHECK(o.phase == OR_DETAIL && o.screen == 0);
    run(&o, 3 * 12000, 10, &d);
    CHECK_EQ(o.phase, OR_HOLD);
    CHECK_EQ(or_next_ms(&o), 300000u - (OR_SHUFFLE_MS + 9000u + 8u * 12000u));   /* idle since the draw */
    run(&o, 300000, 1000, &d);
    CHECK_EQ(o.phase, OR_WAITS);
    CHECK(slot_draw(&d, 0, 0));
    /* the idle timeout from any screen; each tap / back restarts it */
    c.face_ms = c.page_ms = 0;
    c.hold_ms = 10000;
    or_init(&o, &c, 5);
    to_three(&o, row);
    or_turn(&o);
    CHECK_EQ(or_next_ms(&o), 10000);
    run(&o, 9000, 1000, &d);
    or_back(&o);
    run(&o, 9900, 100, &d);
    CHECK(o.phase != OR_WAITS);
    run(&o, 100, 100, &d);
    CHECK_EQ(o.phase, OR_WAITS);
    /* one huge step: the idle timeout first */
    to_three(&o, row);
    or_step(&o, 400000, 0.0f, false, &d);
    CHECK_EQ(o.phase, OR_WAITS);
}

/* §5f.8 arming: waits -(tap)-> armed -(shake | tap)-> shuffle; back on armed disarms; armed idles to waits; the
 * draw (POST /oracle/draw) deals from waits and armed. */
static void test_arming(void)
{
    or_t o;
    or_draw_t d;
    or_config_t c = cfg_of(22, 0, 0, 10000);
    or_init(&o, &c, 11);
    or_step(&o, 0, 0.0f, false, &d);
    CHECK(!or_step(&o, 10, 1.5f, false, &d));  /* a shake on waits does nothing */
    CHECK_EQ(o.phase, OR_WAITS);
    CHECK_EQ(o.draws, 0u);
    CHECK(or_step(&o, 10, 0.0f, true, &d));    /* a tap arms */
    CHECK_EQ(o.phase, OR_ARMED);
    CHECK(slot_draw(&d, OR_TEXT_ARMED_FRAME, 0));
    CHECK(!or_draw_black(&d));
    CHECK(!strcmp(or_state_str(&o), "armed"));
    CHECK(or_in_draw(&o));
    int t[3];
    or_status_three(&o, t);
    CHECK(t[0] == -1 && t[1] == -1 && t[2] == -1);
    CHECK_EQ(or_status_card(&o), -1);
    CHECK_EQ(or_status_page(&o), -1);
    CHECK(!or_animating(&o));
    CHECK_EQ(or_next_ms(&o), 10000u);         /* only the idle timeout */
    CHECK(or_step(&o, 10, 1.0f, false, &d));   /* a shake deals */
    CHECK_EQ(o.phase, OR_SHUFFLE);
    CHECK_EQ(o.draws, 1u);
    CHECK(or_draw_black(&d) && d.n == 3);
    /* disarm: a back on armed -> waits (true); a back on waits does nothing */
    or_init(&o, &c, 12);
    or_turn(&o);
    CHECK(or_back(&o));
    CHECK_EQ(o.phase, OR_WAITS);
    CHECK(!or_in_draw(&o));
    CHECK(!or_back(&o));
    /* armed idles to waits after hold_ms; a tap restarts nothing more than its own screen */
    or_turn(&o);
    run(&o, 9990, 10, &d);
    CHECK_EQ(o.phase, OR_ARMED);
    run(&o, 10, 10, &d);
    CHECK_EQ(o.phase, OR_WAITS);
    CHECK(slot_draw(&d, 0, 0));
    /* hold_ms 0: armed waits for ever */
    c.hold_ms = 0;
    or_init(&o, &c, 13);
    or_turn(&o);
    CHECK_EQ(or_next_ms(&o), UINT32_MAX);
    CHECK_EQ(run(&o, 3600000, 60000, &d), 1);  /* (the first step reports the armed screen) */
    CHECK_EQ(o.phase, OR_ARMED);
    /* a shake and a tap in the same step on armed: one draw */
    or_step(&o, 10, 1.2f, true, &d);
    CHECK_EQ(o.phase, OR_SHUFFLE);
    CHECK_EQ(o.draws, 1u);
    /* a shake held from waits: tapped to armed while still shaking, no deal until a new edge */
    or_init(&o, &c, 14);
    or_step(&o, 10, 1.2f, false, &d);          /* shaking on waits: ignored, the edge used up */
    or_step(&o, 10, 1.2f, true, &d);           /* still shaking + a tap: armed */
    CHECK_EQ(o.phase, OR_ARMED);
    or_step(&o, 10, 1.2f, false, &d);          /* the same shake: no new edge */
    CHECK_EQ(o.phase, OR_ARMED);
    or_step(&o, 10, 0.3f, false, &d);          /* below shake_g / 2: ready */
    or_step(&o, 10, 0.95f, false, &d);         /* a new shake deals */
    CHECK_EQ(o.phase, OR_SHUFFLE);
    /* POST /oracle/draw deals from waits and from armed */
    or_init(&o, &c, 15);
    CHECK(or_trigger(&o, NULL));
    CHECK_EQ(o.phase, OR_SHUFFLE);
    or_init(&o, &c, 16);
    or_turn(&o);
    const int row[3] = { 3, 1, 2 };
    CHECK(or_trigger(&o, row));
    CHECK_EQ(o.phase, OR_SHUFFLE);
    run(&o, OR_SHUFFLE_MS, 50, &d);
    CHECK(o.phase == OR_THREE && o.three[0] == 3 && o.three[1] == 1 && o.three[2] == 2);
}

/* §5f.8 the shake gate: from the shuffle through hold a shake does nothing (no re-draw mid-reading); the only way to
 * a new draw by hand is back to waits, a tap, a shake. A press in the same step as an ignored shake still counts. */
static void test_shake(void)
{
    or_t o;
    or_draw_t d;
    or_config_t c = cfg_of(22, 0, 0, 0);
    c.card_detail[1] = c.card_detail[2] = c.card_detail[3] = true;
    or_init(&o, &c, 6);
    or_turn(&o);
    or_step(&o, 10, 0.95f, false, &d);         /* armed + shake: one draw */
    CHECK_EQ(o.phase, OR_SHUFFLE);
    CHECK_EQ(o.draws, 1u);
    for (int i = 0; i < 20; i++) {             /* shakes during the shuffle: nothing */
        or_step(&o, 10, (i & 1) ? 0.0f : 1.5f, false, &d);
        CHECK_EQ(o.draws, 1u);
    }
    run(&o, OR_SHUFFLE_MS, 50, &d);
    CHECK_EQ(o.phase, OR_THREE);
    const int16_t abc[3] = { o.three[0], o.three[1], o.three[2] };
    const bool every[5] = { true, true, true, true, true };
    /* every screen of the reading: a fresh shake edge (low, then high) changes nothing */
    for (int k = 0; k < 12 && o.phase != OR_WAITS; k++) {
        const or_phase_t ph = o.phase;
        const int8_t sc = o.screen;
        or_step(&o, 10, 0.0f, false, &d);
        CHECK(!or_step(&o, 10, 2.0f, false, &d));
        CHECK(o.phase == ph && o.screen == sc && o.draws == 1u);
        CHECK(o.three[0] == abc[0] && o.three[1] == abc[1] && o.three[2] == abc[2]);
        or_step(&o, 10, 0.0f, true, &d);       /* the tap goes on */
        if (o.phase == OR_LEAN && o.lean[0] < 0) or_lean_screens(&o, every);
    }
    CHECK_EQ(o.phase, OR_WAITS);               /* three, 5 lean, 3 details, hold, then waits */
    /* a shake and a tap together mid-reading: the tap counts, the shake does not */
    to_three(&o, NULL);
    CHECK_EQ(o.draws, 2u);
    or_step(&o, 10, 0.0f, false, &d);
    or_step(&o, 10, 1.5f, true, &d);
    CHECK_EQ(o.phase, OR_LEAN);
    CHECK_EQ(o.draws, 2u);
    /* the way to a new draw: back to waits, tap, shake */
    while (o.phase != OR_WAITS) or_back(&o);
    or_step(&o, 10, 0.0f, true, &d);
    CHECK_EQ(o.phase, OR_ARMED);
    or_step(&o, 10, 1.5f, false, &d);
    CHECK_EQ(o.phase, OR_SHUFFLE);
    CHECK_EQ(o.draws, 3u);
    CHECK_EQ(o.lean[0], -1);
    /* an ignored shake does not reset the idle timeout */
    c.hold_ms = 5000;
    or_init(&o, &c, 7);
    to_three(&o, NULL);
    for (int i = 0; i < 60; i++) or_step(&o, 100, (i & 1) ? 0.0f : 1.5f, false, &d);
    CHECK_EQ(o.phase, OR_WAITS);
    /* POST /oracle/draw still deals mid-reading (the person at the phone chose it), also during a shuffle */
    to_three(&o, NULL);
    or_turn(&o);
    CHECK(or_trigger(&o, NULL));
    CHECK_EQ(o.phase, OR_SHUFFLE);
    const uint32_t n = o.draws;
    or_step(&o, 300, 0.0f, false, &d);
    or_trigger(&o, NULL);
    CHECK_EQ(o.draws, n + 1);
    CHECK_EQ(o.t_ms, 0u);
}

/* Every draw: three distinct cards, never the previous draw's set; uniform over slots; forced rows. */
static void test_draws(void)
{
    or_t o;
    or_config_t c = cfg_of(22, 0, 0, 0);
    or_init(&o, &c, 0xC0FFEEu);
    static uint32_t hist[3][OR_MAX_CARDS];
    memset(hist, 0, sizeof hist);
    int16_t prev[3] = { -1, -1, -1 };
    const int N = 20000;
    for (int i = 0; i < N; i++) {
        to_three(&o, NULL);
        CHECK_EQ(o.phase, OR_THREE);
        const int16_t *t = o.three;
        CHECK(t[0] != t[1] && t[1] != t[2] && t[0] != t[2]);
        for (int s = 0; s < 3; s++) CHECK(t[s] >= 0 && t[s] < 22);
        if (prev[0] >= 0) {
            int same = 0;
            for (int s = 0; s < 3; s++) same += t[s] == prev[0] || t[s] == prev[1] || t[s] == prev[2];
            CHECK(same < 3);
        }
        for (int s = 0; s < 3; s++) {
            hist[s][t[s]]++;
            prev[s] = t[s];
        }
    }
    const double expect = (double)N / 22;
    for (int s = 0; s < 3; s++)
        for (int k = 0; k < 22; k++) CHECK(hist[s][k] > expect * 0.8 && hist[s][k] < expect * 1.2);
    /* 4 cards: the next set always differs; 3 cards: the only set */
    c.cards = 4;
    or_init(&o, &c, 2);
    for (int i = 0; i < 200; i++) {
        int16_t p[3] = { o.three[0], o.three[1], o.three[2] };
        to_three(&o, NULL);
        if (i) {
            int same = 0;
            for (int s = 0; s < 3; s++) same += o.three[s] == p[0] || o.three[s] == p[1] || o.three[s] == p[2];
            CHECK(same < 3);
        }
    }
    c.cards = 3;
    or_init(&o, &c, 2);
    for (int i = 0; i < 20; i++) {
        to_three(&o, NULL);
        CHECK_EQ(o.three[0] + o.three[1] + o.three[2], 3);
    }
    /* forced rows: any three distinct valid cards (also the previous set); bad rows refused */
    c.cards = 22;
    or_init(&o, &c, 3);
    const int f1[3] = { 5, 6, 7 }, bad1[3] = { 5, 5, 7 }, bad2[3] = { 5, 6, 22 }, bad3[3] = { -1, 6, 7 };
    CHECK(or_trigger(&o, f1));
    run(&o, OR_SHUFFLE_MS, 100, NULL);
    CHECK(o.three[0] == 5 && o.three[1] == 6 && o.three[2] == 7);
    CHECK(or_trigger(&o, f1));
    CHECK(!or_trigger(&o, bad1));
    CHECK(!or_trigger(&o, bad2));
    CHECK(!or_trigger(&o, bad3));
    /* the picker alone */
    uint32_t rng = 9;
    int16_t out[3];
    const int16_t pv[3] = { 0, 1, 2 };
    for (int i = 0; i < 5000; i++) {
        or_pick_three(4, pv, &rng, out);
        CHECK(out[0] != out[1] && out[1] != out[2] && out[0] != out[2]);
        CHECK(!((out[0] <= 2) && (out[1] <= 2) && (out[2] <= 2)));
    }
}

static void test_draw_diff(void)
{
    or_draw_t w = { 0 }, x;
    w.n = 2;
    w.op[0] = (or_op_t){ OR_ASSET_TEXT, 0, 0, 0 };
    w.op[1] = (or_op_t){ OR_ASSET_DECK, 0, OR_BACK_X_UP, 0 };
    x = w;
    CHECK_EQ(or_draw_diff(&w, &x), 0);
    x.op[1].frame = 5;
    CHECK_EQ(or_draw_diff(&w, &x), 2);
    x.op[0].frame = 3;
    CHECK_EQ(or_draw_diff(&w, &x), -1);
    or_draw_t t3 = { 0 };
    t3.n = 3;
    for (int s = 0; s < 3; s++) t3.op[s] = (or_op_t){ OR_ASSET_DECK, (uint16_t)(1 + s), or_three_x[s], 0 };
    CHECK(or_draw_black(&t3));
    CHECK_EQ(or_draw_diff(&w, &t3), -1);
    or_draw_t t4 = t3;
    t4.op[0].frame = 9;
    t4.op[2].frame = 7;
    CHECK_EQ(or_draw_diff(&t3, &t4), 1 | 4);
    or_draw_t nt = t3;
    for (int s = 0; s < 3; s++) nt.op[s] = (or_op_t){ OR_ASSET_NOTES, (uint16_t)s, 0, (int16_t)(12 + 72 * s) };
    CHECK_EQ(or_draw_diff(&t3, &nt), -1);       /* same count, another layout */
    or_draw_t empty = { 0 };
    CHECK(or_draw_black(&empty));
}

/* Determinism: the same seed and inputs give the same draws. */
static void test_determinism(void)
{
    or_config_t c = cfg_of(22, 0, 0, 0);
    or_t a, b;
    or_init(&a, &c, 31337);
    or_init(&b, &c, 31337);
    for (int i = 0; i < 50; i++) {
        to_three(&a, NULL);
        to_three(&b, NULL);
        CHECK(a.three[0] == b.three[0] && a.three[1] == b.three[1] && a.three[2] == b.three[2]);
    }
}

static double s_card_stream_us;   /* bench_decode(card): the same frame read from a file in 4 KB chunks, then decoded */

static double bench_decode(const char *name, uint16_t w, uint16_t h, bool card)
{
    static uint16_t px[536 * 240], fb[536 * 240];
    static uint8_t enc[536 * 240 * 2 + 64];
    const size_t npx = (size_t)w * h;
    th_rng = 2026;
    const uint16_t bg = th_be(0x18C3), ink = th_be(0xEF5D);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint16_t v = bg;
            if (card) {                                  /* paper, woodcut strokes, a figure, some noise */
                const uint32_t r = th_rand();
                v = th_be(0xE6B5);
                if ((x * 7 + y * 3) % 37 < 2 || (x - 52) * (x - 52) + (y - 90) * (y - 90) < 900) v = th_be(0x2104);
                if ((r & 15) == 0) v = th_be((uint16_t)(0xC618 + (r >> 16 & 7)));
            } else if (x >= 180 && x < 500 && ((y >= 40 && y < 70) || (y >= 100 && y < 112) || (y >= 130 && y < 142))) {
                v = ((x / 7 + y / 6) % 3 == 0) ? ink : bg;   /* text-like bars right of the blank slot */
            }
            px[y * w + x] = v;
        }
    const size_t n = hca_rle16_encode(px, npx, enc, sizeof enc);
    CHECK(n > 0);
    hca_header_t hdr = { w, h, 1, 0, HCA_COMP_RLE16, 0, 0, 32, 0 };
    CHECK(hca_decode_frame_from(&hdr, enc, n, fb, 536) == HCA_OK);
    for (int y = 0; y < h; y++) CHECK(memcmp(px + y * w, fb + y * 536, (size_t)w * 2) == 0);
    const int N = 400;
    clock_t c0 = clock();
    for (int i = 0; i < N; i++) (void)hca_decode_frame_from(&hdr, enc, n, fb, 536);
    const double us = (double)(clock() - c0) * 1e6 / CLOCKS_PER_SEC / N;
    printf("     bench %-18s %3ux%3u: %6zu B RLE16 (%4.1f%% of raw), decode %5.1f us (host)\n", name, w, h, n,
           100.0 * (double)n / (npx * 2), us);
    if (card) {
        /* the firmware without the deck cache: seek + 4 KB unbuffered reads of the frame from its file, then the decode
         * (storage_frame_stream interleaves them; the host's page cache makes the reads cheap, flash does not) */
        FILE *f = tmpfile();
        CHECK(f != NULL);
        if (f) {
            for (int k = 0; k < 8; k++) fwrite(enc, 1, n, f);   /* a little deck: 8 copies */
            fflush(f);
            setvbuf(f, NULL, _IONBF, 0);
            static uint8_t buf[536 * 240 * 2 + 64];
            c0 = clock();
            for (int i = 0; i < N; i++) {
                fseek(f, (long)((size_t)(i % 8) * n), SEEK_SET);
                size_t got = 0;
                while (got < n) {
                    const size_t want = n - got < 4096 ? n - got : 4096;
                    const size_t r = fread(buf + got, 1, want, f);
                    if (!r) break;
                    got += r;
                }
                (void)hca_decode_frame_from(&hdr, buf, got, fb, 536);
            }
            s_card_stream_us = (double)(clock() - c0) * 1e6 / CLOCKS_PER_SEC / N;
            fclose(f);
        }
    }
    return us;
}

static void bench_frames(void)
{
    const double t = bench_decode("text frame", 536, 240, false);   /* (the old text asset T; kept as a reference) */
    const double c = bench_decode("card (deck frame)", 104, 198, true);
    printf("     shuffle frame (1 card) %.1f us, three-card shuffle frame %.1f us; budget 83333 us (host)\n", c, 3 * c);
    printf("     three-card shuffle frame decode: streamed from a file %.1f us, from the PSRAM deck cache %.1f us (host)\n",
           3 * s_card_stream_us, 3 * c);
    CHECK(t + 3 * c < 83333.0);
}

int main(void)
{
    RUN(test_frame_math);
    RUN(test_init_waits);
    RUN(test_shuffle);
    RUN(test_screens);
    RUN(test_flip);
    RUN(test_timers);
    RUN(test_arming);
    RUN(test_shake);
    RUN(test_draws);
    RUN(test_draw_diff);
    RUN(test_determinism);
    RUN(bench_frames);
    return TH_DONE("test_oracle");
}
