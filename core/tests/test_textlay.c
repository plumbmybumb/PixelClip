/* test_textlay.c — the text layout (textlay.h): wrapping rules, centring, the scroll-style window, the 64-line cap,
 * the Oracle's 900-byte paragraph, and a layout fuzz. */
#include "tharness.h"
#include "textlay.h"

#define FW 536
#define FH 240

/* ------------------------------------------------------------------------------------------ */
/* Test font: geometric glyphs whose pixels identify glyph and atlas                          */

static const char *k_glyphs[] = {
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
    "u", "v", "w", "x", "y", "z", "A", "B", "C", "E", "J", "L", "P", "T", "0", "1", "2", "3", "?", ".",
    ",", ";", ":", "!", "-", "'", "/",
    "\xE2\x80\x99" /* ’ */, "\xC3\xA9" /* é */, "\xC3\xA8" /* è */, "\xC3\xA0" /* à */, "\xC3\xAA" /* ê */,
    "\xC3\xA7" /* ç */, "\xC2\xAB" /* « */, "\xC2\xBB" /* » */, "\xE2\x80\xA6" /* … */, " ",
};
#define NG ((int)(sizeof k_glyphs / sizeof k_glyphs[0]))
#define G_ELLIPSIS (NG - 2)

typedef struct { uint16_t cw, ch, base, adv; } face_spec_t;
static const face_spec_t NORMAL = { 20, 40, 32, 18 };    /* 28 glyphs per 512 px line, a 3-line window */
static const face_spec_t COMPACT = { 12, 24, 19, 11 };   /* 46 glyphs per line (never used by the layout) */
static const face_spec_t TALL = { 20, 100, 80, 18 };     /* a 2-line window */

#define WHITE_TAG 0x8000u
#define ACCENT_TAG 0x4000u

static int adv_of(int g, const face_spec_t *fs) {
    const char *s = k_glyphs[g];
    if (!strcmp(s, "i") || !strcmp(s, "l") || !strcmp(s, ".") || !strcmp(s, ",") || !strcmp(s, "'")) return fs->adv / 2;
    if (!strcmp(s, "m") || !strcmp(s, "w")) return fs->adv + fs->adv / 2;
    return fs->adv;
}

static uint16_t tag_px(uint16_t tag, int g) { return (uint16_t)(tag | (uint16_t)(g + 1)); }

static uint8_t *build_atlas(const face_spec_t *fs, bool accent, size_t *size) {
    size_t npx = (size_t)fs->cw * fs->ch;
    uint16_t *px = calloc(npx * NG, 2);
    for (int g = 0; g < NG; g++) {
        uint16_t *f = px + npx * (size_t)g;
        if (!strcmp(k_glyphs[g], " ")) continue;
        int w = adv_of(g, fs) - 1;
        if (w > fs->cw) w = fs->cw;
        if (w < 1) w = 1;
        uint16_t c = th_be(tag_px(accent ? ACCENT_TAG : WHITE_TAG, g));
        for (int y = fs->base - fs->ch / 2; y < fs->base; y++)
            for (int x = 0; x < w; x++) f[(size_t)y * fs->cw + (size_t)x] = c;
    }
    size_t cap = npx * 2 * NG + 4096 + (size_t)NG * 16;
    uint8_t *out = malloc(cap);
    *size = th_build_hca(px, fs->cw, fs->ch, NG, HCA_COMP_RLE16, HCA_FLAG_GLYPH_ATLAS, NULL, out, cap);
    free(px);
    return out;
}

static size_t face_json(char *buf, size_t cap, const face_spec_t *fs, const char *white, const char *accent, bool ell) {
    size_t o = 0;
    o += (size_t)snprintf(buf + o, cap - o, "{\"glyphs\":\"");
    for (int g = 0; g < NG; g++) if (ell || g != G_ELLIPSIS) o += (size_t)snprintf(buf + o, cap - o, "%s", k_glyphs[g]);
    o += (size_t)snprintf(buf + o, cap - o, "\",\"advance\":[");
    bool first = true;
    for (int g = 0; g < NG; g++) {
        if (!ell && g == G_ELLIPSIS) continue;
        o += (size_t)snprintf(buf + o, cap - o, "%s%d", first ? "" : ",", adv_of(g, fs));
        first = false;
    }
    o += (size_t)snprintf(buf + o, cap - o, "],\"cell_w\":%u,\"cell_h\":%u,\"baseline\":%u,\"atlas_white\":\"%s\",\"atlas_accent\":\"%s\"",
                          fs->cw, fs->ch, fs->base, white, accent);
    return o;
}

