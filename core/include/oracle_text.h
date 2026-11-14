/* oracle_text.h — the Oracle's text screens drawn from glyph atlases (docs/PROTOCOL.md §5f.2).
 *
 * C11, no allocation, no I/O. Replaces the app-rendered text asset T: the clip draws the right column of every text
 * screen (x OT_COL_X0..OT_COL_X1 of the 536x240 panel) from the reader bundle's lines with reader fonts (§5c atlases),
 * wrapping with the text layout (textlay.h, scroll style: its wrapping rules, lines centred in the column) and
 * painting the glyphs statically (no typing). The card slot on the left (x 40, y 21, 104x198) stays the caller's paste.
 *
 * Screens (each clears the column box [OT_CLEAR_X0, 536) x [0, 240) to black first, then draws; blocks are centred
 * vertically in the 240 rows):
 *   prompt    the waits prompt, wrapped, white.
 *   face      the numeral (`big` font, accent atlas) centred, OT_FACE_GAP px, then the printed name (omitted when empty,
 *             e.g. XIII) and the keyword (body font, white), each wrapped and centred.
 *   question  the lead-in line ("Le Tarot te demande :", body font, accent atlas) then the question (white); lines that
 *             do not fit in 240 rows are not drawn.
 *   reading   page p of the wrapped reading: OT_PAGE_LINES lines per page (fewer when the body atlas is too tall),
 *             at most OT_MAX_PAGES pages (more lines are not drawn: ot_info_t.truncated); every page's block is placed as
 *             a full page, so the text does not jump between pages. With 2+ pages a dot per
 *             page at x OT_DOT_X (OT_DOT x OT_DOT px, OT_DOT_STEP apart, centred vertically): the current page in the
 *             accent colour (TEXTLAY_CURSOR_COLOR), the others dim (TEXTLAY_BAR_DIM_COLOR).
 * Fonts: `body` must be bound (normal face); `big` NULL = body. `scratch` holds rsvp_font_scratch_px() of both fonts;
 * `work` is a textlay_layout_t the caller owns (~13 KB; the clip keeps it in PSRAM). Functions return the number of glyph
 * frames that failed to decode, or -1 for bad arguments.
 */
#ifndef ORACLE_TEXT_H
#define ORACLE_TEXT_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "rsvp.h"
#include "textlay.h"

