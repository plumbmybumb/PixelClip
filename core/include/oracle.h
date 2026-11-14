/* oracle.h — Oracle (tarot): three cards read for the person's question, the lean draw (docs/PROTOCOL.md §5f, §5f.3,
 * §5f.6, §5f.7, §5f.8, §5f.10, §5f.11, §5f.12).
 *
 * C11, no allocation, no I/O, no libm. The firmware owns the assets, the bundle and the display; this module decides
 * what is on screen at every instant and describes it as a short list of paste operations: whole frames of the atlases
 * at fixed positions and "text screens" the caller draws from the reader bundle (oracle_text.h), painted in order onto a
 * black ground (or onto a full text screen). No blending.
 *
 * Assets (PROTOCOL §5f, §5f.12): D deck 108x206, 1 + cards frames (0 = the back, 1 + i = card i); K keys 160x34,
 * cards frames (card i's keyword), optional (cfg.keys: absent -> no keyword row). The notes N are no longer used (§5f.7). A TEXT op (asset OR_ASSET_TEXT) is a text screen the
 * caller draws on black; or_text_screen() decodes its frame.
 *
 * §5f.12 geometry: the three (and the shuffle slots) at y 0, x 52 / 214 / 376 in both orientations, their keys at y
 * 206, x 26 / 188 / 350; the back (waits / armed) and the detail card at y 17, at the end away from the BOOT corner:
 * x 8 normally, 420 flipped (or_set_flipped). The corner arrow and the text boxes are oracle_text.h's.
 *
 * §5f.6 / §5f.7: one reading, at most 11 one-page screens, paged by hand:
 *   WAITS     [waits]    TEXT 0 (the prompt) + D[0] (the back) at (or_back_x, OR_BACK_Y): x 8 normally, 420 flipped
 *                        (the end away from the button), y 17. A tap -> ARMED; a shake does nothing (§5f.8); or_trigger() deals.
 *                        Back: nothing (the floor).
 *   ARMED     [armed]    TEXT OR_TEXT_ARMED_FRAME (the armed prompt) + D[0] as on WAITS. A shake or a tap deals
 *                        (-> SHUFFLE); a back disarms (-> WAITS); the idle timeout -> WAITS.
 *   SHUFFLE   [shuffle]  black + random D cards in the three card slots (or_three_x: 52/214/376, y 0; no keys), 12
 *                        fps for OR_SHUFFLE_MS:
 *                        shuffle frame k = floor(t x 12/1000) shows a random card per slot (never that slot's previous
 *                        shuffle card nor its chosen one), from k = OR_SHUFFLE_FRAMES (1166.7 ms) the chosen A, B, C.
 *                        Then THREE. Taps and backs do nothing during a shuffle.
 *   THREE     [three]    black + D[1+A], D[1+B], D[1+C] in the slots + K[A], K[B], K[C] under them (§5f.12; when
 *                        cfg.keys).
 *   LEAN      [lean]     screens 0 by card, 1 by position, 2 by the numbers, 3 together, 4 and (oracle_reader.h
 *                        orr_compose_lean): a TEXT op of frame OR_TEXT_LEAN_FRAME + screen. or_lean_screens() says
 *                        which have text once the caller has composed them (absent = skipped both ways; not told yet
 *                        = screen 0 provisionally).
 *   DETAIL    [detail]   card A, B, C in turn (screen 0..2): TEXT or_text_detail(card) (its brief) + D[1+card] at
 *                        (or_back_x, 0) when the brief fits beside it (cfg.card_beside; else the brief alone, full
 *                        width like the lean screens); a card without a brief (cfg.card_detail) is skipped.
 *   HOLD      [hold]     the THREE frame again. A tap -> WAITS.
 * or_turn() (a tap) is the next screen, or_back() (a double tap) the previous one (WAITS is the floor; THREE -> WAITS).
 * face_ms (THREE) and page_ms (each lean / detail screen) advance by themselves only when non-zero (default 0). hold_ms
 * is the idle timeout: no turn, back, draw or shake for that long returns any screen to WAITS (default 300 000; 0 =
 * never). A shake (metric >= shake_g, edge-triggered: ready again once the metric is below shake_g / 2) deals only on
 * ARMED, where it wins over a press given in the same step; on every other screen it is ignored (§5f.8: no re-draw
 * mid-reading; the edge is used up all the same). or_trigger() (POST /oracle/draw) deals from any screen. Every draw:
 * A, B, C distinct, never the previous draw's set.
 * Randomness: a caller-seeded xorshift32 in or_t.
 */