typedef struct {
    rsvp_font_t font;
    uint8_t *d[4];
    hca_asset_t a[4];
    uint16_t *scratch;
    size_t scratch_px;
} tfont_t;

static void tfont_free(tfont_t *t) {
    for (int i = 0; i < 4; i++) free(t->d[i]);
    free(t->scratch);
    memset(t, 0, sizeof *t);
}

/* compact: the compact face spec (NULL = none). ell: the document lists '…' (the atlases always have the
 * full glyph list; without '…' the trailing " " maps to the '…' frame, harmless since spaces are never
 * drawn). */
static bool tfont_make(tfont_t *t, const face_spec_t *normal, const face_spec_t *compact, bool ell) {
    memset(t, 0, sizeof *t);
    char *j = malloc(8192);
    size_t o = face_json(j, 8192, normal, "tw", "ta", ell);
    if (compact) {
        o += (size_t)snprintf(j + o, 8192 - o, ",\"compact\":");
        o += face_json(j + o, 8192 - o, compact, "cw", "ca", ell);
        o += (size_t)snprintf(j + o, 8192 - o, "}");
    }
    snprintf(j + o, 8192 - o, "}");
    char err[80];
    rsvp_status_t st = rsvp_font_parse(j, strlen(j), &t->font, err, sizeof err);
    free(j);
    if (st != RSVP_OK) { fprintf(stderr, "font parse: %s\n", err); return false; }
    const face_spec_t *fs[4] = { normal, normal, compact ? compact : normal, compact ? compact : normal };
    for (int i = 0; i < 4; i++) {
        size_t n;
        t->d[i] = build_atlas(fs[i], i & 1, &n);
        if (hca_open(&t->a[i], t->d[i], n) != HCA_OK) return false;
    }
    st = rsvp_font_bind(&t->font, &t->a[0], &t->a[1], compact ? &t->a[2] : NULL, compact ? &t->a[3] : NULL);
    if (st != RSVP_OK) return false;
    t->scratch_px = rsvp_font_scratch_px(&t->font);
    t->scratch = malloc(t->scratch_px * 2);
    return true;
}

static int glyph_index(const char *s) {
    for (int g = 0; g < NG; g++) if (!strcmp(k_glyphs[g], s)) return g;
    return -1;
}


/* The text of layout line `li` reconstructed from the glyph frames ("_" for spaces). */
static void line_text(const textlay_layout_t *lay, int li, char *out, size_t cap) {
    size_t o = 0;
    out[0] = '\0';
    const textlay_line_t *L = &lay->line[li];
    for (unsigned i = L->first; i < (unsigned)L->first + L->count; i++) {
        uint16_t g = lay->g[i].glyph;
        const char *s = g == RSVP_GLYPH_NONE ? "_" : (g < NG ? k_glyphs[g] : "#");
        size_t k = strlen(s);
        if (o + k + 1 > cap) break;
        memcpy(out + o, s, k);
        o += k;
        out[o] = '\0';
    }
}

static int line_width(const textlay_layout_t *lay, int li) {
    int w = 0;
    const textlay_line_t *L = &lay->line[li];
    for (unsigned i = L->first; i < (unsigned)L->first + L->count; i++) w += lay->g[i].advance;
    return w;
}

/* Last glyph frame of line li (RSVP_GLYPH_NONE if empty). */
static uint16_t line_last(const textlay_layout_t *lay, int li) {
    const textlay_line_t *L = &lay->line[li];
    return L->count ? lay->g[L->first + L->count - 1].glyph : RSVP_GLYPH_NONE;
}

#define CHECK_LINE(lay, li, s) do { char _b[1200]; line_text(lay, li, _b, sizeof _b); th_checks++; \
    if (strcmp(_b, s)) { th_failures++; fprintf(stderr, "%s:%d: line %d \"%s\" != \"%s\"\n", __FILE__, __LINE__, li, _b, s); } } while (0)

#define MARGIN 12

static textlay_layout_t g_lay;   /* ~13 KB, static to keep the test stack small */

static textlay_status_t lay_text(const tfont_t *t, const char *s) {
    return textlay_layout_style(&t->font, s, strlen(s), FW, FH, MARGIN, TEXTLAY_STYLE_SCROLL, &g_lay);
}

