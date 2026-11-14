/* oracle_text.c — the Oracle's text screens from glyph atlases (see include/oracle_text.h, PROTOCOL §5f.2). */
#include "oracle_text.h"

#include <string.h>

typedef struct { int x0, y0, x1, y1; } box_t;

static const box_t k_clip = { OT_CLEAR_X0, 0, OT_DOT_X - 2, OT_SCREEN_H };        /* the right column */
static const box_t k_full = { 0, 0, OT_DOT_X - 2, OT_SCREEN_H };                  /* the paragraph */

/* Native RGB565 -> the in-memory RGB565BE pixel. */
static uint16_t be(uint16_t v)
{
    const uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v };
    uint16_t r;
    memcpy(&r, b, 2);
    return r;
}

static bool fonts_ok(const ot_fonts_t *f)
{
    return f && f->body && f->body->normal.white && f->body->normal.accent && f->scratch && f->work &&
           (!f->big || (f->big->normal.white && f->big->normal.accent));
}

static void clear(uint16_t *fb)
{
    for (int y = 0; y < OT_SCREEN_H; y++) memset(fb + (size_t)y * OT_SCREEN_W + OT_CLEAR_X0, 0, (OT_SCREEN_W - OT_CLEAR_X0) * 2u);
}

/* Decode glyph g and copy its non-black pixels with the cell's top-left at (x, y), clipped to k_clip. */
static bool blit(const rsvp_face_t *face, const hca_asset_t *atlas, uint16_t g, int x, int y, uint16_t *fb,
                 uint16_t *scratch, size_t scratch_px, box_t clip)
{
    if (g == RSVP_GLYPH_NONE || !atlas) return true;
    if ((size_t)face->cell_w * face->cell_h > scratch_px) return false;
    int ox0 = clip.x0 - x, ox1 = clip.x1 - x, oy0 = clip.y0 - y, oy1 = clip.y1 - y;
    if (ox0 < 0) ox0 = 0;
    if (oy0 < 0) oy0 = 0;
    if (ox1 > face->cell_w) ox1 = face->cell_w;
    if (oy1 > face->cell_h) oy1 = face->cell_h;
    if (ox0 >= ox1 || oy0 >= oy1) return true;
    if (hca_decode_frame(atlas, g, scratch, face->cell_w) != HCA_OK) return false;
    for (int oy = oy0; oy < oy1; oy++) {
        const uint16_t *row = scratch + (size_t)oy * face->cell_w;
        uint16_t *dst = fb + (size_t)(y + oy) * OT_SCREEN_W + x;
        for (int ox = ox0; ox < ox1; ox++)
            if (row[ox]) dst[ox] = row[ox];
    }
    return true;
}

/* Wrap text at width w (all lines, the scroll-style text layout: lines centred in [0, w)). */
static int wrap_w(const ot_fonts_t *f, const rsvp_font_t *font, const char *text, size_t len, int w)
{
    if (textlay_layout_style(font, text ? text : "", text ? len : 0, w, OT_SCREEN_H, 0, TEXTLAY_STYLE_SCROLL, f->work) !=
        TEXTLAY_OK) {
        return -1;
    }
    return f->work->lines;
}

/* Wrap text into the column. */
static int wrap(const ot_fonts_t *f, const rsvp_font_t *font, const char *text, size_t len)
{
    return wrap_w(f, font, text, len, OT_COL_W);
}

/* Draw lines [first, first + count) of the work layout from row y0 at x offset x0, clipped to clip. */
static int draw_lines_at(const ot_fonts_t *f, unsigned first, unsigned count, int x0, int y0, bool accent, uint16_t *fb,
                         box_t clip)
{
    const textlay_layout_t *lay = f->work;
    const rsvp_face_t *face = lay->face;
    int fails = 0;
    for (unsigned li = first; li < first + count && li < lay->lines; li++) {
        const textlay_line_t *L = &lay->line[li];
        const int y = y0 + (int)(li - first) * lay->pitch;
        for (unsigned gi = L->first; gi < (unsigned)L->first + L->count; gi++) {
            const textlay_glyph_t *g = &lay->g[gi];
            fails += !blit(face, accent ? face->accent : face->white, g->glyph, x0 + g->x, y, fb, f->scratch,
                           f->scratch_px, clip);
        }
    }
    return fails;
}