#ifndef ORACLE_H
#define ORACLE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Constants (PROTOCOL §5f) ----------------------------------------------------------------- */

#define OR_MAX_CARDS        78
#define OR_MIN_CARDS        3        /* three distinct cards (§5f.6) */
#define OR_LEAN_SCREENS     5        /* by card, by position, by the numbers, together, and (§5f.7) */
#define OR_SHAKE_G_MIN      0.4f
#define OR_SHAKE_G_MAX      2.0f
#define OR_SHAKE_G_DEF      0.9f
#define OR_FACE_DEF_MS      0u       /* §5f.3: nothing advances by itself unless asked */
#define OR_PAGE_DEF_MS      0u
#define OR_HOLD_DEF_MS      300000u  /* the idle timeout back to WAITS */
#define OR_SHUFFLE_MS       1200u
#define OR_SHUFFLE_FPS      12u
#define OR_SHUFFLE_FRAMES   14u      /* random cards k = 0..13 (83.3 ms each), then the chosen ones */
#define OR_TEXT_LEAN_FRAME  0xE000u  /* TEXT op frames: lean screen s = + s */
#define OR_TEXT_ARMED_FRAME 0xD000u  /* TEXT op frame of the armed prompt (§5f.8) */

/* geometry */
#define OR_SCREEN_W   536
#define OR_SCREEN_H   240
#define OR_CARD_W     108      /* §5f.12: 206 px tall everywhere (the keyword row fits under the three) */
#define OR_CARD_H     206
#define OR_KEY_W      160      /* §5f.12: the keyword row (optional); the notes are no longer used */
#define OR_KEY_H      34
#define OR_NOTE_W     536
#define OR_NOTE_H     72
#define OR_CARD_Y     0        /* the three */
#define OR_KEYS_Y     206      /* their keys, right under them */
#define OR_BACK_Y     17       /* the back (waits / armed) and the detail card, vertically centred */
#define OR_BACK_X_UP   8       /* ... at the end away from the BOOT corner */
#define OR_BACK_X_FLIP 420
extern const int16_t or_three_x[3];        /* §5f.12: 52, 214, 376 (54 px gaps, both orientations) */
extern const int16_t or_keys_x[3];         /* 26, 188, 350 (centred under the cards: centres 106, 268, 430) */
/* §5f.12 each keyword's ink box: 140x28 at offset (10, 2) in its 160x34 tile (rows 208..235); the app renders every
 * keyword at one size so that the longest fits it. */
#define OR_KEY_INK_X  10
#define OR_KEY_INK_Y  2
#define OR_KEY_INK_W  140
#define OR_KEY_INK_H  28

typedef enum {
    OR_WAITS = 0,
    OR_SHUFFLE,     /* the three cards */
    OR_THREE,
    OR_LEAN,        /* the five lean screens (§5f.7) */
    OR_DETAIL,      /* one page per card */
    OR_HOLD,
    OR_ARMED,       /* §5f.8: tapped on WAITS, a shake (or a tap) deals */
} or_phase_t;

/* The assets of an item: TEXT = the text screens the caller draws (no asset since §5f.2); NOTES unused since §5f.7. */
typedef enum { OR_ASSET_TEXT = 0, OR_ASSET_DECK, OR_ASSET_KEYS, OR_ASSET_NOTES, OR_ASSETS } or_asset_t;

