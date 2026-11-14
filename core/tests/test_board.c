/* test_board.c — the board (include/board.h, PROTOCOL §5g): validation, the until filter, the unsynced clock, static
 * vs scrolling layouts, the loop gap, header and empty, expiry at the loop boundary (static: at once), dirty rects,
 * clipping, determinism. Frames are opaque; every pixel names its frame (high byte) and its row (low byte). */
#include "tharness.h"
#include "board.h"

#define SW 536
#define SH 240
#define FW 200
#define FH 40
#define X0 ((SW - FW) / 2)

static uint16_t s_sheet[12][FW * FH];
static const uint16_t *s_frames[12];
static uint16_t s_fb[SW * SH];

static uint16_t px_of(int f, int r) { return (uint16_t)(((f + 1) << 8) | (r + 1)); }

static void make_sheet(void)
{
    for (int f = 0; f < 12; f++) {
        s_frames[f] = s_sheet[f];
        for (int r = 0; r < FH; r++)
            for (int x = 0; x < FW; x++) s_sheet[f][r * FW + x] = px_of(f, r);
    }
}

/* The frame / row shown at screen row y (column X0 + 5): -1 = black. */
static int frame_at(int y, int *row)
{
    const uint16_t v = s_fb[y * SW + X0 + 5];
    if (row) *row = v ? (v & 0xFF) - 1 : -1;
    return v ? (v >> 8) - 1 : -1;
}

static board_row_t row(int frame, int64_t until)
{
    return (board_row_t){ .frame = (uint8_t)frame, .has_until = until > 0, .until = until };
}

