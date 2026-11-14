/* textlay.c — text layout: word wrap into centred lines, one column of <= 64 lines behind a <= 3-line window (rules in
 * textlay.h). */
#include <string.h>
#include "textlay.h"
#include "rsvp_internal.h"

/* A text normalised into entries: glyphs and separators (whitespace runs collapsed). Entry i is
 * cpk[i] = code point | kind << 24, with its advance in the face being tried in adv[i]. */
enum { E_GLYPH = 0, E_SPACE, E_GLUE, E_NL };

#define MAXE TEXTLAY_LAYOUT_TEXT_MAX       /* one entry per byte at most */

typedef struct {
    uint32_t *cpk;
    uint16_t *adv;
    int n;
} text_t;

static inline uint32_t CP(const text_t *nt, int i) { return nt->cpk[i] & 0xFFFFFFu; }
static inline int KIND(const text_t *nt, int i) { return (int)(nt->cpk[i] >> 24); }
static inline void SETKIND(text_t *nt, int i, int k) { nt->cpk[i] = (nt->cpk[i] & 0xFFFFFFu) | ((uint32_t)k << 24); }

/* Closing punctuation that a preceding space must not separate from its word, and opening punctuation
 * that must not be separated from the following word (French typography: "« Bonjour ! »"). */
static bool glue_before(uint32_t cp) {
    switch (cp) {
    case '!': case '?': case ':': case ';': case 0xBB /* » */: case 0x201D /* ” */: case 0x2026 /* … */:
    case 0x203A /* › */:
        return true;
    default:
        return false;
    }
}
static bool glue_after(uint32_t cp) { return cp == 0xAB /* « */ || cp == 0x201C /* “ */ || cp == 0x2039 /* ‹ */; }

/* A word may be broken after one of these when it does not fit. */
static bool break_after(uint32_t cp) {
    return cp == '-' || cp == '/' || cp == 0x2010 || cp == 0x2013 || cp == 0x2014;
}

static void push(text_t *nt, uint32_t cp, int kind) { nt->cpk[nt->n++] = (cp & 0xFFFFFFu) | ((uint32_t)kind << 24); }

static void normalise(const char *text, size_t len, text_t *nt) {
    if (len > TEXTLAY_LAYOUT_TEXT_MAX) len = TEXTLAY_LAYOUT_TEXT_MAX;
    nt->n = 0;
    int pending = 0;   /* 0 none, 1 space, 2 newline */
    bool pending_glue = false;
    size_t i = 0;
    while (i < len && nt->n < MAXE) {
        uint32_t cp;
        size_t k = rsvp_utf8_next(text + i, len - i, &cp);
        if (k == 0) break;
        i += k;
        int cls = rsvp__class(cp);
        if (cp == '\r') continue;
        if (cls == RC_NEWLINE || cls == RC_PARASEP) { pending = 2; continue; }
        if (cls == RC_SPACE) { if (pending < 1) pending = 1; continue; }
        if (cls == RC_JOIN) {   /* no-break space: a glued space */
            if (pending < 1) pending = 1;
            pending_glue = true;
            continue;
        }
        if (pending && nt->n > 0) {
            push(nt, ' ', pending == 2 ? E_NL : (pending_glue ? E_GLUE : E_SPACE));
            if (nt->n >= MAXE) break;
        }
        pending = 0;
        pending_glue = false;
        push(nt, cp, E_GLYPH);
    }
    /* French punctuation stays with its word. */
    for (int j = 0; j < nt->n; j++) {
        if (KIND(nt, j) != E_SPACE) continue;
        bool glue = (j + 1 < nt->n && KIND(nt, j + 1) == E_GLYPH && glue_before(CP(nt, j + 1))) ||
                    (j > 0 && KIND(nt, j - 1) == E_GLYPH && glue_after(CP(nt, j - 1)));
        if (glue) SETKIND(nt, j, E_GLUE);
    }
}