typedef struct {
    uint8_t asset;      /* or_asset_t */
    uint16_t frame;
    int16_t x, y;       /* top-left on the screen; the size is the asset's (or_asset_w/h) */
} or_op_t;

#define OR_MAX_OPS 7
/* A composed frame: ops painted in order. When op[0] is not a TEXT screen the ground is black: the painter clears the
 * screen first. */
typedef struct {
    uint8_t n;
    or_op_t op[OR_MAX_OPS];
} or_draw_t;

typedef struct {
    uint16_t cards;     /* OR_MIN_CARDS..OR_MAX_CARDS */
    float shake_g;      /* OR_SHAKE_G_MIN..OR_SHAKE_G_MAX */
    uint32_t face_ms;   /* THREE before turning by itself; 0 = only on a press */
    uint32_t page_ms;   /* per lean / detail screen; 0 = only on a press */
    uint32_t hold_ms;   /* idle timeout back to WAITS; 0 = never */
    bool card_detail[OR_MAX_CARDS];   /* card i has a detail screen (its brief) */
    bool card_beside[OR_MAX_CARDS];   /* §5f.10: card i's brief fits beside the card (else the detail is text only) */
    bool keys;                        /* §5f.12: the keyword row under the three (the item has a keys atlas) */
} or_config_t;

typedef struct or_s {
    or_config_t cfg;
    /* state */
    or_phase_t phase;
    uint32_t t_ms;      /* time in the current screen */
    uint32_t idle_ms;   /* since the last input (turn, back, draw, shake): the hold_ms idle timeout */
    int16_t three[3];   /* A, B, C of this draw, -1 = none yet */
    int16_t prev[3];    /* the previous draw's three (the next set differs), -1 = none */
    int8_t screen;      /* LEAN: 0..4; DETAIL: 0..2 = A, B, C */
    int8_t lean[OR_LEAN_SCREENS];   /* lean screens of this draw with text (or_lean_screens): 1 / 0, -1 = not told yet */
    int16_t shuf[3];    /* cards on screen during the shuffle's random frames, -1 = none yet */
    uint8_t shuf_k;     /* shuffle frame index of shuf[] */
    bool shake_ready;   /* a new shake edge (the metric went below shake_g / 2 since the last shake) */
    uint32_t rng;       /* xorshift32 state, never 0 */
    uint32_t draws;     /* draws since or_init */
    bool flipped;       /* §5f.9: the panel is flipped (the three sit higher, the hint band is at the bottom) */
    /* the draw reported last (or_step reports changes only) */
    or_draw_t drawn;
    bool have_drawn;
} or_t;

/* ---- frame math --------------------------------------------------------------------------------- */

static inline uint32_t or_deck_frames(uint16_t cards) { return 1u + cards; }
static inline uint16_t or_deck_card(uint16_t i) { return (uint16_t)(1u + i); }
/* TEXT frame of card i's detail screen (frame 0 = the waits prompt). */
static inline uint16_t or_text_detail(uint16_t i) { return (uint16_t)(1u + i); }
uint16_t or_asset_w(or_asset_t a);
uint16_t or_asset_h(or_asset_t a);

typedef enum { OR_TEXT_WAITS = 0, OR_TEXT_DETAIL, OR_TEXT_LEAN, OR_TEXT_ARMED } or_text_kind_t;
/* The text screen a TEXT op's frame names: the waits prompt; card *card's detail; lean screen *card (0..4); the armed
 * prompt. */
static inline or_text_kind_t or_text_screen(uint16_t frame, uint16_t *card)
{
    *card = 0;
    if (frame >= OR_TEXT_LEAN_FRAME) {
        *card = (uint16_t)(frame - OR_TEXT_LEAN_FRAME);
        return OR_TEXT_LEAN;
    }
    if (frame == OR_TEXT_ARMED_FRAME) return OR_TEXT_ARMED;
    if (frame == 0) return OR_TEXT_WAITS;
    *card = (uint16_t)(frame - 1u);
    return OR_TEXT_DETAIL;
}