static void test_init(void)
{
    make_sheet();
    board_t b;
    board_row_t rows[2] = { row(1, 0), row(2, 0) };
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 2, 0, -1, 0, SW, SH), BOARD_OK);
    CHECK_EQ(b.speed, BOARD_SPEED_DEF);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 2, -1, -1, 2, SW, SH), BOARD_OK);
    CHECK_EQ(b.speed, BOARD_SPEED_MIN);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 2, -1, -1, 999, SW, SH), BOARD_OK);
    CHECK_EQ(b.speed, BOARD_SPEED_MAX);
    /* bad arguments */
    CHECK_EQ(board_init(NULL, s_frames, 12, FW, FH, rows, 2, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, NULL, 12, FW, FH, rows, 2, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, s_frames, 0, FW, FH, rows, 2, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, s_frames, 49, FW, FH, rows, 2, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, s_frames, 12, 537, FH, rows, 2, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, 15, rows, 2, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, 241, rows, 2, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 0, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 48, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 2, 12, -1, 0, SW, SH), BOARD_ERR_ARG);   /* header */
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 2, -1, 12, 0, SW, SH), BOARD_ERR_ARG);   /* empty */
    board_row_t bad[1] = { row(12, 0) };
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, bad, 1, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    const uint16_t *holes[2] = { s_frames[0], NULL };
    board_row_t r0[1] = { row(0, 0) };
    CHECK_EQ(board_init(&b, holes, 2, FW, FH, r0, 1, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    /* the pixel limit: 48 x 536 x 41 > 1 048 576, 48 x 536 x 40 fits */
    static uint16_t big[536 * 41];
    const uint16_t *bf[48];
    for (int i = 0; i < 48; i++) bf[i] = big;
    CHECK_EQ(board_init(&b, bf, 48, 536, 41, r0, 1, -1, -1, 0, SW, SH), BOARD_ERR_ARG);
    CHECK_EQ(board_init(&b, bf, 48, 536, 40, r0, 1, -1, -1, 0, SW, SH), BOARD_OK);
    /* a failed board renders nothing */
    board_t z;
    board_init(&z, NULL, 0, 0, 0, NULL, 0, -1, -1, 0, SW, SH);
    for (int i = 0; i < SW * SH; i++) s_fb[i] = 0x1234;
    board_rect_t d;
    board_render(&z, s_fb, SW, SH, &d);
    CHECK(d.w == 0 && s_fb[0] == 0x1234);
    CHECK(!board_step(&z, 100) && !board_set_clock(&z, 5, true));
}

/* The until filter and the unsynced clock; a static list: header, rows stacked under it, centred; expiry at once. */
static void test_static(void)
{
    board_t b;
    board_row_t rows[3] = { row(1, 1000), row(2, 2000), row(3, 0) };
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 3, 0, 9, 16, SW, SH), BOARD_OK);
    CHECK_EQ(b.nshown, 3);                       /* until the clock is told: every row */
    CHECK(!board_set_clock(&b, 5000, false));    /* unsynced: still every row */
    CHECK_EQ(b.nshown, 3);
    CHECK(!b.scrolling && board_next_ms(&b) == UINT32_MAX);
    CHECK_EQ(board_top(&b), FH);
    board_rect_t d;
    CHECK(board_step(&b, 0));                    /* the first render is pending */
    for (int i = 0; i < SW * SH; i++) s_fb[i] = 0x1234;
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(d.x == 0 && d.y == 0 && d.w == SW && d.h == SH);
    CHECK_EQ(s_fb[0], 0);                        /* cleared */
    int r;
    CHECK(frame_at(0, &r) == 0 && r == 0);       /* the header at the top */
    CHECK(frame_at(FH, &r) == 1 && r == 0);      /* rows stacked with no gap */
    CHECK(frame_at(2 * FH + 7, &r) == 2 && r == 7);
    CHECK(frame_at(3 * FH, NULL) == 3);
    CHECK(frame_at(4 * FH, NULL) == -1);         /* below: black */
    CHECK(s_fb[FH * SW + X0] != 0 && s_fb[FH * SW + X0 - 1] == 0 && s_fb[FH * SW + X0 + FW - 1] != 0 &&
          s_fb[FH * SW + X0 + FW] == 0);         /* centred horizontally */
    CHECK(!board_step(&b, 1000));                /* static: nothing moves */
    board_render(&b, s_fb, SW, SH, &d);
    CHECK_EQ(d.w, 0);
    /* the synced clock: row 0 (until 1000) is past at 1500, row 1 still ahead */
    CHECK(board_set_clock(&b, 1500, true));      /* static: at once */
    CHECK_EQ(b.nshown, 2);
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(frame_at(FH, NULL) == 2 && frame_at(2 * FH, NULL) == 3 && frame_at(3 * FH, NULL) == -1);
    CHECK(!board_set_clock(&b, 1600, true));     /* the same set: nothing to do */
    CHECK(board_set_clock(&b, 2000, true));      /* until is exclusive: at 2000 row 1 is gone */
    CHECK_EQ(b.nshown, 1);
    /* a row without until never expires; the clock going back brings rows back */
    CHECK(!board_set_clock(&b, 99999999, true));
    CHECK_EQ(b.nshown, 1);
    CHECK(board_set_clock(&b, 10, true));
    CHECK_EQ(b.nshown, 3);
    /* unsynced again: every row */
    board_set_clock(&b, 99999999, true);
    CHECK(board_set_clock(&b, 99999999, false));
    CHECK_EQ(b.nshown, 3);
}

/* Header and empty: no row left -> the empty frame alone under the header; without empty -> black. */
static void test_empty(void)
{
    board_t b;
    board_row_t rows[2] = { row(1, 100), row(2, 200) };
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 2, 0, 9, 16, SW, SH), BOARD_OK);
    CHECK(board_set_clock(&b, 500, true));
    CHECK_EQ(b.nshown, 0);
    CHECK_EQ(board_stack_h(&b), FH);
    board_rect_t d;
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(frame_at(0, NULL) == 0 && frame_at(FH, NULL) == 9 && frame_at(2 * FH, NULL) == -1);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 2, -1, -1, 16, SW, SH), BOARD_OK);
    board_set_clock(&b, 500, true);
    board_render(&b, s_fb, SW, SH, &d);
    int ink = 0;
    for (int i = 0; i < SW * SH; i++) ink += s_fb[i] != 0;
    CHECK_EQ(ink, 0);
    CHECK_EQ(board_stack_h(&b), 0);
    /* no header: rows from y 0 */
    board_set_clock(&b, 50, true);
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(board_top(&b) == 0 && frame_at(0, NULL) == 1 && frame_at(FH, NULL) == 2);
}

