/* board.h — a board: a list of timed row pictures that scrolls (docs/PROTOCOL.md §5g).
 *
 * C11, no allocation, no I/O, no libm. The caller owns the decoded sheet (frames of fw x fh RGB565BE pixels, opaque)
 * and the framebuffer; this module decides which rows show and where, and paints them.
 *
 *   board_t b;
 *   board_init(&b, frames, n, fw, fh, rows, nrows, header, empty, scroll_px_s, 536, 240);
 *   board_set_clock(&b, now_unix, clock_ok);        // at start and once a second: the row set (until filter)
 *   if (board_step(&b, dt_ms)) board_render(&b, fb, 536, 240, &dirty);   // <= 30 fps while scrolling
 *   wake_in = board_next_ms(&b);                    // 33 while scrolling, UINT32_MAX when static
 *
 * Rows: `frame` and an optional `until` (unix seconds): shown while the clock is before `until`, always without one;
 * every row while the clock is not synced. Layout: the header frame (optional) fixed at y 0; below it the shown rows
 * stacked with no gap, centred horizontally (x = (screen_w - fw) / 2); no row left -> the `empty` frame alone (or
 * nothing). When the stack is taller than the space under the header it scrolls up continuously at scroll_px_s px/s,
 * looping with BOARD_GAP px of black between the end and the start; otherwise it is static from the top. A change of
 * the row set while scrolling waits for the next loop boundary (static: at once). Deterministic: integer arithmetic
 * (the offset in 1/1000 px).
 */
#ifndef BOARD_H
#define BOARD_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BOARD_MAX_FRAMES  48
#define BOARD_MAX_ROWS    47
#define BOARD_MAX_PX      1048576u   /* N * w * h */
#define BOARD_MIN_H       16
#define BOARD_MAX_W       536
#define BOARD_MAX_H       240
#define BOARD_GAP         48         /* px of black between the end of the list and its start again */
#define BOARD_SPEED_MIN   4
#define BOARD_SPEED_MAX   60
#define BOARD_SPEED_DEF   16
#define BOARD_FRAME_MS    33         /* <= 30 fps while scrolling */

typedef struct {
    uint8_t frame;       /* 0..n-1 */
    bool has_until;
    int64_t until;       /* unix seconds: shown while now < until */
} board_row_t;

typedef struct { int16_t x, y, w, h; } board_rect_t;   /* w == 0: nothing changed */

typedef enum { BOARD_OK = 0, BOARD_ERR_ARG } board_status_t;

typedef struct {
    /* configuration */
    const uint16_t *frames[BOARD_MAX_FRAMES];
    uint16_t fw, fh, sw, sh;
    uint8_t nframes, nrows;
    int8_t header, empty;            /* frame or -1 */
    uint16_t speed;                  /* px/s */
    board_row_t rows[BOARD_MAX_ROWS];
    /* state */
    int64_t now;
    bool clock_ok, clock_known;
    uint8_t shown[BOARD_MAX_ROWS];   /* row indices of the shown set, in order */
    uint8_t nshown;
    uint8_t want[BOARD_MAX_ROWS];    /* the set the clock asks for (applied at once, or at the loop boundary) */
    uint8_t nwant;
    bool pending;                    /* want differs from shown, waiting for the loop boundary */
    bool scrolling;
    uint64_t offset_m;               /* scroll offset in 1/1000 px, within [0, period) */
    int drawn_offset;                /* the offset of the last render (px), -1 = none */
    bool need_full;
    uint32_t loops;                  /* loop boundaries crossed (stats / tests) */
} board_t;

/* Validate and set up (frames[0..n) non-NULL, 1 <= n <= BOARD_MAX_FRAMES, 1 <= fw <= sw, BOARD_MIN_H <= fh <= sh,
 * n*fw*fh <= BOARD_MAX_PX, 1 <= nrows <= BOARD_MAX_ROWS with every frame < n, header / empty -1 or < n, speed clamped
 * to 4..60 (0 = the default 16)). Until board_set_clock, every row shows (as with an unsynced clock). */
board_status_t board_init(board_t *b, const uint16_t *const frames[], int n, uint16_t fw, uint16_t fh,
                          const board_row_t *rows, int nrows, int header, int empty, int speed, uint16_t sw, uint16_t sh);

/* The clock (call at start and once a second): recomputes the row set; applied at once when the board is static (or
 * becomes so), at the next loop boundary while it scrolls. Returns true when the screen must be repainted now. */
bool board_set_clock(board_t *b, int64_t now, bool clock_ok);

/* Advance the scroll by dt_ms (no-op when static). At a loop boundary a pending row set is applied. Returns true when
 * the next render differs (the integer offset moved, or the set changed). */
bool board_step(board_t *b, uint32_t dt_ms);

/* Paint into fb (RGB565BE, fb_w x fb_h, the board's sw x sh at the top-left). The first render (and after
 * board_invalidate) clears the whole screen; then only the rows' column below the header is repainted. */
void board_render(board_t *b, uint16_t *fb, uint16_t fb_w, uint16_t fb_h, board_rect_t *dirty);
void board_invalidate(board_t *b);

/* ms until board_step can change something by time: BOARD_FRAME_MS while scrolling, UINT32_MAX when static. */
uint32_t board_next_ms(const board_t *b);

/* Layout facts (tests, logs): the y where rows start (the header's height or 0), the stack's height (rows, or the
 * empty frame), the loop period (stack + BOARD_GAP) when scrolling, else 0. */
int board_top(const board_t *b);
int board_stack_h(const board_t *b);
int board_period(const board_t *b);

#ifdef __cplusplus
}
#endif
#endif /* BOARD_H */