/* Draw lines [first, first + count) of the work layout from row y0 in the column. */
static int draw_lines(const ot_fonts_t *f, unsigned first, unsigned count, int y0, bool accent, uint16_t *fb)
{
    return draw_lines_at(f, first, count, OT_COL_X0, y0, accent, fb, k_clip);
}


static int pitch_of(const rsvp_font_t *font) { return font->normal.cell_h; }

int ot_draw_prompt(const ot_fonts_t *f, const char *text, size_t len, uint16_t *fb)
{
    if (!fonts_ok(f) || !fb) return -1;
    clear(fb);
    const int n = wrap(f, f->body, text, len);
    if (n <= 0) return n < 0 ? -1 : 0;
    const int p = pitch_of(f->body);
    int rows = n;
    if (rows * p > OT_TEXT_Y1 - OT_TEXT_Y0) rows = (OT_TEXT_Y1 - OT_TEXT_Y0) / p;   /* §5f.9: clear of the hint bands */
    const int y = OT_TEXT_Y0 + (OT_TEXT_Y1 - OT_TEXT_Y0 - rows * p) / 2;          /* centred (= on the screen's middle) */
    return draw_lines(f, 0, (unsigned)rows, y, false, fb);
}

int ot_draw_face(const ot_fonts_t *f, const char *num, size_t num_len, const char *printed, size_t printed_len,
                 const char *kw, size_t kw_len, uint16_t *fb)
{
    if (!fonts_ok(f) || !fb) return -1;
    clear(fb);
    const rsvp_font_t *big = f->big ? f->big : f->body;
    const int pb = pitch_of(big), p = pitch_of(f->body);
    /* pass 1: heights */
    const int nn = wrap(f, big, num, num_len), np = wrap(f, f->body, printed, printed_len), nk = wrap(f, f->body, kw, kw_len);
    if (nn < 0 || np < 0 || nk < 0) return -1;
    const int h = nn * pb + (nn && (np || nk) ? OT_FACE_GAP : 0) + (np + nk) * p;
    int y = (OT_SCREEN_H - h) / 2;
    if (y < 0) y = 0;
    /* pass 2: draw */
    int fails = 0;
    wrap(f, big, num, num_len);
    fails += draw_lines(f, 0, (unsigned)nn, y, true, fb);
    y += nn * pb + (nn && (np || nk) ? OT_FACE_GAP : 0);
    wrap(f, f->body, printed, printed_len);
    fails += draw_lines(f, 0, (unsigned)np, y, false, fb);
    y += np * p;
    wrap(f, f->body, kw, kw_len);
    fails += draw_lines(f, 0, (unsigned)nk, y, false, fb);
    return fails;
}

int ot_draw_question(const ot_fonts_t *f, const char *lead, size_t lead_len, const char *question, size_t question_len,
                     uint16_t *fb)
{
    if (!fonts_ok(f) || !fb) return -1;
    clear(fb);
    const int p = pitch_of(f->body), max_rows = OT_SCREEN_H / p;
    int nl = wrap(f, f->body, lead, lead_len), nq = wrap(f, f->body, question, question_len);
    if (nl < 0 || nq < 0) return -1;
    if (nl > max_rows) nl = max_rows;
    if (nl + nq > max_rows) nq = max_rows - nl;
    const int y = (OT_SCREEN_H - (nl + nq) * p) / 2;
    int fails = 0;
    wrap(f, f->body, lead, lead_len);
    fails += draw_lines(f, 0, (unsigned)nl, y, true, fb);
    wrap(f, f->body, question, question_len);
    fails += draw_lines(f, 0, (unsigned)nq, y + nl * p, false, fb);
    return fails;
}

/* Pages of `lines` lines at `per` lines a page, at most `max` pages. */
static void info_of(int lines, int per, int max, ot_info_t *out)
{
    out->lines = (uint8_t)(lines > 255 ? 255 : lines);
    out->per_page = (uint8_t)per;
    int pages = (lines + per - 1) / per;
    out->truncated = pages > max;
    out->pages = (uint8_t)(pages > max ? max : pages);
}

/* Lines a reading page holds at this body size: OT_PAGE_LINES, fewer if the atlas is too tall for that. */
static int reading_rows(const ot_fonts_t *f)
{
    const int p = pitch_of(f->body), fit = p > 0 ? OT_SCREEN_H / p : 1;
    return fit < 1 ? 1 : fit < OT_PAGE_LINES ? fit : OT_PAGE_LINES;
}