/* A long list scrolls up at speed px/s, loops with a 48 px black gap, dirty = the rows' column below the header. */
static void test_scroll(void)
{
    board_t b;
    board_row_t rows[8];
    for (int i = 0; i < 8; i++) rows[i] = row(1 + i, 0);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 8, 0, -1, 16, SW, SH), BOARD_OK);
    CHECK(b.scrolling);                          /* 8 x 40 = 320 > 240 - 40 */
    CHECK_EQ(board_period(&b), 8 * FH + BOARD_GAP);
    CHECK_EQ(board_next_ms(&b), BOARD_FRAME_MS);
    board_rect_t d;
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(d.w == SW && d.h == SH);
    int r;
    CHECK(frame_at(FH, &r) == 1 && r == 0);      /* offset 0: row 0 right under the header */
    CHECK(board_step(&b, 1000));                 /* 16 px later */
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(d.x == X0 && d.y == FH && d.w == FW && d.h == SH - FH);   /* the column below the header */
    CHECK(frame_at(0, NULL) == 0);               /* the header stays */
    CHECK(frame_at(FH, &r) == 1 && r == 16);     /* row 0 scrolled up by 16 */
    CHECK(frame_at(FH + 24, &r) == 2 && r == 0);
    /* sub-pixel steps: no change until a whole pixel */
    CHECK(!board_step(&b, 30));                  /* 0.48 px */
    CHECK(board_step(&b, 40));                   /* 1.12 px in all */
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(frame_at(FH, &r) == 1 && r == 17);
    /* the gap: at offset 320 the top of the area is 48 px of black, then row 0 again */
    b.offset_m = 320u * 1000u;
    board_invalidate(&b);
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(frame_at(FH, NULL) == -1 && frame_at(FH + BOARD_GAP - 1, NULL) == -1);
    CHECK(frame_at(FH + BOARD_GAP, &r) == 1 && r == 0);
    /* at offset 300: the last row's end, then the gap, then row 0 */
    b.offset_m = 300u * 1000u;
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(frame_at(FH, &r) == 8 && r == 20);
    CHECK(frame_at(FH + 20, NULL) == -1);
    CHECK(frame_at(FH + 20 + BOARD_GAP, &r) == 1 && r == 0);
    /* one loop: period / speed seconds */
    b.offset_m = 0;
    const uint32_t loops = b.loops;
    const uint32_t ms = (uint32_t)board_period(&b) * 1000u / b.speed;   /* 368 px at 16 px/s = 23 s */
    for (uint32_t t = 0; t + BOARD_FRAME_MS <= ms; t += BOARD_FRAME_MS) board_step(&b, BOARD_FRAME_MS);
    CHECK_EQ(b.loops, loops);
    board_step(&b, BOARD_FRAME_MS);
    CHECK_EQ(b.loops, loops + 1);
    CHECK(b.offset_m < (uint64_t)b.speed * BOARD_FRAME_MS);
    /* dirty rects clipped to a smaller framebuffer; nothing outside it written */
    static uint16_t small[300 * 100 + 50];
    for (size_t i = 0; i < sizeof small / 2; i++) small[i] = 0x5A5A;
    board_invalidate(&b);
    board_render(&b, small, 300, 100, &d);
    CHECK(d.x + d.w <= 300 && d.y + d.h <= 100);
    for (int i = 300 * 100; i < 300 * 100 + 50; i++) CHECK_EQ(small[i], 0x5A5A);
}