/* ---- state machine ------------------------------------------------------------------------------ */

/* cfg values are clamped (cards 3..78, shake_g); seed 0 is replaced. Starts in WAITS (shake edge ready); the first
 * or_step() always reports a draw. */
void or_init(or_t *o, const or_config_t *cfg, uint32_t seed);

/* A draw now (POST /oracle/draw), from any screen (WAITS and ARMED included): SHUFFLE. `cards` forces the row (three distinct indices < cards),
 * NULL = random. Returns false (and does nothing) for a bad forced row. */
bool or_trigger(or_t *o, const int cards[3]);

/* A tap of BOOT / POST /oracle/turn: the next screen (WAITS -> ARMED, ARMED -> a draw, HOLD -> WAITS). Returns true
 * when it changed something (false during a shuffle). */
bool or_turn(or_t *o);
/* A double tap / POST /oracle/back: the previous screen (ARMED -> WAITS). False (nothing) in WAITS and during a
 * shuffle. */
bool or_back(or_t *o);

/* Which lean screens of this draw have text (absent = skipped both ways; told while screen 0 shows provisionally: moved
 * on to the next one that has text). */
bool or_lean_screens(or_t *o, const bool present[OR_LEAN_SCREENS]);

/* Advance by dt_ms with the current shake metric (g; 0 without an IMU) and a press that happened since the last step.
 * Writes the composed frame to *d and returns true when it differs from the previous report. */
bool or_step(or_t *o, uint32_t dt_ms, float shake, bool press, or_draw_t *d);

/* The panel's orientation (display_is_flipped): moves the back and the detail card (§5f.11); the next or_step reports
 * the change (a full repaint). */
void or_set_flipped(or_t *o, bool flipped);
static inline int or_back_x(const or_t *o) { return o->flipped ? OR_BACK_X_FLIP : OR_BACK_X_UP; }

/* The composed frame of the current state. */
void or_draw(const or_t *o, or_draw_t *d);

/* What changed from `prev` to `next`: -1 = repaint everything (another ground, or another number of ops), else a bit
 * mask of the ops of `next` to repaint (each over its own rectangle; 0 = nothing). */
int or_draw_diff(const or_draw_t *prev, const or_draw_t *next);
bool or_draw_black(const or_draw_t *d);   /* the ground is black (op[0] is not a TEXT screen) */

/* Milliseconds until or_step() can change something by time alone (next shuffle frame, a non-zero screen timer, the
 * idle timeout); UINT32_MAX when it only reacts to input. */
uint32_t or_next_ms(const or_t *o);

/* PROTOCOL §5f.6 /status.oracle */
const char *or_state_str(const or_t *o);   /* waits|armed|shuffle|three|lean|detail|hold */
/* A draw is in progress (§5f.8: any screen other than WAITS): the player defers rotation, queue, notes, windows. */
static inline bool or_in_draw(const or_t *o) { return o->phase != OR_WAITS; }
void or_status_three(const or_t *o, int out[3]);   /* cards_drawn: A, B, C from THREE on, else -1 */
int or_status_card(const or_t *o);         /* the detail card (DETAIL), else -1 */
int or_status_page(const or_t *o);         /* LEAN: the screen 0..4; DETAIL: 0..2; else -1 */
bool or_animating(const or_t *o);          /* a shuffle runs (12 fps) */

/* ---- pickers (pure) ----------------------------------------------------------------------------- */

/* Three distinct cards of `cards` (>= 3), never the set `prev` (any order; prev[0] < 0 = none) when cards > 3.
 * *rng: xorshift32 state. */
void or_pick_three(uint16_t cards, const int16_t prev[3], uint32_t *rng, int16_t out[3]);

#ifdef __cplusplus
}
#endif
#endif /* ORACLE_H */
