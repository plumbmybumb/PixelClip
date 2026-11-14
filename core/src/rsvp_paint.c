/* rsvp_paint.c — word layout around the ORP column, painting with dirty rects, end card, pause mark. */
#include <string.h>
#include <stdio.h>
#include "rsvp_internal.h"

#define MAX_PLACE (RSVP_WORD_MAX_GLYPHS * 2)

/* ------------------------------------------------------------------------------------------ */
/* Glyph metrics                                                                              */

/* Atlas frame (or RSVP_GLYPH_NONE) and advance for cp in face; *missing counts substitutions. */
static void glyph_of(const rsvp_face_t *f, uint32_t cp, uint16_t *glyph, uint16_t *adv, int *missing) {
    int cls = rsvp__class(cp);
    if (cp == ' ' || cls == RC_JOIN || cls == RC_SPACE || cls == RC_NEWLINE || cls == RC_PARASEP) {
        *glyph = RSVP_GLYPH_NONE;
        *adv = f->space_adv;
        return;
    }
    int i = rsvp__face_find(f, cp);
    if (i < 0) {
        if (missing) (*missing)++;
        i = f->qmark;
    }
    if (i < 0) {
        *glyph = RSVP_GLYPH_NONE;
        *adv = (uint16_t)(f->cell_w / 2 ? f->cell_w / 2 : 1);
        return;
    }
    *glyph = f->map[i].glyph;
    *adv = f->map[i].advance;
}

static size_t decode_word(const char *s, size_t len, uint32_t *cps, size_t cap) {
    size_t n = 0, i = 0;
    while (i < len && n < cap) {
        uint32_t cp;
        size_t k = rsvp_utf8_next(s + i, len - i, &cp);
        if (k == 0) break;
        cps[n++] = cp;
        i += k;
    }
    return n;
}

/* ORP from the code points with the tokeniser's lead/core rule. */
static unsigned orp_of(const uint32_t *cps, size_t n) {
    int first = -1, last = -1;
    for (size_t i = 0; i < n; i++) {
        if (rsvp__class(cps[i]) == RC_LETTER) {
            if (first < 0) first = (int)i;
            last = (int)i;
        }
    }
    unsigned o = first >= 0 ? (unsigned)first + rsvp_orp_index((unsigned)(last - first + 1)) : rsvp_orp_index((unsigned)n);
    return n == 0 ? 0 : (o < n ? o : (unsigned)n - 1u);
}

/* Pen positions relative to the word's origin; returns the total advance. */
static int32_t measure(const rsvp_face_t *f, const uint32_t *cps, size_t n, rsvp_glyph_pos_t *pos, int *missing) {
    int32_t pen = 0;
    for (size_t i = 0; i < n; i++) {
        uint16_t g, a;
        glyph_of(f, cps[i], &g, &a, missing);
        pos[i].x = (int16_t)(pen > 30000 ? 30000 : pen);
        pos[i].glyph = g;
        pos[i].advance = a;
        pos[i].accent = 0;
        pen += a;
    }
    return pen;
}

static const rsvp_face_t *face_bound(const rsvp_font_t *f, bool compact) {
    if (!compact) return f->normal.white && f->normal.accent ? &f->normal : NULL;
    return f->compact_bound ? &f->compact : NULL;
}