/* Lines a paragraph page holds: as many as fit in rows [OT_TEXT_Y0, OT_TEXT_Y1) (§5f.9). */
static int paragraph_rows(const ot_fonts_t *f)
{
    const int p = pitch_of(f->body), fit = p > 0 ? (OT_TEXT_Y1 - OT_TEXT_Y0) / p : 1;
    return fit < 1 ? 1 : fit;
}

/* The page dots at the right edge: one per page, the current one in the accent colour. */
static void dots(uint16_t *fb, unsigned pages, unsigned page)
{
    if (pages < 2) return;
    const uint16_t on = be(TEXTLAY_CURSOR_COLOR), off = be(TEXTLAY_BAR_DIM_COLOR);
    const int y0 = (OT_SCREEN_H - ((int)pages - 1) * OT_DOT_STEP - OT_DOT) / 2;
    for (unsigned k = 0; k < pages; k++) {
        const uint16_t px = k == page ? on : off;
        for (int y = 0; y < OT_DOT; y++)
            for (int x = 0; x < OT_DOT; x++) fb[(size_t)(y0 + (int)k * OT_DOT_STEP + y) * OT_SCREEN_W + OT_DOT_X + x] = px;
    }
}

int ot_reading_info(const ot_fonts_t *f, const char *text, size_t len, ot_info_t *out)
{
    if (!fonts_ok(f) || !out) return -1;
    memset(out, 0, sizeof *out);
    const int n = wrap(f, f->body, text, len);
    if (n < 0) return -1;
    info_of(n, reading_rows(f), OT_MAX_PAGES, out);
    return 0;
}

int ot_draw_reading(const ot_fonts_t *f, const char *text, size_t len, unsigned page, uint16_t *fb, ot_info_t *info)
{
    if (!fonts_ok(f) || !fb) return -1;
    clear(fb);
    const int n = wrap(f, f->body, text, len);
    if (n < 0) return -1;
    ot_info_t in;
    const int per = reading_rows(f);
    info_of(n, per, OT_MAX_PAGES, &in);
    if (info) *info = in;
    if (!in.pages) return 0;
    if (page >= in.pages) page = in.pages - 1u;
    const int p = pitch_of(f->body);
    const int rows = n < per ? n : per;   /* every page placed as a full one: the text does not jump */
    const int first = (int)page * per;
    const int count = n - first < rows ? n - first : rows;
    const int fails = draw_lines(f, (unsigned)first, (unsigned)count, (OT_SCREEN_H - rows * p) / 2, false, fb);
    dots(fb, in.pages, page);
    return fails;
}

int ot_paragraph_info(const ot_fonts_t *f, const char *text, size_t len, ot_info_t *out)
{
    if (!fonts_ok(f) || !out) return -1;
    memset(out, 0, sizeof *out);
    const int n = wrap_w(f, f->body, text, len, OT_PARA_W);
    if (n < 0) return -1;
    info_of(n, paragraph_rows(f), OT_PARA_MAX_PAGES, out);
    return 0;
}

int ot_draw_paragraph(const ot_fonts_t *f, const char *text, size_t len, unsigned page, uint16_t *fb, ot_info_t *info)
{
    if (!fonts_ok(f) || !fb) return -1;
    memset(fb, 0, (size_t)OT_SCREEN_W * OT_SCREEN_H * 2u);   /* full width: the whole screen */
    const int n = wrap_w(f, f->body, text, len, OT_PARA_W);
    if (n < 0) return -1;
    ot_info_t in;
    const int per = paragraph_rows(f);
    info_of(n, per, OT_PARA_MAX_PAGES, &in);
    if (info) *info = in;
    if (!in.pages) return 0;
    if (page >= in.pages) page = in.pages - 1u;
    const int p = pitch_of(f->body);
    const int rows = n < per ? n : per;
    const int first = (int)page * per;
    const int count = n - first < rows ? n - first : rows;
    const int y0 = OT_TEXT_Y0 + (OT_TEXT_Y1 - OT_TEXT_Y0 - rows * p) / 2;   /* centred between the hint bands */
    const int fails = draw_lines_at(f, (unsigned)first, (unsigned)count, OT_PARA_X0, y0, false, fb, k_full);
    dots(fb, in.pages, page);
    return fails;
}

/* ---- §5f.11 the corner arrow ---------------------------------------------------------------------------------- */

