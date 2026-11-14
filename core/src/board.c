/* board.c — timed rows that scroll (see include/board.h, PROTOCOL §5g). */
#include "board.h"

#include <string.h>

board_status_t board_init(board_t *b, const uint16_t *const frames[], int n, uint16_t fw, uint16_t fh,
                          const board_row_t *rows, int nrows, int header, int empty, int speed, uint16_t sw, uint16_t sh)
{
    if (!b) return BOARD_ERR_ARG;
    memset(b, 0, sizeof *b);
    if (!frames || n < 1 || n > BOARD_MAX_FRAMES || !sw || !sh || fw < 1 || fw > sw || fw > BOARD_MAX_W ||
        fh < BOARD_MIN_H || fh > sh || fh > BOARD_MAX_H || (uint64_t)n * fw * fh > BOARD_MAX_PX || !rows || nrows < 1 ||
        nrows > BOARD_MAX_ROWS || header < -1 || header >= n || empty < -1 || empty >= n) {
        return BOARD_ERR_ARG;
    }
    for (int i = 0; i < n; i++) {
        if (!frames[i]) return BOARD_ERR_ARG;
        b->frames[i] = frames[i];
    }
    for (int i = 0; i < nrows; i++) {
        if (rows[i].frame >= n) return BOARD_ERR_ARG;
        b->rows[i] = rows[i];
    }
    b->nframes = (uint8_t)n;
    b->nrows = (uint8_t)nrows;
    b->fw = fw;
    b->fh = fh;
    b->sw = sw;
    b->sh = sh;
    b->header = (int8_t)header;
    b->empty = (int8_t)empty;
    b->speed = (uint16_t)(speed == 0 ? BOARD_SPEED_DEF : speed < BOARD_SPEED_MIN ? BOARD_SPEED_MIN
                                                      : speed > BOARD_SPEED_MAX ? BOARD_SPEED_MAX : speed);
    b->drawn_offset = -1;
    b->need_full = true;
    /* until the clock is told: every row */
    board_set_clock(b, 0, false);
    return BOARD_OK;
}

int board_top(const board_t *b) { return b->header >= 0 ? b->fh : 0; }

static int area_h(const board_t *b)
{
    const int a = (int)b->sh - board_top(b);
    return a > 0 ? a : 0;
}

int board_stack_h(const board_t *b)
{
    if (b->nshown) return (int)b->nshown * b->fh;
    return b->empty >= 0 ? b->fh : 0;
}

int board_period(const board_t *b) { return b->scrolling ? (int)b->nshown * b->fh + BOARD_GAP : 0; }

/* The row set the clock asks for (all while it is not synced). */
static void want_of(board_t *b)
{
    b->nwant = 0;
    for (uint8_t i = 0; i < b->nrows; i++) {
        const board_row_t *r = &b->rows[i];
        if (!b->clock_ok || !r->has_until || b->now < r->until) b->want[b->nwant++] = i;
    }
}

static bool same_set(const board_t *b)
{
    return b->nwant == b->nshown && memcmp(b->want, b->shown, b->nshown) == 0;
}

/* Take the wanted set: scrolling or static from its height; a list that (re)starts scrolling starts at its top. */
static void apply(board_t *b)
{
    const bool was = b->scrolling;
    memcpy(b->shown, b->want, b->nwant);
    b->nshown = b->nwant;
    b->scrolling = b->nshown && (int)b->nshown * b->fh > area_h(b);
    if (!b->scrolling || !was) b->offset_m = 0;
    b->pending = false;
    b->need_full = true;
}

bool board_set_clock(board_t *b, int64_t now, bool clock_ok)
{
    if (!b || !b->nrows) return false;
    b->now = now;
    b->clock_ok = clock_ok;
    want_of(b);
    if (same_set(b)) {
        b->pending = false;
        return false;
    }
    if (!b->scrolling) {   /* static (or the first call): at once */
        apply(b);
        return true;
    }
    b->pending = true;     /* scrolling: at the next loop boundary */
    return false;
}