rsvp_status_t rsvp_layout(const rsvp_font_t *f, const char *word, size_t len, int orp_x, int screen_w,
                          int margin, rsvp_glyph_pos_t *pos, size_t cap, rsvp_layout_t *out) {
    if (!f || !word || len == 0 || !pos || cap == 0 || !out || !face_bound(f, false)) return RSVP_ERR_ARG;
    uint32_t cps[MAX_PLACE];
    size_t n = decode_word(word, len, cps, cap < MAX_PLACE ? cap : MAX_PLACE);
    if (n == 0) return RSVP_ERR_ARG;
    unsigned orp = orp_of(cps, n);
    memset(out, 0, sizeof *out);
    const rsvp_face_t *faces[2] = { face_bound(f, false), face_bound(f, true) };
    const rsvp_face_t *face = NULL;
    int32_t left = 0, total = 0;
    for (int k = 0; k < 2 && faces[k]; k++) {
        total = measure(faces[k], cps, n, pos, NULL);
        left = orp_x - pos[orp].x - pos[orp].advance / 2;
        face = faces[k];
        out->compact = k == 1;
        if (left >= margin && left + total <= screen_w - margin) break;
        if (k == 1 || !faces[1]) {
            /* the smallest size still overflows with the ORP pinned */
            if (total <= screen_w - 2 * margin) {
                int32_t l2 = left < margin ? margin : left;
                if (l2 + total > screen_w - margin) l2 = screen_w - margin - total;
                left = l2;
                out->shifted = true;
            } else {
                out->clipped = true;
            }
            break;
        }
    }
    int32_t x0 = INT16_MAX, x1 = INT16_MIN;
    for (size_t i = 0; i < n; i++) {
        int32_t x = left + pos[i].x;
        if (x < INT16_MIN) x = INT16_MIN;
        if (x > INT16_MAX - 1024) x = INT16_MAX - 1024;
        pos[i].x = (int16_t)x;
        pos[i].accent = i == orp;
        if (pos[i].glyph != RSVP_GLYPH_NONE) {
            if (x < x0) x0 = x;
            if (x + face->cell_w > x1) x1 = x + face->cell_w;
        }
    }
    if (x1 < x0) x0 = x1 = left;
    out->face = face;
    out->n = (uint8_t)n;
    out->orp = (uint8_t)orp;
    out->x0 = (int16_t)x0;
    out->x1 = (int16_t)x1;
    int32_t tx0 = left, tx1 = left + total;
    out->text_x0 = (int16_t)(tx0 < INT16_MIN ? INT16_MIN : tx0 > INT16_MAX ? INT16_MAX : tx0);
    out->text_x1 = (int16_t)(tx1 < INT16_MIN ? INT16_MIN : tx1 > INT16_MAX ? INT16_MAX : tx1);
    return RSVP_OK;
}

/* ------------------------------------------------------------------------------------------ */
/* Drawing                                                                                    */

typedef struct { int x0, y0, x1, y1; } clip_t;

/* Decode glyph `g` of `atlas` into scratch and copy its non-black pixels, subsampled by `div`, with
 * the cell's top-left at (x, y), clipped to c. False if the frame does not decode. */
static bool blit_glyph(const rsvp_face_t *f, const hca_asset_t *atlas, uint16_t g, int x, int y, int div,
                       uint16_t *fb, int fb_w, clip_t c, uint16_t *scratch, size_t scratch_px) {
    if (g == RSVP_GLYPH_NONE || !atlas) return true;
    if ((size_t)f->cell_w * f->cell_h > scratch_px || !scratch) return false;
    int ow = f->cell_w / div, oh = f->cell_h / div;
    int ox0 = c.x0 - x, ox1 = c.x1 - x, oy0 = c.y0 - y, oy1 = c.y1 - y;
    if (ox0 < 0) ox0 = 0;
    if (oy0 < 0) oy0 = 0;
    if (ox1 > ow) ox1 = ow;
    if (oy1 > oh) oy1 = oh;
    if (ox0 >= ox1 || oy0 >= oy1) return true;
    if (hca_decode_frame(atlas, g, scratch, f->cell_w) != HCA_OK) return false;
    for (int oy = oy0; oy < oy1; oy++) {
        const uint16_t *row = scratch + (size_t)(oy * div) * f->cell_w;
        uint16_t *dst = fb + (size_t)(y + oy) * (size_t)fb_w;
        if (div == 1) {
            for (int ox = ox0; ox < ox1; ox++) if (row[ox]) dst[x + ox] = row[ox];
        } else {
            for (int ox = ox0; ox < ox1; ox++) {
                uint16_t px = row[ox * div];
                if (px) dst[x + ox] = px;
            }
        }
    }
    return true;
}