/* ------------------------------------------------------------------------------------------ */
/* Layout                                                                                     */

/* Every invariant of a layout on a w_scr x h_scr screen: one page (none for a blank text) whose block is the window,
 * lines stacked from the window's top, each centred on its pen extent, glyphs in order, no space at either end. */
static void check_geometry_wh(const textlay_layout_t *lay, int w_scr, int h_scr, int margin) {
    CHECK_EQ(lay->style, TEXTLAY_STYLE_SCROLL);
    CHECK_EQ(lay->pitch, lay->face->cell_h);
    int win = lay->pitch ? h_scr / lay->pitch : 1;
    if (win > TEXTLAY_MAX_LINES) win = TEXTLAY_MAX_LINES;
    if (win < 1) win = 1;
    CHECK_EQ(lay->window, win);
    CHECK(lay->lines <= TEXTLAY_SCROLL_MAX_LINES);
    CHECK(lay->n <= TEXTLAY_MAX_GLYPHS);
    if (!lay->lines) {
        CHECK_EQ(lay->pages, 0);
        CHECK_EQ(lay->n, 0);
        return;
    }
    CHECK_EQ(lay->pages, 1);
    const textlay_page_t *P = &lay->page[0];
    CHECK_EQ(P->first_line, 0);
    CHECK_EQ(P->first, 0);
    CHECK_EQ(P->lines, lay->lines);
    CHECK_EQ(P->n, lay->n);
    CHECK_EQ(P->block_h, win * lay->pitch);
    CHECK_EQ(P->block_y, (h_scr - P->block_h) / 2);
    unsigned total = 0;
    for (int i = 0; i < lay->lines; i++) {
        const textlay_line_t *L = &lay->line[i];
        int w = line_width(lay, i);
        CHECK_EQ(L->x1 - L->x0, w);
        CHECK_EQ(L->x0, (w_scr - w) >= 0 ? (w_scr - w) / 2 : -((w - w_scr + 1) / 2));
        CHECK(w <= w_scr - 2 * margin || L->count == 1);
        CHECK_EQ(L->top, P->block_y + i * lay->pitch);
        CHECK_EQ(L->first, total);
        if (L->count) {
            CHECK_EQ(lay->g[L->first].x, L->x0);
            CHECK(lay->g[L->first].glyph != RSVP_GLYPH_NONE);                 /* no leading space */
            CHECK(lay->g[L->first + L->count - 1].glyph != RSVP_GLYPH_NONE);  /* no trailing space */
        }
        for (unsigned k = L->first; k + 1 < (unsigned)L->first + L->count; k++)
            CHECK_EQ(lay->g[k + 1].x, lay->g[k].x + lay->g[k].advance);
        for (unsigned k = L->first; k < (unsigned)L->first + L->count; k++) CHECK_EQ(lay->g[k].line, i);
        total += L->count;
    }
    CHECK_EQ(total, lay->n);
}
static void check_geometry(const textlay_layout_t *lay) { check_geometry_wh(lay, FW, FH, MARGIN); }