void ot_draw_arrow(uint16_t *fb, bool flipped)
{
    if (!fb) return;
    int x, y;
    ot_arrow_xy(flipped, &x, &y);
    const uint16_t c = be(TEXTLAY_CURSOR_COLOR);
    for (int r = 0; r < OT_ARROW_H; r++) {
        const int d = r < 4 ? 4 - r : r - 4, w = 9 - 2 * d;   /* 1, 3, 5, 7, 9, 7, 5, 3, 1 -> clipped to 8 wide */
        for (int k = 0; k < w && k < OT_ARROW_W; k++) {
            const int px = flipped ? x + OT_ARROW_W - 1 - k : x + k;   /* the wide side away from the button */
            fb[(size_t)(y + r) * OT_SCREEN_W + px] = c;
        }
    }
}

/* ---- §5f.10 / §5f.11 text boxes ------------------------------------------------------------------------------- */

static bool view_of(const rsvp_font_t *src, const rsvp_face_t *face, bool bound, rsvp_font_t *dst)
{
    if (!src || !dst || !bound || !face->white || !face->accent) return false;
    *dst = *src;
    dst->normal = *face;
    dst->has_compact = dst->compact_bound = false;
    dst->has_large = dst->large_bound = false;
    return true;
}

bool ot_font_compact_view(const rsvp_font_t *src, rsvp_font_t *dst)
{
    return src && view_of(src, &src->compact, src->compact_bound, dst);
}

bool ot_font_large_view(const rsvp_font_t *src, rsvp_font_t *dst)
{
    return src && view_of(src, &src->large, src->large_bound, dst);
}

static bool box_ok(const ot_fonts_t *f, const rsvp_font_t *font, int x0, int x1, int y0, int y1)
{
    return fonts_ok(f) && font && font->normal.white && font->normal.accent && x0 >= 0 && x1 <= OT_SCREEN_W &&
           x1 - x0 >= 16 && y0 >= 0 && y1 <= OT_SCREEN_H && y1 > y0;
}

/* Rows a box page holds at this font. */
static int box_rows(const rsvp_font_t *font, int y0, int y1)
{
    const int p = pitch_of(font), fit = p > 0 ? (y1 - y0) / p : 1;
    return fit < 1 ? 1 : fit;
}

int ot_box_info(const ot_fonts_t *f, const rsvp_font_t *font, const char *text, size_t len, int x0, int x1, int y0,
                int y1, ot_info_t *out)
{
    if (!box_ok(f, font, x0, x1, y0, y1) || !out) return -1;
    memset(out, 0, sizeof *out);
    const int n = wrap_w(f, font, text, len, x1 - x0);
    if (n < 0) return -1;
    info_of(n, box_rows(font, y0, y1), 255, out);
    if (len > TEXTLAY_LAYOUT_TEXT_MAX || f->work->truncated) {   /* laid out only in part: never "one page" */
        out->truncated = true;
        if (out->pages < 2) out->pages = 2;
    }
    return 0;
}

bool ot_lean_fits(void *fonts, const char *text, size_t len)
{
    const ot_fonts_t *f = (const ot_fonts_t *)fonts;
    ot_info_t in;
    return f && ot_box_info(f, f->body, text, len, OT_FULL_X0, OT_FULL_X1, 0, OT_BOX_H, &in) == 0 && in.pages <= 1;
}

int ot_box_pick(const ot_fonts_t *f, const rsvp_font_t *const fonts[], int n, const char *text, size_t len, int x0,
                int x1, int y0, int y1)
{
    for (int i = 0; fonts && i < n; i++) {
        ot_info_t in;
        if (fonts[i] && ot_box_info(f, fonts[i], text, len, x0, x1, y0, y1, &in) == 0 && in.pages <= 1) return i;
    }
    return -1;
}

int ot_draw_box(const ot_fonts_t *f, const rsvp_font_t *font, const char *text, size_t len, int x0, int x1, int y0,
                int y1, uint16_t *fb, ot_info_t *info)
{
    if (!box_ok(f, font, x0, x1, y0, y1) || !fb) return -1;
    memset(fb, 0, (size_t)OT_SCREEN_W * OT_SCREEN_H * 2u);
    const int n = wrap_w(f, font, text, len, x1 - x0);
    if (n < 0) return -1;
    ot_info_t in;
    const int per = box_rows(font, y0, y1);
    info_of(n, per, 255, &in);
    if (info) *info = in;
    if (!n) return 0;
    const int rows = n < per ? n : per, p = pitch_of(font);
    const box_t clip = { x0, y0, x1, y1 };
    return draw_lines_at(f, 0, (unsigned)rows, x0, y0 + (y1 - y0 - rows * p) / 2, false, fb, clip);
}