#ifdef __cplusplus
extern "C" {
#endif

#define OT_SCREEN_W   536
#define OT_SCREEN_H   240
#define OT_COL_X0     168
#define OT_COL_X1     520
#define OT_COL_W      (OT_COL_X1 - OT_COL_X0)   /* 352 */
#define OT_CLEAR_X0   160                       /* cleared from here to the right edge (the slot ends at 144) */
#define OT_PAGE_LINES 4
#define OT_MAX_PAGES  6                         /* reading pages (§5f.3) */
#define OT_FACE_GAP   8
#define OT_DOT        4
#define OT_DOT_STEP   12
#define OT_DOT_X      526
#define OT_PARA_X0    20                        /* the paragraph: full width x 20..516 (§5f.3) */
#define OT_PARA_X1    516
#define OT_PARA_W     (OT_PARA_X1 - OT_PARA_X0)
#define OT_TEXT_Y0    20                        /* §5f.9: text (prompts, lean, detail) is centred in rows 20..219, */
#define OT_TEXT_Y1    220                       /* clear of both hint bands, whatever the orientation */
#define OT_PARA_MAX_PAGES 8

typedef struct {
    const rsvp_font_t *body;      /* body text (~24 px); required */
    const rsvp_font_t *big;       /* the face's numeral (~60 px); NULL = body */
    uint16_t *scratch;
    size_t scratch_px;
    textlay_layout_t *work;
} ot_fonts_t;

typedef struct {
    uint8_t pages;      /* 1..max pages (0: empty text) */
    uint8_t lines;      /* wrapped lines (all of them) */
    uint8_t per_page;   /* lines a page holds at this body size */
    bool truncated;     /* more lines than per_page x max pages: the rest is not drawn */
} ot_info_t;

/* Pages of a reading (layout only). -1: bad arguments. */
int ot_reading_info(const ot_fonts_t *f, const char *text, size_t len, ot_info_t *out);

int ot_draw_prompt(const ot_fonts_t *f, const char *text, size_t len, uint16_t *fb);
int ot_draw_face(const ot_fonts_t *f, const char *num, size_t num_len, const char *printed, size_t printed_len,
                 const char *kw, size_t kw_len, uint16_t *fb);
int ot_draw_question(const ot_fonts_t *f, const char *lead, size_t lead_len, const char *question, size_t question_len,
                     uint16_t *fb);
/* page 0..pages-1 (clamped); *info (optional) as ot_reading_info. */
int ot_draw_reading(const ot_fonts_t *f, const char *text, size_t len, unsigned page, uint16_t *fb, ot_info_t *info);

/* §5f.3 the paragraph as static pages: full width (x OT_PARA_X0..OT_PARA_X1), the body font, as many lines a page as
 * fit in rows [OT_TEXT_Y0, OT_TEXT_Y1) (§5f.9: both hint bands stay free; the atlas pitch), at most
 * OT_PARA_MAX_PAGES pages, the block centred in those rows and placed as a full page on every page, the page dots at
 * OT_DOT_X. ot_draw_paragraph clears the whole screen. (The lean and detail screens are page 0 of this.) */
int ot_paragraph_info(const ot_fonts_t *f, const char *text, size_t len, ot_info_t *out);
int ot_draw_paragraph(const ot_fonts_t *f, const char *text, size_t len, unsigned page, uint16_t *fb, ot_info_t *info);

/* §5f.11 the hint: one ▶ (OT_ARROW_W x OT_ARROW_H, the accent colour) in the BOOT corner, pointing at the button:
 * normally its right edge 8 px from the right edge and its top row at y 4 (pointing right); flipped its left edge 8 px
 * from the left edge and its bottom row at y 235 (pointing left). The corner reserve (OT_RESERVE_W x OT_RESERVE_H:
 * x 512..535 y 0..15 normally, x 0..23 y 224..239 flipped) holds nothing else. ot_draw_arrow touches only the
 * triangle's pixels. */
#define OT_ARROW_W   8
#define OT_ARROW_H   9
#define OT_RESERVE_W 24
#define OT_RESERVE_H 16
static inline void ot_arrow_xy(bool flipped, int *x, int *y)
{
    *x = flipped ? 8 : OT_SCREEN_W - 8 - OT_ARROW_W;
    *y = flipped ? 235 - (OT_ARROW_H - 1) : 4;
}
static inline void ot_reserve_xy(bool flipped, int *x, int *y)
{
    *x = flipped ? 0 : OT_SCREEN_W - OT_RESERVE_W;
    *y = flipped ? OT_SCREEN_H - OT_RESERVE_H : 0;
}
void ot_draw_arrow(uint16_t *fb, bool flipped);

/* §5f.10 / §5f.11 text boxes: text wrapped at x1 - x0 with `font` (the body font, or a view whose normal face is its
 * large / compact face), lines centred in [x0, x1), the block centred in rows [y0, y1), one page (lines past it are not
 * drawn; info->pages > 1 says so). ot_draw_box clears the whole screen first (a card is the caller's paste). Boxes
 * (§5f.11): rows 16..239 normally, 0..223 flipped (ot_text_y0); full width x 8..528; beside a card (§5f.12) x 124..528
 * normally, x 8..412 flipped. */
#define OT_BOX_H          224
#define OT_FULL_X0        8
#define OT_FULL_X1        528
#define OT_BESIDE_X0_UP   124   /* §5f.12: beside the 108 px card at x 8 (normal) / 420 (flipped), 8 px apart */
#define OT_BESIDE_X1_UP   528
#define OT_BESIDE_X0_FLIP 8
#define OT_BESIDE_X1_FLIP 412
static inline int ot_text_y0(bool flipped) { return flipped ? 0 : OT_RESERVE_H; }
int ot_box_info(const ot_fonts_t *f, const rsvp_font_t *font, const char *text, size_t len, int x0, int x1, int y0,
                int y1, ot_info_t *out);
int ot_draw_box(const ot_fonts_t *f, const rsvp_font_t *font, const char *text, size_t len, int x0, int x1, int y0,
                int y1, uint16_t *fb, ot_info_t *info);
/* §5f.11 "as big as fits": the first of fonts[0..n) (largest first; NULL entries skipped) in which the text fits the
 * box on one page; -1 when none does (the caller then uses the last, cut). */
int ot_box_pick(const ot_fonts_t *f, const rsvp_font_t *const fonts[], int n, const char *text, size_t len, int x0,
                int x1, int y0, int y1);
/* §5f.11 / §5f.7 the composer's one-page check (orr_compose_lean's `fits` callback, ctx = the ot_fonts_t): the text is
 * one page in the body font's NORMAL face (f->body, whatever face the screen is then drawn in) in the full-width box,
 * OT_FULL_X1 - OT_FULL_X0 = 520 px wide by OT_BOX_H = 224 rows — the same in both orientations, and the rule the phone
 * applies, so clip and phone compose byte-identical text. */
bool ot_lean_fits(void *fonts, const char *text, size_t len);

/* A font whose normal face is src's compact / large face; false when src has none bound. dst is a plain copy (a few
 * KB: keep it with the caller's fonts). */
bool ot_font_compact_view(const rsvp_font_t *src, rsvp_font_t *dst);
bool ot_font_large_view(const rsvp_font_t *src, rsvp_font_t *dst);

#ifdef __cplusplus
}
#endif
#endif /* ORACLE_TEXT_H */