/* Atlas frame (or RSVP_GLYPH_NONE) and advance of code point cp; *missing counts '?' substitutions. */
static void glyph_of(const rsvp_face_t *f, uint32_t cp, uint16_t *glyph, uint16_t *adv, int *missing) {
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

static void measure(text_t *nt, const rsvp_face_t *f) {
    for (int i = 0; i < nt->n; i++) {
        if (KIND(nt, i) == E_GLYPH) {
            uint16_t g;
            glyph_of(f, CP(nt, i), &g, &nt->adv[i], NULL);
        } else {
            nt->adv[i] = f->space_adv;
        }
    }
}

static int32_t width(const text_t *nt, int a, int b) {
    int32_t w = 0;
    for (int i = a; i < b; i++) w += nt->adv[i];
    return w;
}

static bool is_sep(const text_t *nt, int i) { return KIND(nt, i) == E_SPACE || KIND(nt, i) == E_NL; }

static int skip_seps(const text_t *nt, int i) {
    while (i < nt->n && KIND(nt, i) != E_GLYPH) i++;
    return i;
}

/* Largest k in (a, b) such that w0 + width(a..k) <= maxw, preferring a break after a hyphen/dash/slash;
 * `glyph_ok`: else the largest glyph boundary (at least a+1). Returns -1 if none. */
static int split_point(const text_t *nt, int a, int b, int32_t w0, int32_t maxw, bool glyph_ok) {
    int best_h = -1, best_g = -1;
    int32_t w = w0;
    for (int k = a + 1; k < b; k++) {
        w += nt->adv[k - 1];
        if (w > maxw) break;
        best_g = k;
        if (KIND(nt, k - 1) == E_GLYPH && break_after(CP(nt, k - 1))) best_h = k;
    }
    if (best_h > 0) return best_h;
    if (!glyph_ok) return -1;
    return best_g > 0 ? best_g : a + 1;
}

/* Greedy wrap of entries [from, n), stopping once `stop` lines are complete and more text follows (the count
 * is then stop + 1). Line i covers [ls[i], le[i]) (separators at the breaks excluded); ls / le hold `cap`
 * lines (stop < cap). Returns the number of lines. */
static int wrap_cap(const text_t *nt, int from, int32_t maxw, int stop, int16_t *ls, int16_t *le, int cap) {
    int nl = 0, s = skip_seps(nt, from), i = s;
    int32_t w = 0;
#define CLOSE(a, b) do { if (nl < cap) { ls[nl] = (int16_t)(a); le[nl] = (int16_t)(b); } nl++; } while (0)
    while (i < nt->n) {
        if (nl >= stop) return nl + 1;   /* more lines follow */
        int j = i;
        while (j < nt->n && !is_sep(nt, j)) j++;
        int32_t ww = width(nt, i, j);
        if (i == s) {
            if (ww > maxw) {
                int k = split_point(nt, i, j, 0, maxw, true);
                CLOSE(s, k);
                if (k >= j && j < nt->n) k = j + 1;   /* one glyph wider than the line: skip its separator */
                s = i = skip_seps(nt, k);
                w = 0;
                continue;
            }
            w = ww;
        } else {
            const int32_t sp = nt->adv[i - 1];
            if (w + sp + ww > maxw) {
                int k = split_point(nt, i, j, w + sp, maxw, false);
                if (k > 0) {
                    CLOSE(s, k);
                    s = i = k;
                } else {
                    CLOSE(s, i - 1);
                    s = i;
                }
                w = 0;
                continue;
            }
            w += sp + ww;
        }
        if (j >= nt->n) {
            CLOSE(s, j);
            break;
        }
        if (KIND(nt, j) == E_NL) {
            CLOSE(s, j);
            s = i = skip_seps(nt, j + 1);
            w = 0;
        } else {
            i = j + 1;
        }
    }
#undef CLOSE
    return nl;
}

static int16_t clamp16(int32_t v) { return (int16_t)(v < INT16_MIN ? INT16_MIN : v > INT16_MAX ? INT16_MAX : v); }

/* Trim separators / glued spaces at both ends of [*a, *b). */
static void trim(const text_t *nt, int *a, int *b) {
    while (*a < *b && KIND(nt, *a) != E_GLYPH) (*a)++;
    while (*b > *a && KIND(nt, *b - 1) != E_GLYPH) (*b)--;
}

static void place_line(textlay_layout_t *out, const text_t *nt, int a, int b, const uint32_t *extra, int nextra,
                       const rsvp_face_t *f) {
    const int li = out->lines;
    textlay_line_t *L = &out->line[li];
    L->first = out->n;
    int32_t pen = 0;
    for (int i = a; i < b && out->n < TEXTLAY_MAX_GLYPHS; i++) {
        textlay_glyph_t *g = &out->g[out->n++];
        if (KIND(nt, i) == E_GLYPH) {
            glyph_of(f, CP(nt, i), &g->glyph, &g->advance, &out->missing);
        } else {
            g->glyph = RSVP_GLYPH_NONE;
            g->advance = f->space_adv;
        }
        g->x = clamp16(pen);
        g->line = (uint8_t)li;
        pen += g->advance;
    }
    for (int i = 0; i < nextra && out->n < TEXTLAY_MAX_GLYPHS; i++) {
        textlay_glyph_t *g = &out->g[out->n++];
        glyph_of(f, extra[i], &g->glyph, &g->advance, NULL);
        g->x = clamp16(pen);
        g->line = (uint8_t)li;
        pen += g->advance;
    }
    L->count = (uint16_t)(out->n - L->first);
    const int32_t room = out->screen_w - pen;
    const int32_t x0 = room >= 0 ? room / 2 : -((-room + 1) / 2);   /* floor(room / 2) */
    for (unsigned i = L->first; i < out->n; i++) out->g[i].x = clamp16(x0 + out->g[i].x);
    L->x0 = clamp16(x0);
    L->x1 = clamp16(x0 + pen);
    out->lines++;
}

/* The last line of a truncated text: entries [a, n) cut so that they end with "…" (or "...", or nothing if
 * the font has neither) within maxw, at a word boundary when that keeps >= 60 % of the room. */
static void place_cut_line(textlay_layout_t *out, const text_t *ntp, int a0, int32_t maxw, const rsvp_face_t *face) {
    const text_t nt = *ntp;
    uint32_t ell[3];
    int nell = 0;
    if (rsvp__face_find(face, 0x2026) >= 0) {
        ell[nell++] = 0x2026;
    } else if (rsvp__face_find(face, '.') >= 0) {
        ell[0] = ell[1] = ell[2] = '.';
        nell = 3;
    }
    int32_t ew = 0;
    for (int i = 0; i < nell; i++) {
        uint16_t g, a;
        glyph_of(face, ell[i], &g, &a, NULL);
        ew += a;
    }
    int a = a0, b = nt.n;
    trim(&nt, &a, &b);
    const int32_t room = maxw - ew;
    /* best cut at a word boundary, else between glyphs */
    int best_w = -1, best_g = a;
    int32_t w = 0, wbest_w = 0;
    for (int k = a + 1; k <= b; k++) {
        w += nt.adv[k - 1];
        if (w > room) break;
        if (KIND(&nt, k - 1) == E_GLYPH) best_g = k;
        if (k < b && is_sep(&nt, k) && KIND(&nt, k - 1) == E_GLYPH) {
            best_w = k;
            wbest_w = w;
        }
    }
    int cut = (best_w > a && wbest_w * 10 >= room * 6) ? best_w : best_g;
    int ca = a, cb = cut;
    trim(&nt, &ca, &cb);
    place_line(out, &nt, ca, cb, ell, nell, face);
}

static void begin_page(textlay_layout_t *out) {
    textlay_page_t *P = &out->page[out->pages];
    P->first_line = out->lines;
    P->first = out->n;
}

static int max_lines(const rsvp_face_t *f, int screen_h) {
    int m = f->cell_h ? screen_h / f->cell_h : 1;
    if (m > TEXTLAY_MAX_LINES) m = TEXTLAY_MAX_LINES;
    return m < 1 ? 1 : m;
}

/* Scroll style: the whole text at the normal face, <= TEXTLAY_SCROLL_MAX_LINES lines (the last one cut with "…"
 * beyond), one page whose block is the window: W lines centred vertically, block_y = (screen_h - W * pitch) / 2,
 * whatever the text's length (a short text starts on the window's top line); line tops continue below the
 * window (top_i = block_y + i * pitch). */
static void layout_scroll(textlay_layout_t *out, text_t *nt, int32_t maxw, int screen_h) {
    const rsvp_face_t *face = out->face;
    measure(nt, face);
    const int win = max_lines(face, screen_h);
    out->window = (uint8_t)win;
    int16_t ls[TEXTLAY_SCROLL_MAX_LINES + 1], le[TEXTLAY_SCROLL_MAX_LINES + 1];
    const int nl = wrap_cap(nt, 0, maxw, TEXTLAY_SCROLL_MAX_LINES, ls, le, TEXTLAY_SCROLL_MAX_LINES + 1);
    if (nl == 0) return;   /* blank text: pages = 0 */
    begin_page(out);
    const bool cut = nl > TEXTLAY_SCROLL_MAX_LINES;
    const int full = cut ? TEXTLAY_SCROLL_MAX_LINES - 1 : nl;
    for (int i = 0; i < full; i++) {
        int a = ls[i], b = le[i];
        trim(nt, &a, &b);
        place_line(out, nt, a, b, NULL, 0, face);
    }
    if (cut) {
        out->truncated = true;
        place_cut_line(out, nt, ls[TEXTLAY_SCROLL_MAX_LINES - 1], maxw, face);
    }
    textlay_page_t *P = &out->page[0];
    P->lines = (uint8_t)(out->lines - P->first_line);
    P->n = (uint16_t)(out->n - P->first);
    P->block_h = (int16_t)(win * out->pitch);   /* always the W-line window (the app mirrors this) */
    P->block_y = (int16_t)((screen_h - P->block_h) / 2);
    for (int i = 0; i < P->lines; i++) out->line[i].top = (int16_t)(P->block_y + i * out->pitch);
    out->pages = 1;
}

textlay_status_t textlay_layout_style(const rsvp_font_t *f, const char *text, size_t len, int screen_w, int screen_h,
                                      int margin, textlay_style_t style, textlay_layout_t *out) {
    if (!out) return TEXTLAY_ERR_ARG;
    memset(out, 0, offsetof(textlay_layout_t, g));
    if (!f || (!text && len) || screen_w < 1 || screen_h < 1 || screen_w > 4096 || screen_h > 4096 || margin < 0 ||
        !f->normal.white || !f->normal.accent || style != TEXTLAY_STYLE_SCROLL)
        return TEXTLAY_ERR_ARG;
    out->screen_w = (int16_t)screen_w;
    out->screen_h = (int16_t)screen_h;
    out->style = (uint8_t)style;
    text_t nt = { out->work.cpk, out->work.adv, 0 };
    normalise(text ? text : "", text ? len : 0, &nt);
    int32_t maxw = screen_w - 2 * margin;
    if (maxw < 1) maxw = 1;
    out->face = &f->normal;
    out->pitch = (int16_t)f->normal.cell_h;
    layout_scroll(out, &nt, maxw, screen_h);
    return TEXTLAY_OK;
}