static void fill(uint16_t *fb, int fb_w, int x0, int y0, int x1, int y1, uint16_t px) {
    for (int y = y0; y < y1; y++) {
        uint16_t *d = fb + (size_t)y * (size_t)fb_w;
        if (px == 0) {
            memset(d + x0, 0, (size_t)(x1 - x0) * 2u);
        } else {
            for (int x = x0; x < x1; x++) d[x] = px;
        }
    }
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

static rsvp_rect_t rect_of(int x0, int y0, int x1, int y1) {
    rsvp_rect_t r = { 0, 0, 0, 0 };
    if (x1 > x0 && y1 > y0) {
        r.x = (int16_t)x0; r.y = (int16_t)y0; r.w = (int16_t)(x1 - x0); r.h = (int16_t)(y1 - y0);
    }
    return r;
}

void rsvp_painter_init(rsvp_painter_t *p, const rsvp_font_t *f, int fb_w, int fb_h, int orp_x) {
    if (!p) return;
    memset(p, 0, sizeof *p);
    if (fb_w < 1) fb_w = 1;
    if (fb_h < 1) fb_h = 1;
    if (fb_w > 4096) fb_w = 4096;
    if (fb_h > 4096) fb_h = 4096;
    p->fb_w = (int16_t)fb_w;
    p->fb_h = (int16_t)fb_h;
    p->orp_x = (int16_t)clampi(orp_x, 1, fb_w - 1);
    p->margin = 8;
    int asc = 0, desc = 0;
    if (f) {
        asc = f->normal.baseline;
        desc = f->normal.cell_h - f->normal.baseline;
        if (f->compact_bound) {
            if (f->compact.baseline > asc) asc = f->compact.baseline;
            if (f->compact.cell_h - f->compact.baseline > desc) desc = f->compact.cell_h - f->compact.baseline;
        }
    }
    int band_h = clampi(asc + desc, 1, fb_h);
    p->band_h = (int16_t)band_h;
    p->band_y = (int16_t)((fb_h - band_h) / 2);
    p->baseline_y = (int16_t)(p->band_y + asc);
    p->tick_len = 12;
    p->tick_gap = 4;
    p->tick_px = rsvp__be(RSVP_TICK_COLOR);
    /* pause mark box in the top-right corner, above the band when there is room (24..40 px high) */
    int bh = clampi(p->band_y - 12, 24, 40), bw = 40;
    p->pause_box = rect_of(clampi(fb_w - 8 - bw, 0, fb_w), clampi(6, 0, fb_h), clampi(fb_w - 8, 0, fb_w),
                           clampi(6 + bh, 0, fb_h));
    p->full = true;
}

static void draw_ticks(const rsvp_painter_t *p, uint16_t *fb) {
    int x0 = clampi(p->orp_x - 1, 0, p->fb_w), x1 = clampi(p->orp_x + 1, 0, p->fb_w);
    int a0 = clampi(p->band_y - p->tick_gap - p->tick_len, 0, p->fb_h), a1 = clampi(p->band_y - p->tick_gap, 0, p->fb_h);
    int b0 = clampi(p->band_y + p->band_h + p->tick_gap, 0, p->fb_h), b1 = clampi(b0 + p->tick_len, 0, p->fb_h);
    fill(fb, p->fb_w, x0, a0, x1, a1, p->tick_px);
    fill(fb, p->fb_w, x0, b0, x1, b1, p->tick_px);
}

int rsvp_paint(rsvp_painter_t *p, const rsvp_font_t *f, const char *word, size_t len,
               uint16_t *fb, uint16_t *scratch, size_t scratch_px, rsvp_rect_t *dirty, rsvp_layout_t *lay_out) {
    rsvp_rect_t none = { 0, 0, 0, 0 };
    if (dirty) *dirty = none;
    if (!p || !fb) return 0;
    rsvp_layout_t lay;
    rsvp_glyph_pos_t pos[MAX_PLACE];
    memset(&lay, 0, sizeof lay);
    bool have = f && word && len && rsvp_layout(f, word, len, p->orp_x, p->fb_w, p->margin, pos, MAX_PLACE, &lay) == RSVP_OK;
    if (lay_out) *lay_out = lay;
    const int band0 = p->band_y, band1 = p->band_y + p->band_h;
    int nx0 = 0, nx1 = 0;
    if (have) {
        nx0 = clampi(lay.x0, 0, p->fb_w);
        nx1 = clampi(lay.x1, 0, p->fb_w);
    }
    rsvp_rect_t d;
    if (p->full) {
        memset(fb, 0, (size_t)p->fb_w * (size_t)p->fb_h * 2u);
        draw_ticks(p, fb);
        d = rect_of(0, 0, p->fb_w, p->fb_h);
        p->full = false;
    } else {
        int cx0 = nx0, cx1 = nx1;
        if (p->last_x1 > p->last_x0) {
            if (cx1 <= cx0) { cx0 = p->last_x0; cx1 = p->last_x1; }
            else {
                if (p->last_x0 < cx0) cx0 = p->last_x0;
                if (p->last_x1 > cx1) cx1 = p->last_x1;
            }
        }
        if (cx1 > cx0) fill(fb, p->fb_w, cx0, band0, cx1, band1, 0);
        d = rect_of(cx0, band0, cx1, band1);
    }
    int failures = 0;
    if (have) {
        const rsvp_face_t *face = lay.face;
        int y = p->baseline_y - face->baseline;
        clip_t c = { 0, band0, p->fb_w, band1 };
        for (unsigned i = 0; i < lay.n; i++) {
            const hca_asset_t *atlas = pos[i].accent ? face->accent : face->white;
            if (!blit_glyph(face, atlas, pos[i].glyph, pos[i].x, y, 1, fb, p->fb_w, c, scratch, scratch_px)) failures++;
        }
    }
    p->last_x0 = (int16_t)nx0;
    p->last_x1 = (int16_t)nx1;
    if (dirty) *dirty = d;
    return failures;
}

/* ------------------------------------------------------------------------------------------ */
/* Text lines (end card, pause glyph)                                                         */

typedef struct { const rsvp_face_t *face; int div; } fsize_t;

/* Candidate sizes, largest output height first. Returns the count. */
static int sizes(const rsvp_font_t *f, fsize_t *out) {
    int n = 0;
    for (int div = 1; div <= 4; div++) {
        if (face_bound(f, false)) out[n++] = (fsize_t){ &f->normal, div };
        if (face_bound(f, true)) out[n++] = (fsize_t){ &f->compact, div };
    }
    for (int i = 1; i < n; i++) {   /* stable insertion sort by cell_h/div, descending */
        fsize_t s = out[i];
        int h = s.face->cell_h / s.div, j = i - 1;
        while (j >= 0 && out[j].face->cell_h / out[j].div < h) {
            out[j + 1] = out[j];
            j--;
        }
        out[j + 1] = s;
    }
    return n;
}

static int32_t line_width(const rsvp_face_t *face, const uint32_t *cps, size_t n, int div) {
    int32_t w = 0;
    for (size_t i = 0; i < n; i++) {
        uint16_t g, a;
        glyph_of(face, cps[i], &g, &a, NULL);
        w += a / div;
    }
    return w;
}

static int draw_line(const rsvp_face_t *face, bool accent, const uint32_t *cps, size_t n, int div, int x, int y,
                     uint16_t *fb, int fb_w, clip_t c, uint16_t *scratch, size_t scratch_px) {
    int missing = 0;
    for (size_t i = 0; i < n; i++) {
        uint16_t g, a;
        glyph_of(face, cps[i], &g, &a, &missing);
        blit_glyph(face, accent ? face->accent : face->white, g, x, y, div, fb, fb_w, c, scratch, scratch_px);
        x += a / div;
    }
    return missing;
}

size_t rsvp_end_card_text(uint32_t words, uint32_t minutes, char *out, size_t cap) {
    char num[24], tmp[16];
    int k = snprintf(tmp, sizeof tmp, "%lu", (unsigned long)words);
    size_t o = 0;
    for (int i = 0; i < k; i++) {
        if (i > 0 && (k - i) % 3 == 0) num[o++] = ' ';
        num[o++] = tmp[i];
    }
    num[o] = '\0';
    if (!out || cap == 0) return 0;
    int n = snprintf(out, cap, "%s word%s \xC2\xB7 %lu min", num, words == 1 ? "" : "s", (unsigned long)minutes);
    if (n < 0 || (size_t)n >= cap) {
        out[0] = '\0';
        return 0;
    }
    return (size_t)n;
}

int rsvp_paint_end_card(rsvp_painter_t *p, const rsvp_font_t *f, uint32_t words, uint32_t minutes,
                        uint16_t *fb, uint16_t *scratch, size_t scratch_px, rsvp_rect_t *dirty) {
    rsvp_rect_t none = { 0, 0, 0, 0 };
    if (dirty) *dirty = none;
    if (!p || !fb) return 0;
    memset(fb, 0, (size_t)p->fb_w * (size_t)p->fb_h * 2u);
    p->full = true;
    p->last_x0 = p->last_x1 = 0;
    if (dirty) *dirty = rect_of(0, 0, p->fb_w, p->fb_h);
    if (!f || !face_bound(f, false)) return 0;
    char text[64];
    rsvp_end_card_text(words, minutes, text, sizeof text);
    uint32_t l1[3] = { 'f', 'i', 'n' }, l2[64];
    size_t n2 = decode_word(text, strlen(text), l2, 64);
    fsize_t cand[8];
    int nc = sizes(f, cand);
    const int avail = p->fb_w - 2 * p->margin;
    fsize_t s1 = cand[nc - 1], s2 = cand[nc - 1];
    for (int i = nc - 1; i >= 0; i--) {   /* largest that fits (cand is sorted largest first) */
        if (line_width(cand[i].face, l1, 3, cand[i].div) <= avail) s1 = cand[i];
        if (line_width(cand[i].face, l2, n2, cand[i].div) <= avail) s2 = cand[i];
    }
    int h1 = s1.face->cell_h / s1.div, h2 = s2.face->cell_h / s2.div, gap = 10;
    int y1 = (p->fb_h - (h1 + gap + h2)) / 2, y2 = y1 + h1 + gap;
    int w1 = line_width(s1.face, l1, 3, s1.div), w2 = line_width(s2.face, l2, n2, s2.div);
    clip_t c = { 0, 0, p->fb_w, p->fb_h };
    int missing = draw_line(s1.face, true, l1, 3, s1.div, (p->fb_w - w1) / 2, y1, fb, p->fb_w, c, scratch, scratch_px);
    missing += draw_line(s2.face, false, l2, n2, s2.div, (p->fb_w - w2) / 2, y2, fb, p->fb_w, c, scratch, scratch_px);
    return missing;
}

/* 5x7 two-bar mark (column bitmaps, bit 0 = top row), drawn ×3. */
static const uint8_t k_pause5x7[5] = { 0x7F, 0x7F, 0x00, 0x7F, 0x7F };

void rsvp_paint_pause(const rsvp_painter_t *p, const rsvp_font_t *f, bool on, uint16_t *fb,
                      uint16_t *scratch, size_t scratch_px, rsvp_rect_t *dirty) {
    rsvp_rect_t none = { 0, 0, 0, 0 };
    if (dirty) *dirty = none;
    if (!p || !fb) return;
    rsvp_rect_t b = p->pause_box;
    if (b.w <= 0 || b.h <= 0) return;
    fill(fb, p->fb_w, b.x, b.y, b.x + b.w, b.y + b.h, 0);
    if (dirty) *dirty = b;
    if (!on) return;
    clip_t c = { b.x, b.y, b.x + b.w, b.y + b.h };
    if (f && face_bound(f, false)) {
        fsize_t cand[8];
        int nc = sizes(f, cand);
        for (int i = 0; i < nc; i++) {
            const rsvp_face_t *face = cand[i].face;
            int k = rsvp__face_find(face, 0x23F8);
            if (k < 0) continue;
            int w = face->map[k].advance / cand[i].div, h = face->cell_h / cand[i].div;
            if (w > b.w || h > b.h) continue;
            blit_glyph(face, face->accent, face->map[k].glyph, b.x + b.w - w, b.y, cand[i].div, fb, p->fb_w, c,
                       scratch, scratch_px);
            return;
        }
    }
    const int s = 3;
    const uint16_t px = rsvp__be(RSVP_PAUSE_COLOR);
    int x0 = b.x + b.w - 5 * s, y0 = b.y + (b.h - 7 * s) / 2;
    for (int col = 0; col < 5; col++) {
        for (int row = 0; row < 7; row++) {
            if (!(k_pause5x7[col] & (1u << row))) continue;
            int xa = clampi(x0 + col * s, c.x0, c.x1), xb = clampi(x0 + col * s + s, c.x0, c.x1);
            int ya = clampi(y0 + row * s, c.y0, c.y1), yb = clampi(y0 + row * s + s, c.y0, c.y1);
            if (xa < xb && ya < yb) fill(fb, p->fb_w, xa, ya, xb, yb, px);
        }
    }
}