static void test_wrap_basic(void) {
    tfont_t t;
    CHECK(tfont_make(&t, &NORMAL, &COMPACT, true));
    CHECK_EQ(lay_text(&t, "le train part de la gare"), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 1);
    CHECK_EQ(g_lay.pages, 1);
    CHECK(!g_lay.truncated);
    CHECK_LINE(&g_lay, 0, "le_train_part_de_la_gare");
    CHECK(g_lay.face == &t.font.normal);
    CHECK_EQ(g_lay.pitch, 40);
    CHECK_EQ(g_lay.window, 3);
    CHECK_EQ(g_lay.page[0].block_y, (240 - 3 * 40) / 2);
    check_geometry(&g_lay);
    /* whitespace collapses and is trimmed */
    CHECK_EQ(lay_text(&t, "  le \t train   part  "), TEXTLAY_OK);
    CHECK_LINE(&g_lay, 0, "le_train_part");
    CHECK_EQ(g_lay.n, 13);
    /* two lines (28 glyphs of 18 px per line, i and l are narrow) */
    CHECK_EQ(lay_text(&t, "le train part de la gare et je ne peux pas le voir"), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 2);
    CHECK_LINE(&g_lay, 0, "le_train_part_de_la_gare_et");
    CHECK_LINE(&g_lay, 1, "je_ne_peux_pas_le_voir");
    check_geometry(&g_lay);
    CHECK_EQ(g_lay.line[1].first, g_lay.line[0].count);   /* glyph order follows the lines */
    /* three lines, French accents and apostrophes */
    const char *fr = "l\xE2\x80\x99" "\xC3\xA9t\xC3\xA9 dernier il a dit que la mer \xC3\xA9tait plus belle "
                     "\xC3\xA0 c\xC3\xB4t\xC3\xA9 du port de p\xC3\xAA" "che";
    CHECK_EQ(lay_text(&t, fr), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 3);
    CHECK_EQ(g_lay.pages, 1);
    CHECK_LINE(&g_lay, 0, "l\xE2\x80\x99\xC3\xA9t\xC3\xA9_dernier_il_a_dit_que_la");
    CHECK_EQ(g_lay.missing, 1);   /* ô is not in the font: '?' */
    check_geometry(&g_lay);
    /* empty and blank */
    CHECK_EQ(lay_text(&t, ""), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 0);
    CHECK_EQ(g_lay.pages, 0);
    CHECK_EQ(g_lay.n, 0);
    check_geometry(&g_lay);
    CHECK_EQ(lay_text(&t, " \n \t "), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 0);
    /* hard line break */
    CHECK_EQ(lay_text(&t, "le quai\nun n\xC5\x93ud"), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 2);
    CHECK_LINE(&g_lay, 0, "le_quai");
    CHECK_EQ(g_lay.line[1].count, 7);
    check_geometry(&g_lay);
    /* CRLF and blank lines collapse into one break */
    CHECK_EQ(lay_text(&t, "a\r\n\r\n\r\nb"), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 2);
    /* bad arguments */
    CHECK_EQ(textlay_layout_style(NULL, "a", 1, FW, FH, 12, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_ERR_ARG);
    CHECK_EQ(textlay_layout_style(&t.font, NULL, 1, FW, FH, 12, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_ERR_ARG);
    CHECK_EQ(textlay_layout_style(&t.font, "a", 1, 0, FH, 12, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_ERR_ARG);
    CHECK_EQ(textlay_layout_style(&t.font, "a", 1, FW, FH, -1, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_ERR_ARG);
    CHECK_EQ(textlay_layout_style(&t.font, "a", 1, FW, FH, 12, (textlay_style_t)1, &g_lay), TEXTLAY_ERR_ARG);
    CHECK_EQ(textlay_layout_style(&t.font, "a", 1, FW, FH, 12, TEXTLAY_STYLE_SCROLL, NULL), TEXTLAY_ERR_ARG);
    rsvp_font_t unbound = t.font;
    unbound.normal.white = NULL;
    CHECK_EQ(textlay_layout_style(&unbound, "a", 1, FW, FH, 12, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_ERR_ARG);
    tfont_free(&t);
}

static void test_wrap_french_punct(void) {
    tfont_t t;
    CHECK(tfont_make(&t, &NORMAL, &COMPACT, true));
    CHECK_EQ(lay_text(&t, "il faut que je le dise : le train de nuit est en retard !"), TEXTLAY_OK);
    CHECK(g_lay.lines >= 2);
    for (int i = 0; i < g_lay.lines; i++) {
        uint16_t first = g_lay.g[g_lay.line[i].first].glyph;
        CHECK(first != glyph_index("!") && first != glyph_index(":"));
    }
    check_geometry(&g_lay);
    const char *q = "il a dit \xC2\xAB le train repart dans dix minutes \xC2\xBB et c'est vrai";
    CHECK_EQ(lay_text(&t, q), TEXTLAY_OK);
    CHECK(g_lay.lines >= 2);
    for (int i = 0; i < g_lay.lines; i++) {
        CHECK(line_last(&g_lay, i) != glyph_index("\xC2\xAB"));                      /* « never ends a line */
        CHECK(g_lay.g[g_lay.line[i].first].glyph != glyph_index("\xC2\xBB"));         /* » never starts one */
    }
    check_geometry(&g_lay);
    const char *nb = "aaaaaaaaaaaaaaaaaaaaaaa bonjour\xC2\xA0!";   /* no-break space joins "!" */
    CHECK_EQ(lay_text(&t, nb), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 2);
    CHECK_LINE(&g_lay, 1, "bonjour_!");
    tfont_free(&t);
}

static void test_wrap_long_words(void) {
    tfont_t t;
    CHECK(tfont_make(&t, &NORMAL, NULL, true));
    CHECK_EQ(lay_text(&t, "aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd"), TEXTLAY_OK);   /* 40 glyphs: 28 + 12 */
    CHECK_EQ(g_lay.lines, 2);
    CHECK_EQ(g_lay.line[0].count, 28);
    CHECK_EQ(g_lay.line[1].count, 12);
    check_geometry(&g_lay);
    CHECK_EQ(lay_text(&t, "je suis toute aujourd'hui-peut-etre"), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 2);
    CHECK_LINE(&g_lay, 0, "je_suis_toute_aujourd'hui-");
    CHECK_LINE(&g_lay, 1, "peut-etre");
    check_geometry(&g_lay);
    CHECK_EQ(lay_text(&t, "oui aaaaaaaaaabbbbbbbbbbccccc"), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 2);
    CHECK_LINE(&g_lay, 0, "oui");
    CHECK_EQ(g_lay.line[1].count, 25);
    tfont_free(&t);
}

static void test_centring(void) {
    tfont_t t;
    CHECK(tfont_make(&t, &NORMAL, &COMPACT, true));
    for (int len = 1; len <= 28; len++) {
        char s[40];
        memset(s, 'a', (size_t)len);
        s[len] = '\0';
        CHECK_EQ(lay_text(&t, s), TEXTLAY_OK);
        CHECK_EQ(g_lay.lines, 1);
        CHECK_EQ(g_lay.line[0].x0, (FW - 18 * len) / 2);
        int left = g_lay.line[0].x0, right = FW - g_lay.line[0].x1;
        CHECK(right - left == 0 || right - left == 1);
    }
    /* the window (3 lines) is centred whatever the number of lines: a short text starts on its top line */
    const char *txt[4] = { "a", "a\nb", "a\nb\nc", "a\nb\nc\nd" };
    for (int k = 0; k < 4; k++) {
        CHECK_EQ(lay_text(&t, txt[k]), TEXTLAY_OK);
        CHECK_EQ(g_lay.lines, k + 1);
        CHECK_EQ(g_lay.line[0].top, (FH - 3 * g_lay.pitch) / 2);
        int top = g_lay.page[0].block_y, bottom = FH - (g_lay.page[0].block_y + g_lay.page[0].block_h);
        CHECK(bottom - top == 0 || bottom - top == 1);
    }
    CHECK_EQ(textlay_layout_style(&t.font, "abc", 3, 300, 100, 10, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_OK);
    CHECK_EQ(g_lay.line[0].x0, (300 - 54) / 2);
    CHECK_EQ(g_lay.window, 2);
    CHECK_EQ(g_lay.page[0].block_y, (100 - 80) / 2);
    check_geometry_wh(&g_lay, 300, 100, 10);
    tfont_free(&t);
}

/* ------------------------------------------------------------------------------------------ */
/* Long texts                                                                                 */

/* A face shaped like a real reader font: cells much wider than the advance (accented capitals, '…', '—'),
 * ~22 glyphs per line, 72 px lines; compact ~31 glyphs per line. */
static const face_spec_t REALF = { 64, 72, 52, 22 };
static const face_spec_t REALC = { 44, 50, 36, 16 };

/* 599 bytes of French prose (accents, apostrophes, guillemets, punctuation). */
static const char *k_prose600 =
    "Le train de sept heures quitte la gare sous une pluie fine. Dans le wagon, les voyageurs lisent, dorment "
    "ou regardent passer les champs encore gris. \xC3\x80 Dijon, une femme monte avec un v\xC3\xA9lo "
    "pli\xC3\xA9 et s\xE2\x80\x99" "excuse en riant. Le contr\xC3\xB4leur annonce \xC2\xAB dix minutes de "
    "retard \xC2\xBB et personne ne proteste vraiment : le caf\xC3\xA9 est chaud, les fen\xC3\xAAtres sont "
    "propres, le paysage change. Plus loin, la Sa\xC3\xB4ne brille entre les arbres, puis les vignes "
    "apparaissent, rang\xC3\xA9" "es comme des lignes d\xE2\x80\x99\xC3\xA9" "criture. Un enfant compte les "
    "ponts \xC3\xA0 voix haute. \xC3\x80 midi, le soleil revient enfin, et le train entre en gare de Lyon.";

/* n lines of "ab cd" separated by hard breaks. */
static void lines_text(char *buf, size_t cap, int n) {
    size_t o = 0;
    buf[0] = '\0';
    for (int i = 0; i < n && o + 8 < cap; i++) o += (size_t)snprintf(buf + o, cap - o, "%sab cd", i ? "\n" : "");
}

static void test_scroll_layout(void) {
    tfont_t t;
    CHECK(tfont_make(&t, &REALF, &REALC, true));
    CHECK(strlen(k_prose600) >= 560 && strlen(k_prose600) <= 600);
    CHECK_EQ(lay_text(&t, k_prose600), TEXTLAY_OK);
    CHECK(g_lay.face == &t.font.normal);   /* the compact face is never used */
    CHECK_EQ(g_lay.pages, 1);
    CHECK_EQ(g_lay.window, 3);
    CHECK(!g_lay.truncated);
    CHECK_EQ(g_lay.page[0].lines, g_lay.lines);
    CHECK_EQ(g_lay.page[0].n, g_lay.n);
    CHECK(g_lay.lines > 20);
    CHECK_EQ(g_lay.page[0].block_h, 3 * 72);
    CHECK_EQ(g_lay.page[0].block_y, (FH - 3 * 72) / 2);
    check_geometry(&g_lay);
    /* every glyph of the text is placed: the count of non-space glyphs equals the text's */
    {
        int vis = 0, want = 0;
        for (unsigned i = 0; i < g_lay.n; i++) vis += g_lay.g[i].glyph != RSVP_GLYPH_NONE;
        for (size_t i = 0; i < strlen(k_prose600);) {
            uint32_t cp;
            i += rsvp_utf8_next(k_prose600 + i, strlen(k_prose600) - i, &cp);
            want += cp != ' ';
        }
        CHECK_EQ(vis, want);
    }
    /* short texts: the window is still 3 lines */
    CHECK_EQ(lay_text(&t, "le quai"), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 1);
    CHECK_EQ(g_lay.page[0].block_h, 3 * 72);
    CHECK_EQ(g_lay.line[0].top, (FH - 3 * 72) / 2);
    CHECK_EQ(lay_text(&t, "   "), TEXTLAY_OK);
    CHECK_EQ(g_lay.pages, 0);
    /* 64-line cap: the 64th line ends with "…" */
    char buf[700];
    lines_text(buf, sizeof buf, 64);
    CHECK_EQ(lay_text(&t, buf), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, 64);
    CHECK(!g_lay.truncated);
    check_geometry(&g_lay);
    char more[TEXTLAY_LAYOUT_TEXT_MAX + 1] = "";
    for (int i = 0; i < 100; i++) strcat(more, i ? "\nab" : "ab");
    CHECK_EQ(lay_text(&t, more), TEXTLAY_OK);
    CHECK_EQ(g_lay.lines, TEXTLAY_SCROLL_MAX_LINES);
    CHECK(g_lay.truncated);
    CHECK_EQ(line_last(&g_lay, 63), G_ELLIPSIS);
    CHECK_LINE(&g_lay, 62, "ab");
    check_geometry(&g_lay);
    /* a font whose cell is taller than a third of the screen: a 2-line window */
    tfont_t tall;
    CHECK(tfont_make(&tall, &TALL, NULL, true));
    CHECK_EQ(lay_text(&tall, "un deux trois quatre cinq six sept huit neuf dix onze douze treize quatorze"), TEXTLAY_OK);
    CHECK_EQ(g_lay.window, 2);
    CHECK_EQ(g_lay.page[0].block_y, (FH - 200) / 2);
    check_geometry(&g_lay);
    tfont_free(&tall);
    /* a font without '…' ends a truncated text with "..." */
    CHECK(tfont_make(&tall, &TALL, NULL, false));
    CHECK_EQ(lay_text(&tall, more), TEXTLAY_OK);
    CHECK(g_lay.truncated);
    const int dot = glyph_index(".");
    CHECK_EQ(g_lay.g[g_lay.n - 1].glyph, dot);
    CHECK_EQ(g_lay.g[g_lay.n - 2].glyph, dot);
    CHECK_EQ(g_lay.g[g_lay.n - 3].glyph, dot);
    tfont_free(&tall);
    tfont_free(&t);
}

/* The Oracle's paragraph (PROTOCOL §5f.1): up to TEXTLAY_LAYOUT_TEXT_MAX = 900 bytes laid out whole; past that the
 * rest is not used. */
static void test_paragraph_900(void) {
    tfont_t t;
    CHECK(tfont_make(&t, &NORMAL, NULL, true));
    static const char k_words[] = "le train part de la gare ";
    const size_t wl = sizeof k_words - 1;
    char text[TEXTLAY_LAYOUT_TEXT_MAX + 64] = "";
    while (strlen(text) + wl < TEXTLAY_LAYOUT_TEXT_MAX) strcat(text, k_words);
    const size_t len = strlen(text) - 1;   /* ~875 bytes, no trailing space */
    CHECK(len > 600 && len <= TEXTLAY_LAYOUT_TEXT_MAX);
    CHECK_EQ(textlay_layout_style(&t.font, text, len, FW, FH, MARGIN, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_OK);
    CHECK(!g_lay.truncated);
    unsigned spaces = 0;
    for (size_t i = 0; i < len; i++) spaces += text[i] == ' ';
    CHECK(g_lay.n + g_lay.lines - 1 >= (unsigned)(len - spaces));   /* every letter placed (line-break spaces dropped) */
    CHECK(g_lay.lines <= TEXTLAY_SCROLL_MAX_LINES);
    check_geometry(&g_lay);
    /* beyond 900 bytes: only the first 900 are laid out */
    const unsigned n900 = g_lay.n;
    strcat(text, k_words);
    strcat(text, k_words);
    CHECK(strlen(text) > TEXTLAY_LAYOUT_TEXT_MAX);
    CHECK_EQ(textlay_layout_style(&t.font, text, strlen(text), FW, FH, MARGIN, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_OK);
    CHECK(g_lay.n >= n900 && g_lay.n <= n900 + (TEXTLAY_LAYOUT_TEXT_MAX - len));
    printf("     paragraph %zu B: %u lines, %u glyphs\n", len, (unsigned)g_lay.lines, (unsigned)n900);
    tfont_free(&t);
}

/* ------------------------------------------------------------------------------------------ */
/* Fuzz                                                                                       */

static int fuzz_scale(void) {
    const char *s = getenv("TEXTLAY_FUZZ_SCALE");
    int v = s ? atoi(s) : 1;
    return v < 1 ? 1 : v;
}

static void test_fuzz_layout(void) {
    tfont_t t[3];
    CHECK(tfont_make(&t[0], &NORMAL, &COMPACT, true));
    CHECK(tfont_make(&t[1], &TALL, NULL, false));
    CHECK(tfont_make(&t[2], &REALF, &REALC, true));
    static const char *frags[] = { "a", "mm", "é", "à", "’", "«", "»", "!", " ", " ", " ", "\n", "-", "\xC2\xA0", "\xff",
                                   "\xE2\x80\xA6", "\t", "\r", "w", "ô", "\xF0\x9F\x92\x96", ".", "/" };
    const int nf = (int)(sizeof frags / sizeof frags[0]);
    for (int it = 0; it < 3000 * fuzz_scale(); it++) {
        char s[TEXTLAY_LAYOUT_TEXT_MAX + 64];
        size_t n = 0;
        size_t want = th_rand() % (TEXTLAY_LAYOUT_TEXT_MAX + 41);
        while (n < want) {
            const char *f = frags[th_rand() % nf];
            size_t k = strlen(f);
            if (n + k > sizeof s) break;
            memcpy(s + n, f, k);
            n += k;
        }
        const tfont_t *tf = &t[th_rand() % 3];
        int w = 100 + (int)(th_rand() % 437), h = 30 + (int)(th_rand() % 211), margin = (int)(th_rand() % 20);
        char *heap = malloc(n ? n : 1);   /* exact size: the sanitizer catches any read past len */
        memcpy(heap, s, n);
        CHECK_EQ(textlay_layout_style(&tf->font, heap, n, w, h, margin, TEXTLAY_STYLE_SCROLL, &g_lay), TEXTLAY_OK);
        free(heap);
        check_geometry_wh(&g_lay, w, h, margin);
    }
    for (int i = 0; i < 3; i++) tfont_free(&t[i]);
}

int main(void) {
    RUN(test_wrap_basic);
    RUN(test_wrap_french_punct);
    RUN(test_wrap_long_words);
    RUN(test_centring);
    RUN(test_scroll_layout);
    RUN(test_paragraph_900);
    RUN(test_fuzz_layout);
    return TH_DONE("test_textlay");
}