bool board_step(board_t *b, uint32_t dt_ms)
{
    if (!b || !b->nrows) return false;
    bool changed = b->need_full;
    if (!b->scrolling) return changed;
    b->offset_m += (uint64_t)b->speed * dt_ms;   /* px/s x ms = 1/1000 px */
    for (int guard = 0; guard < 64 && b->scrolling; guard++) {
        const uint64_t p = (uint64_t)board_period(b) * 1000u;
        if (b->offset_m < p) break;
        b->offset_m -= p;
        b->loops++;
        if (b->pending) {
            const uint64_t rem = b->offset_m;
            apply(b);   /* (keeps the remainder only while it still scrolls) */
            if (b->scrolling) b->offset_m = rem;
            changed = true;
        }
    }
    if (b->scrolling) {   /* more than 64 periods in one step (a very long dt): fold, the render walks offset / period */
        const uint64_t p = (uint64_t)board_period(b) * 1000u;
        if (b->offset_m >= p) {
            b->loops += (uint32_t)(b->offset_m / p);
            b->offset_m %= p;
        }
    }
    return changed || (int)(b->offset_m / 1000u) != b->drawn_offset;
}

void board_invalidate(board_t *b)
{
    if (b) b->need_full = true;
}

uint32_t board_next_ms(const board_t *b) { return b && b->scrolling ? BOARD_FRAME_MS : UINT32_MAX; }

/* Copy frame f with its top-left at (x, y), rows clipped to [y0, y1) and columns to [0, fb_w). */
static void blit(const board_t *b, int f, int x, int y, int y0, int y1, uint16_t *fb, uint16_t fb_w)
{
    if (f < 0 || f >= b->nframes) return;
    int c0 = 0, c1 = b->fw;
    if (x + c0 < 0) c0 = -x;
    if (x + c1 > fb_w) c1 = fb_w - x;
    if (c0 >= c1) return;
    for (int r = 0; r < b->fh; r++) {
        const int yy = y + r;
        if (yy < y0) continue;
        if (yy >= y1) break;
        memcpy(fb + (size_t)yy * fb_w + x + c0, b->frames[f] + (size_t)r * b->fw + c0, (size_t)(c1 - c0) * 2u);
    }
}

void board_render(board_t *b, uint16_t *fb, uint16_t fb_w, uint16_t fb_h, board_rect_t *dirty)
{
    if (dirty) memset(dirty, 0, sizeof *dirty);
    if (!b || !b->nrows || !fb || !fb_w || !fb_h) return;
    const int W = b->sw < fb_w ? b->sw : fb_w, H = b->sh < fb_h ? b->sh : fb_h;
    const int x0 = ((int)b->sw - (int)b->fw) / 2, top = board_top(b) < H ? board_top(b) : H;
    const int off = (int)(b->offset_m / 1000u);
    if (!b->need_full && off == b->drawn_offset) return;   /* nothing moved */
    int dx0 = x0, dy0 = top, dx1 = x0 + b->fw, dy1 = H;
    if (b->need_full) {
        for (int y = 0; y < H; y++) memset(fb + (size_t)y * fb_w, 0, (size_t)W * 2u);
        if (b->header >= 0) blit(b, b->header, x0, 0, 0, H, fb, fb_w);
        dx0 = 0;
        dy0 = 0;
        dx1 = W;
    } else {
        for (int y = top; y < H; y++) {
            const int c0 = x0 < 0 ? 0 : x0, c1 = x0 + b->fw > W ? W : x0 + b->fw;
            if (c1 > c0) memset(fb + (size_t)y * fb_w + c0, 0, (size_t)(c1 - c0) * 2u);
        }
    }
    if (!b->nshown) {
        if (b->empty >= 0) blit(b, b->empty, x0, top, top, H, fb, fb_w);
    } else if (!b->scrolling) {
        for (int i = 0; i < b->nshown; i++) blit(b, b->rows[b->shown[i]].frame, x0, top + i * b->fh, top, H, fb, fb_w);
    } else {
        const int p = board_period(b);
        for (int y = top - off; y < H; y += p)
            for (int i = 0; i < b->nshown; i++) blit(b, b->rows[b->shown[i]].frame, x0, y + i * b->fh, top, H, fb, fb_w);
    }
    if (dx0 < 0) dx0 = 0;
    if (dx1 > W) dx1 = W;
    if (dirty && dx1 > dx0 && dy1 > dy0) {
        dirty->x = (int16_t)dx0;
        dirty->y = (int16_t)dy0;
        dirty->w = (int16_t)(dx1 - dx0);
        dirty->h = (int16_t)(dy1 - dy0);
    }
    b->drawn_offset = off;
    b->need_full = false;
}