/* Expiry while scrolling waits for the loop boundary; a list that then fits stops scrolling. */
static void test_expiry_at_loop(void)
{
    board_t b;
    board_row_t rows[6];
    for (int i = 0; i < 6; i++) rows[i] = row(1 + i, 1000 + 100 * i);   /* 6 x 40 = 240 > 200 (header) */
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, rows, 6, 0, 11, 60, SW, SH), BOARD_OK);
    CHECK(!board_set_clock(&b, 500, true));      /* all ahead: the same set */
    CHECK(b.scrolling);
    board_step(&b, 2000);                        /* 120 px in */
    CHECK(!board_set_clock(&b, 1050, true));     /* row 0 expired: pending, not applied mid-loop */
    CHECK(b.pending && b.nshown == 6);
    board_rect_t d;
    board_render(&b, s_fb, SW, SH, &d);
    int r;
    CHECK(frame_at(FH, &r) == 4 && r == 0);      /* still the old list at offset 120 (row 3, frame 4, at the top) */
    const uint32_t loops = b.loops;
    while (b.loops == loops) board_step(&b, BOARD_FRAME_MS);
    CHECK(!b.pending && b.nshown == 5);          /* applied at the boundary */
    CHECK(!b.scrolling);                         /* 5 x 40 = 200: fits under the header now */
    CHECK_EQ(board_next_ms(&b), UINT32_MAX);
    board_render(&b, s_fb, SW, SH, &d);
    CHECK(d.w == SW && d.h == SH);               /* a full repaint */
    CHECK(frame_at(FH, &r) == 2 && r == 0);      /* row 1 (frame 2) on top, static */
    CHECK(frame_at(SH - 1, &r) == 6 && r == FH - 1);
    /* a scrolling list that stays scrolling keeps its phase past the boundary */
    board_row_t many[10];
    for (int i = 0; i < 10; i++) many[i] = row(1 + (i % 10), i == 0 ? 1000 : 0);
    CHECK_EQ(board_init(&b, s_frames, 12, FW, FH, many, 10, -1, -1, 30, SW, SH), BOARD_OK);
    board_set_clock(&b, 500, true);
    CHECK(b.scrolling && b.nshown == 10);
    board_set_clock(&b, 1500, true);
    CHECK(b.pending);
    const int p = board_period(&b);
    while (!b.loops) board_step(&b, 100);
    CHECK(b.scrolling && b.nshown == 9 && board_period(&b) == p - FH);
}

static uint64_t run_hash(uint32_t seed)
{
    board_t b;
    board_row_t rows[10];
    for (int i = 0; i < 10; i++) rows[i] = row(1 + i % 11, i % 3 ? 0 : 400 + 37 * i);
    board_init(&b, s_frames, 12, FW, FH, rows, 10, 0, 11, 23, SW, SH);
    uint64_t h = 1469598103934665603ULL;
    uint32_t x = seed;
    int64_t now = 0;
    for (int i = 0; i < 2000; i++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        if (i % 30 == 0) board_set_clock(&b, now += 3, i > 60);
        if (board_step(&b, 20 + x % 30)) {
            board_rect_t d;
            board_render(&b, s_fb, SW, SH, &d);
            for (int k = 0; k < SW * SH; k += 97) h = (h ^ s_fb[k]) * 1099511628211ULL;
        }
    }
    return h;
}

static void test_determinism(void)
{
    CHECK_EQ(run_hash(7), run_hash(7));
    CHECK(run_hash(7) != run_hash(8));
}

int main(void)
{
    RUN(test_init);
    RUN(test_static);
    RUN(test_empty);
    RUN(test_scroll);
    RUN(test_expiry_at_loop);
    RUN(test_determinism);
    return TH_DONE("test_board");
}
