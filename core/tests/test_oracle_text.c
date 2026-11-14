/* test_oracle_text.c — the Oracle's text screens from glyph atlases (include/oracle_text.h, PROTOCOL §5f.2): column
 * geometry, colours (white / accent atlases), the face block, the question's lead-in, reading pages and their dots,
 * the page counts of the real readings, and the cost of a text screen. The test font (copied from test_textlay.c) makes
 * every pixel name its glyph and atlas. */
#include "tharness.h"
#include "oracle_text.h"
#include "oracle_reader.h"
#include "oracle.h"
#include <time.h>

#ifndef ORR_FIXTURES
#define ORR_FIXTURES "core/fixtures/tarot"
#endif

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
    uint8_t *d[6];
    hca_asset_t a[6];
    uint16_t *scratch;
    size_t scratch_px;
} tfont_t;

static void tfont_free(tfont_t *t) {
    for (int i = 0; i < 6; i++) free(t->d[i]);
    free(t->scratch);
    memset(t, 0, sizeof *t);
}

/* compact: the compact face spec (NULL = none). ell: the document lists '…' (the atlases always have the
 * full glyph list; without '…' the trailing " " maps to the '…' frame, harmless since spaces are never
 * drawn). */
static bool tfont_make3(tfont_t *t, const face_spec_t *normal, const face_spec_t *compact, const face_spec_t *large,
                        bool ell) {
    memset(t, 0, sizeof *t);
    char *j = malloc(8192);
    size_t o = face_json(j, 8192, normal, "tw", "ta", ell);
    if (compact) {
        o += (size_t)snprintf(j + o, 8192 - o, ",\"compact\":");
        o += face_json(j + o, 8192 - o, compact, "cw", "ca", ell);
        o += (size_t)snprintf(j + o, 8192 - o, "}");
    }
    if (large) {
        o += (size_t)snprintf(j + o, 8192 - o, ",\"large\":");
        o += face_json(j + o, 8192 - o, large, "lw", "la", ell);
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
    if (large) {
        for (int i = 4; i < 6; i++) {
            size_t n;
            t->d[i] = build_atlas(large, i & 1, &n);
            if (hca_open(&t->a[i], t->d[i], n) != HCA_OK) return false;
        }
        if (rsvp_font_bind_large(&t->font, &t->a[4], &t->a[5]) != RSVP_OK) return false;
    }
    t->scratch_px = rsvp_font_scratch_px(&t->font);
    t->scratch = malloc(t->scratch_px * 2);
    return true;
}

static bool tfont_make(tfont_t *t, const face_spec_t *normal, const face_spec_t *compact, bool ell) {
    return tfont_make3(t, normal, compact, NULL, ell);
}


static const face_spec_t BODY = { 16, 30, 23, 12 };   /* ~24 px body: 29 glyphs per 352 px line, 8 rows */
static const face_spec_t BIG = { 40, 72, 58, 36 };    /* the numeral */

static uint16_t s_fb[OT_SCREEN_W * OT_SCREEN_H];
static textlay_layout_t s_work;
static tfont_t s_body, s_big;
static uint16_t *s_scratch;

static ot_fonts_t fonts(bool big)
{
    return (ot_fonts_t){ .body = &s_body.font, .big = big ? &s_big.font : NULL, .scratch = s_scratch,
                         .scratch_px = s_big.scratch_px > s_body.scratch_px ? s_big.scratch_px : s_body.scratch_px,
                         .work = &s_work };
}

typedef struct { int white, accent, other, x0, x1, y0, y1; } census_t;

/* Pixels of the frame by kind, and the bounding box of the glyph pixels. */
static census_t census(int xa, int xb)
{
    census_t c = { 0, 0, 0, OT_SCREEN_W, -1, OT_SCREEN_H, -1 };
    for (int y = 0; y < OT_SCREEN_H; y++)
        for (int x = xa; x < xb; x++) {
            const uint16_t v = s_fb[y * OT_SCREEN_W + x];
            if (!v) continue;
            const uint16_t n = (uint16_t)((v >> 8) | (v << 8));   /* back to native */
            if (n & WHITE_TAG) c.white++;
            else if (n & ACCENT_TAG) c.accent++;
            else { c.other++; continue; }
            if (x < c.x0) c.x0 = x;
            if (x > c.x1) c.x1 = x;
            if (y < c.y0) c.y0 = y;
            if (y > c.y1) c.y1 = y;
        }
    return c;
}

static void fill_fb(uint16_t v) { for (size_t i = 0; i < sizeof s_fb / 2; i++) s_fb[i] = v; }

static void test_prompt(void)
{
    ot_fonts_t f = fonts(false);
    fill_fb(0x1234);
    const char *t = "secoue-moi, ou appuie : une carte attend";
    CHECK_EQ(ot_draw_prompt(&f, t, strlen(t), s_fb), 0);
    census_t c = census(OT_CLEAR_X0, OT_SCREEN_W);
    CHECK(c.white > 0 && c.accent == 0 && c.other == 0);   /* the column was cleared, white glyphs only */
    CHECK(c.x0 >= OT_COL_X0 && c.x1 < OT_COL_X1);
    CHECK(abs((c.x0 + c.x1) / 2 - (OT_COL_X0 + OT_COL_X1) / 2) <= 12);   /* centred in the column */
    CHECK(abs((c.y0 + c.y1) / 2 - OT_SCREEN_H / 2) <= 20);
    CHECK(c.y0 >= OT_TEXT_Y0 && c.y1 < OT_TEXT_Y1);
    CHECK_EQ(s_fb[100 * OT_SCREEN_W + 50], 0x1234);   /* left of the column: untouched (the slot is the caller's) */
    /* §5f.9: a prompt too tall to be centred above the hint band is moved up, never into it */
    char lg[400] = "";
    while (strlen(lg) < 200) strcat(lg, "pense a ta question puis appuie ");
    CHECK_EQ(ot_draw_prompt(&f, lg, strlen(lg), s_fb), 0);
    c = census(OT_CLEAR_X0, OT_SCREEN_W);
    CHECK(c.white > 0 && c.y0 >= OT_TEXT_Y0 && c.y1 < OT_TEXT_Y1);   /* §5f.9: rows 20..219 only */
    CHECK_EQ(ot_draw_prompt(NULL, t, 3, s_fb), -1);
    CHECK_EQ(ot_draw_prompt(&f, "", 0, s_fb), 0);
    CHECK(census(OT_CLEAR_X0, OT_SCREEN_W).white == 0);
}

static void test_face(void)
{
    ot_fonts_t f = fonts(true);
    CHECK_EQ(ot_draw_face(&f, "XIII", 4, "LE BATELEVR", 11, "Potentiel", 9, s_fb), 0);
    census_t c = census(OT_CLEAR_X0, OT_SCREEN_W);
    CHECK(c.accent > 0 && c.white > 0);
    /* the numeral (accent) above the name and keyword (white) */
    int acc_y1 = -1, wht_y0 = OT_SCREEN_H;
    for (int y = 0; y < OT_SCREEN_H; y++)
        for (int x = OT_CLEAR_X0; x < OT_SCREEN_W; x++) {
            const uint16_t v = s_fb[y * OT_SCREEN_W + x];
            const uint16_t n = (uint16_t)((v >> 8) | (v << 8));
            if (v && (n & ACCENT_TAG) && y > acc_y1) acc_y1 = y;
            if (v && (n & WHITE_TAG) && y < wht_y0) wht_y0 = y;
        }
    CHECK(acc_y1 < wht_y0);
    const int h_full = c.y1 - c.y0;
    /* XIII: no printed name, one body row less */
    CHECK_EQ(ot_draw_face(&f, "XIII", 4, "", 0, "Transformation", 14, s_fb), 0);
    census_t c2 = census(OT_CLEAR_X0, OT_SCREEN_W);
    CHECK(h_full - (c2.y1 - c2.y0) >= BODY.ch - 2);
    /* without a big font the numeral uses the body font */
    f = fonts(false);
    CHECK_EQ(ot_draw_face(&f, "XIII", 4, "", 0, "", 0, s_fb), 0);
    census_t c3 = census(OT_CLEAR_X0, OT_SCREEN_W);
    CHECK(c3.accent > 0 && c3.white == 0 && c3.y1 - c3.y0 < BODY.ch);
}

static void test_question(void)
{
    ot_fonts_t f = fonts(false);
    const char *lead = "Le Tarot te demande :";
    const char *q = "de toutes tes possibilites, laquelle veux-tu rendre reelle ? et pourquoi pas aujourd'hui ?";
    CHECK_EQ(ot_draw_question(&f, lead, strlen(lead), q, strlen(q), s_fb), 0);
    census_t c = census(OT_CLEAR_X0, OT_SCREEN_W);
    CHECK(c.accent > 0 && c.white > 0);
    /* the lead-in (accent) is the first row */
    for (int y = 0; y < OT_SCREEN_H; y++)
        for (int x = OT_CLEAR_X0; x < OT_SCREEN_W; x++) {
            const uint16_t v = s_fb[y * OT_SCREEN_W + x];
            const uint16_t n = (uint16_t)((v >> 8) | (v << 8));
            if (v && (n & ACCENT_TAG)) CHECK(y < c.y0 + BODY.ch);
        }
    /* a question longer than the screen: rows that do not fit are dropped, nothing drawn out of the panel */
    char big[2000] = "";
    while (strlen(big) < 1500) strcat(big, "encore une question sans fin ");
    CHECK_EQ(ot_draw_question(&f, lead, strlen(lead), big, strlen(big), s_fb), 0);
    census_t c2 = census(OT_CLEAR_X0, OT_SCREEN_W);
    CHECK(c2.y0 >= 0 && c2.y1 < OT_SCREEN_H);
}

static int dots(unsigned *current)
{
    int n = 0;
    *current = 99;
    const uint16_t on = th_be(TEXTLAY_CURSOR_COLOR), off = th_be(TEXTLAY_BAR_DIM_COLOR);
    for (int y = 0; y < OT_SCREEN_H; y++) {
        const uint16_t v = s_fb[y * OT_SCREEN_W + OT_DOT_X];
        if ((v == on || v == off) && (y == 0 || s_fb[(y - 1) * OT_SCREEN_W + OT_DOT_X] != v)) {
            if (v == on) *current = (unsigned)n;
            n++;
        }
    }
    return n;
}

static void test_reading_pages(void)
{
    ot_fonts_t f = fonts(false);
    ot_info_t in;
    /* short: one page, no dots */
    CHECK_EQ(ot_draw_reading(&f, "un seul souffle.", 16, 0, s_fb, &in), 0);
    CHECK(in.pages == 1 && in.lines == 1 && !in.truncated);
    unsigned cur;
    CHECK_EQ(dots(&cur), 0);
    /* ~6 lines: two pages, the same block position on both, dots 2 with the current one lit */
    char t[3000] = "";
    while (strlen(t) < 29 * 6 - 30) strcat(t, "le vent passe sur la ville ");
    const size_t n6 = strlen(t) - 1;
    CHECK_EQ(ot_reading_info(&f, t, n6, &in), 0);
    CHECK_EQ(in.pages, 2);
    CHECK_EQ(ot_draw_reading(&f, t, n6, 0, s_fb, NULL), 0);
    census_t p0 = census(OT_CLEAR_X0, OT_DOT_X - 2);
    CHECK_EQ(dots(&cur), 2);
    CHECK_EQ(cur, 0);
    CHECK_EQ(ot_draw_reading(&f, t, n6, 1, s_fb, NULL), 0);
    census_t p1 = census(OT_CLEAR_X0, OT_DOT_X - 2);
    CHECK_EQ(dots(&cur), 2);
    CHECK_EQ(cur, 1);
    CHECK_EQ(p0.y0, p1.y0);                    /* the block does not jump */
    CHECK(p1.y1 < p0.y1);                     /* page 2 has fewer rows */
    CHECK(p0.y1 - p0.y0 < OT_PAGE_LINES * BODY.ch);
    CHECK_EQ(ot_draw_reading(&f, t, n6, 7, s_fb, NULL), 0);   /* clamped to the last page */
    CHECK_EQ(dots(&cur), 2);
    CHECK_EQ(cur, 1);
    /* ~22 lines: 6 pages (§5f.3), dots 6 */
    while (strlen(t) < 29 * 22 - 30) strcat(t, "le vent passe sur la ville ");
    CHECK_EQ(ot_reading_info(&f, t, strlen(t) - 1, &in), 0);
    CHECK(in.pages == 6 && !in.truncated && in.per_page == OT_PAGE_LINES);
    CHECK_EQ(ot_draw_reading(&f, t, strlen(t) - 1, 5, s_fb, NULL), 0);
    CHECK_EQ(dots(&cur), 6);
    CHECK_EQ(cur, 5);
    /* more than 24 lines: 6 pages, truncated */
    while (strlen(t) < 29 * 30) strcat(t, "le vent passe sur la ville ");
    CHECK_EQ(ot_reading_info(&f, t, strlen(t) - 1, &in), 0);
    CHECK(in.pages == 6 && in.truncated && in.lines > 24);
}

static char *slurp(const char *name, size_t *len)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", ORR_FIXTURES, name);
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;
    fseek(fp, 0, SEEK_END);
    const long n = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    char *p = malloc((size_t)n + 1);
    if (p && fread(p, 1, (size_t)n, fp) != (size_t)n) { free(p); p = NULL; }
    fclose(fp);
    if (p) { p[n] = '\0'; *len = (size_t)n; }
    return p;
}

/* The real bundles: every card has a reading of 1..3 pages at the body size, a printed name (but XIII), a prompt and
 * a lead-in; the cost of each text screen (host). */
static void test_real_bundles(void)
{
    const char *names[2] = { "reader-fr.txt", "reader-en.txt" };
    ot_fonts_t f = fonts(true);
    for (int l = 0; l < 2; l++) {
        size_t len = 0;
        char *text = slurp(names[l], &len);
        CHECK(text != NULL);
        if (!text) continue;
        const size_t need = orr_arena_bytes(text, len);
        void *ar = malloc(need);
        orr_bundle_t *b = orr_parse(text, len, ar, need);
        CHECK(b != NULL);
        size_t n;
        const char *pr0 = orr_prompt(b, &n);
        CHECK(n > 0);
        size_t na;
        const char *pa = orr_prompt_armed(b, &na);   /* §5f.8: its own line, not the fallback */
        CHECK(na > 0 && pa != pr0);
        CHECK(l == 0 ? (na == 14 && !memcmp(pa, "Secoue le jeu.", 14)) : (na == 15 && !memcmp(pa, "Shake the deck.", 15)));
        orr_question_lead(b, &n);
        CHECK(n > 0);
        static const char *const hw[2][ORR_HINTS] = { { "appuie", "secoue", "suite", "retour", "fin" },
                                                       { "press", "shake", "next", "back", "end" } };
        for (int h = 0; h < ORR_HINTS; h++) {   /* §5f.9 */
            const char *hs = orr_hint(b, (orr_hint_t)h, &n);
            CHECK(n == strlen(hw[l][h]) && !memcmp(hs, hw[l][h], n));
        }
        int hist[OT_MAX_PAGES + 1] = { 0 }, trunc = 0;
        double layout_us = 0, page_us = 0, face_us = 0, q_us = 0, page_max = 0;
        int pages_drawn = 0;
        for (int i = 0; i < 22; i++) {
            size_t rl, pl, kl, nl, ql;
            const char *rdg = orr_card_field(b, i, ORR_F_READING, &rl);
            const char *pr = orr_card_field(b, i, ORR_F_PRINTED, &pl);
            const char *kw = orr_card_field(b, i, ORR_F_KW, &kl);
            const char *num = orr_card_field(b, i, ORR_F_NUM, &nl);
            const char *qq = orr_card_field(b, i, ORR_F_QUESTION, &ql);
            CHECK(rl > 0);
            CHECK(i == 13 ? pl == 0 : pl > 0);
            ot_info_t in;
            clock_t c0 = clock();
            CHECK_EQ(ot_reading_info(&f, rdg, rl, &in), 0);
            layout_us += (double)(clock() - c0) * 1e6 / CLOCKS_PER_SEC;
            CHECK(in.pages >= 1 && in.pages <= OT_MAX_PAGES);
            hist[in.pages]++;
            trunc += in.truncated;
            for (unsigned p = 0; p < in.pages; p++) {
                c0 = clock();
                CHECK(ot_draw_reading(&f, rdg, rl, p, s_fb, NULL) >= 0);
                const double us = (double)(clock() - c0) * 1e6 / CLOCKS_PER_SEC;
                page_us += us;
                if (us > page_max) page_max = us;
                pages_drawn++;
            }
            c0 = clock();
            CHECK(ot_draw_face(&f, num, nl, pr, pl, kw, kl, s_fb) >= 0);
            face_us += (double)(clock() - c0) * 1e6 / CLOCKS_PER_SEC;
            const char *lead = orr_question_lead(b, &n);
            c0 = clock();
            CHECK(ot_draw_question(&f, lead, n, qq, ql, s_fb) >= 0);
            q_us += (double)(clock() - c0) * 1e6 / CLOCKS_PER_SEC;
        }
        CHECK_EQ(trunc, 0);
        printf("     %s: readings of 1/2/3/4/5/6 pages: %d/%d/%d/%d/%d/%d at %u px lines; host: page count %.0f us/card, reading page "
               "%.0f us avg / %.0f max, face %.0f us, question %.0f us\n", names[l], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6], OT_COL_W,
               layout_us / 22, page_us / pages_drawn, page_max, face_us / 22, q_us / 22);
        free(ar);
        free(text);
    }
}

/* §5f.3 the paragraph as pages: full width, as many lines as fit, dots, at most 8 pages, the block steady. */
static void test_paragraph_pages(void)
{
    ot_fonts_t f = fonts(false);
    char t[2000] = "";
    while (strlen(t) < 880) strcat(t, "le vent passe sur la ville ");
    const size_t n = strlen(t) - 1;
    ot_info_t in;
    CHECK_EQ(ot_paragraph_info(&f, t, n, &in), 0);
    CHECK_EQ(in.per_page, (OT_TEXT_Y1 - OT_TEXT_Y0) / BODY.ch);   /* §5f.9: 200 / 30 = 6 */
    CHECK(in.pages >= 2 && in.pages <= OT_PARA_MAX_PAGES && !in.truncated);
    CHECK_EQ(in.pages, (in.lines + in.per_page - 1) / in.per_page);
    fill_fb(0x1234);
    CHECK_EQ(ot_draw_paragraph(&f, t, n, 0, s_fb, NULL), 0);
    CHECK_EQ(s_fb[100 * OT_SCREEN_W + 2], 0);   /* the whole screen cleared */
    census_t c0 = census(0, OT_DOT_X - 2);
    CHECK(c0.x0 >= OT_PARA_X0 && c0.x1 < OT_PARA_X1 && c0.white > 0 && c0.accent == 0);
    CHECK(c0.y0 >= OT_TEXT_Y0 && c0.y1 < OT_TEXT_Y1);   /* §5f.9: between the hint bands */
    CHECK(c0.x1 - c0.x0 > OT_COL_W);   /* wider than the column */
    unsigned cur;
    CHECK_EQ(dots(&cur), in.pages);
    CHECK_EQ(cur, 0);
    CHECK_EQ(ot_draw_paragraph(&f, t, n, in.pages - 1, s_fb, NULL), 0);
    census_t cl = census(0, OT_DOT_X - 2);
    CHECK_EQ(c0.y0, cl.y0);
    CHECK_EQ(dots(&cur), in.pages);
    CHECK_EQ(cur, in.pages - 1u);
    /* a short paragraph: one page, no dots */
    CHECK_EQ(ot_draw_paragraph(&f, "un souffle.", 11, 0, s_fb, &in), 0);
    CHECK(in.pages == 1);
    CHECK_EQ(dots(&cur), 0);
    /* beyond 8 pages (a very large body font: 2 rows a page above the hint band): cut */
    ot_fonts_t fb = f;
    fb.body = &s_big.font;
    CHECK_EQ(ot_paragraph_info(&fb, t, n, &in), 0);
    CHECK(in.pages == OT_PARA_MAX_PAGES && in.truncated && in.per_page == 2);
    (void)in;
}

/* §5f.11 the corner arrow: one ▶ of the accent colour in the BOOT corner, exact pixels, pointing at the button, inside
 * the corner reserve; nothing else touched. */
static void test_arrow(void)
{
    for (int fl = 0; fl < 2; fl++) {
        fill_fb(0x1234);
        ot_draw_arrow(s_fb, fl);
        int ax, ay, rx, ry;
        ot_arrow_xy(fl, &ax, &ay);
        ot_reserve_xy(fl, &rx, &ry);
        CHECK(fl ? (ax == 8 && ay + OT_ARROW_H - 1 == 235) : (ax + OT_ARROW_W == OT_SCREEN_W - 8 && ay == 4));
        CHECK(fl ? (rx == 0 && ry == 224) : (rx == 512 && ry == 0));
        const uint16_t c = th_be(TEXTLAY_CURSOR_COLOR);
        int n = 0, outside = 0, other = 0, col_first = 0, col_last = 0;
        for (int y = 0; y < OT_SCREEN_H; y++)
            for (int x = 0; x < OT_SCREEN_W; x++) {
                const uint16_t v = s_fb[y * OT_SCREEN_W + x];
                if (v == 0x1234) continue;
                if (v != c) other++;
                n++;
                if (x < ax || x >= ax + OT_ARROW_W || y < ay || y >= ay + OT_ARROW_H) outside++;
                if (x < rx || x >= rx + OT_RESERVE_W || y < ry || y >= ry + OT_RESERVE_H) outside++;
                if (x == ax) col_first++;
                if (x == ax + OT_ARROW_W - 1) col_last++;
            }
        CHECK_EQ(n, 1 + 3 + 5 + 7 + 8 + 7 + 5 + 3 + 1);
        CHECK_EQ(outside, 0);
        CHECK_EQ(other, 0);
        /* normally the flat side is on the left and the tip on the right (pointing right, at the button); flipped the
         * other way round */
        CHECK(fl ? (col_first == 1 && col_last == 9) : (col_first == 9 && col_last == 1));
    }
    ot_draw_arrow(NULL, false);
}

/* §5f.10 / §5f.11 text boxes: ink only inside the box, lines centred in it, one page; the face choice. */
static const face_spec_t COMPACT = { 9, 16, 12, 7 };

static void test_boxes(void)
{
    tfont_t t;
    static const face_spec_t LARGE = { 21, 39, 30, 16 };
    CHECK(tfont_make3(&t, &BODY, &COMPACT, &LARGE, true));
    CHECK(t.font.large_bound && t.font.compact_bound);
    static rsvp_font_t lv, cv, none;
    CHECK(ot_font_large_view(&t.font, &lv) && lv.normal.cell_h == LARGE.ch && !lv.large_bound);
    CHECK(ot_font_compact_view(&t.font, &cv) && cv.normal.cell_h == COMPACT.ch);
    CHECK(!ot_font_large_view(&s_body.font, &none));   /* no large face */
    uint16_t *scr = malloc(t.scratch_px * 2);
    ot_fonts_t f = { .body = &t.font, .scratch = scr, .scratch_px = t.scratch_px, .work = &s_work };
    const rsvp_font_t *faces[3] = { &lv, &t.font, &cv };
    struct { int x0, x1; bool fl; } boxes[4] = { { OT_FULL_X0, OT_FULL_X1, false }, { OT_FULL_X0, OT_FULL_X1, true },
                                               { OT_BESIDE_X0_UP, OT_BESIDE_X1_UP, false },
                                               { OT_BESIDE_X0_FLIP, OT_BESIDE_X1_FLIP, true } };
    static char lg[3000] = "";
    while (strlen(lg) < 2400) strcat(lg, "le vent passe sur la ville ");
    for (int b = 0; b < 4; b++) {
        const int x0 = boxes[b].x0, x1 = boxes[b].x1, y0 = ot_text_y0(boxes[b].fl), y1 = y0 + OT_BOX_H;
        CHECK(boxes[b].fl ? (y0 == 0 && y1 == 224) : (y0 == 16 && y1 == 240));
        for (int fi = 0; fi < 3; fi++) {
            fill_fb(0x1234);
            ot_info_t in;
            CHECK_EQ(ot_draw_box(&f, faces[fi], lg, 300, x0, x1, y0, y1, s_fb, &in), 0);
            census_t c = census(0, OT_SCREEN_W);
            CHECK(c.white > 0 && c.accent == 0 && c.other == 0);
            CHECK(c.x0 >= x0 && c.x1 < x1 && c.y0 >= y0 && c.y1 < y1);
            CHECK(abs((c.x0 + c.x1) / 2 - (x0 + x1) / 2) <= 8);   /* centred */
            CHECK_EQ(s_fb[0], 0);                                  /* the whole screen cleared */
            CHECK(in.per_page == OT_BOX_H / faces[fi]->normal.cell_h);
        }
        /* the face choice: a short text takes the large face, a longer one the normal, longer the compact, too long none */
        const int wpx = x1 - x0;
        CHECK_EQ(ot_box_pick(&f, faces, 3, "un souffle.", 11, x0, x1, y0, y1), 0);
        int got[4] = { 0, 0, 0, 0 };
        for (int n = 10; n <= 2400; n += 10) {
            const int k = ot_box_pick(&f, faces, 3, lg, (size_t)n, x0, x1, y0, y1);
            got[k + 1]++;
        }
        if (!(got[1] > 0 && got[2] > 0 && got[3] > 0 && got[0] > 0)) printf("     box %d: %d %d %d %d\n", b, got[1], got[2], got[3], got[0]);
        CHECK(got[1] > 0 && got[2] > 0 && got[3] > 0 && got[0] > 0);   /* every face, then none */
        (void)wpx;
        /* a missing face is skipped */
        const rsvp_font_t *two[3] = { NULL, &t.font, &cv };
        CHECK_EQ(ot_box_pick(&f, two, 3, "un souffle.", 11, x0, x1, y0, y1), 1);
    }
    /* bad boxes */
    CHECK_EQ(ot_draw_box(&f, &t.font, "x", 1, 0, 8, 0, 100, s_fb, NULL), -1);
    CHECK_EQ(ot_draw_box(&f, &t.font, "x", 1, 0, 537, 0, 100, s_fb, NULL), -1);
    CHECK_EQ(ot_draw_box(&f, &t.font, "x", 1, 0, 100, 10, 241, s_fb, NULL), -1);
    CHECK_EQ(ot_draw_box(&f, NULL, "x", 1, 0, 100, 0, 100, s_fb, NULL), -1);
    CHECK_EQ(ot_box_pick(&f, NULL, 3, "x", 1, 0, 100, 0, 100), -1);
    free(scr);
    tfont_free(&t);
}

/* §5f.11 the composer's one-page check: the normal face (never the large one) in the 520 x 224 full-width box; with the
 * real bundles at 22 pt it composes the "and" screen as the 150-character reference rule does on (almost) every row. */
static void test_lean_fits(void)
{
    tfont_t t;
    static const face_spec_t LARGE = { 21, 39, 30, 16 };
    CHECK(tfont_make3(&t, &BODY, &COMPACT, &LARGE, true));
    uint16_t *scr = malloc(t.scratch_px * 2);
    ot_fonts_t f = { .body = &t.font, .scratch = scr, .scratch_px = t.scratch_px, .work = &s_work };
    static char txt[1000] = "";
    while (strlen(txt) < 900) strcat(txt, "le vent passe sur la ville ");
    int edge = -1;
    for (int n = 10; n < 900; n += 2) {
        ot_info_t in;
        CHECK_EQ(ot_box_info(&f, &t.font, txt, (size_t)n, OT_FULL_X0, OT_FULL_X1, 0, OT_BOX_H, &in), 0);
        CHECK_EQ(ot_lean_fits(&f, txt, (size_t)n), in.pages <= 1);
        if (in.pages > 1 && edge < 0) edge = n;
    }
    CHECK(edge > 0);   /* the normal face's page (7 rows of 30 px), not the large face's (5 rows) */
    static rsvp_font_t lv;
    ot_font_large_view(&t.font, &lv);
    ot_info_t li;
    ot_box_info(&f, &lv, txt, (size_t)edge - 2, OT_FULL_X0, OT_FULL_X1, 0, OT_BOX_H, &li);
    CHECK(li.pages > 1 && ot_lean_fits(&f, txt, (size_t)edge - 2));
    CHECK(!ot_lean_fits(NULL, txt, 10));
    /* the real bundles: the "and" screens composed with this check vs the reference rule (fits = NULL) */
    size_t len = 0;
    char *text = slurp("reader-fr.txt", &len);
    if (text) {
        const size_t need = orr_arena_bytes(text, len);
        void *ar = malloc(need);
        orr_bundle_t *b = orr_parse(text, len, ar, need);
        static char l1[ORR_LEAN_SCREENS][ORR_OUT_MIN], l2[ORR_LEAN_SCREENS][ORR_OUT_MIN];
        char *const o1[ORR_LEAN_SCREENS] = { l1[0], l1[1], l1[2], l1[3], l1[4] };
        char *const o2[ORR_LEAN_SCREENS] = { l2[0], l2[1], l2[2], l2[3], l2[4] };
        const size_t lc[ORR_LEAN_SCREENS] = { ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN };
        int rows = 0, same = 0;
        for (int A = 0; A < 22; A++)
            for (int B = 0; B < 22; B += 2)
                for (int C = 0; C < 22; C += 3) {
                    if (A == B || B == C || A == C) continue;
                    if (orr_compose_lean(b, A, B, C, o1, lc, ot_lean_fits, &f) != ORR_LEAN_SCREENS) continue;
                    orr_compose_lean(b, A, B, C, o2, lc, NULL, NULL);
                    rows++;
                    same += !strcmp(l1[4], l2[4]);
                }
        printf("     22 pt normal face, 520 x 224: the \"and\" screen as the 150-char rule on %d of %d rows\n", same, rows);
        CHECK(rows > 0);   /* (informative: the reference rule is a character count, this a font measure) */
        free(ar);
        free(text);
    }
    free(scr);
    tfont_free(&t);
}

/* §5f.10 / §5f.11 layout: the corner reserve holds nothing but the arrow (cards, backs and boxes stay out of it); cards
 * whole; the text beside a card does not overlap it. */
static void test_layout(void)
{
    for (int fl = 0; fl < 2; fl++) {
        int rx, ry;
        ot_reserve_xy(fl, &rx, &ry);
        const int y0 = ot_text_y0(fl), y1 = y0 + OT_BOX_H;
        /* boxes vs the reserve: full width and beside a card */
        const int bx0[2] = { OT_FULL_X0, fl ? OT_BESIDE_X0_FLIP : OT_BESIDE_X0_UP };
        const int bx1[2] = { OT_FULL_X1, fl ? OT_BESIDE_X1_FLIP : OT_BESIDE_X1_UP };
        for (int b = 0; b < 2; b++) {
            const bool hit = bx0[b] < rx + OT_RESERVE_W && rx < bx1[b] && y0 < ry + OT_RESERVE_H && ry < y1;
            CHECK(!hit);
        }
        /* the three (centred, whole) and the back / detail card vs the reserve */
        for (int s = 0; s < 3; s++) {
            CHECK(or_three_x[s] >= 0 && or_three_x[s] + OR_CARD_W <= OT_SCREEN_W);
            CHECK(or_three_x[s] + OR_CARD_W <= rx || or_three_x[s] >= rx + OT_RESERVE_W);
        }
        /* §5f.12 the keyword row (y 206..239) under the three: clear of the reserve in both orientations */
        for (int k = 0; k < 3; k++) {
            const bool hit = or_keys_x[k] < rx + OT_RESERVE_W && rx < or_keys_x[k] + OR_KEY_W && OR_KEYS_Y < ry + OT_RESERVE_H &&
                             ry < OR_KEYS_Y + OR_KEY_H;
            CHECK(!hit);
            CHECK(or_keys_x[k] >= 0 && or_keys_x[k] + OR_KEY_W <= OT_SCREEN_W && OR_KEYS_Y + OR_KEY_H <= OT_SCREEN_H);
        }
        const int bx = fl ? OR_BACK_X_FLIP : OR_BACK_X_UP;
        CHECK(bx >= 0 && bx + OR_CARD_W <= OT_SCREEN_W && OR_BACK_Y + OR_CARD_H <= OT_SCREEN_H);
        CHECK(bx + OR_CARD_W <= rx || bx >= rx + OT_RESERVE_W || OR_BACK_Y + OR_CARD_H <= ry || OR_BACK_Y >= ry + OT_RESERVE_H);
        /* the text beside the card does not overlap it, 8 px apart */
        CHECK(bx + OR_CARD_W + 8 == bx0[1] || bx == bx1[1] + 8);
    }
}

/* §5f.11 per size (18 / 22 / 26 pt, a large face at 1.3x, compact at 12 pt): the face every real screen lands on — the
 * prompts beside the back, every lean screen at full width, every brief beside its card — and the briefs that do not
 * fit beside the card even in compact (the card is then left out). */
static void test_real_faces(void)
{
    static const face_spec_t sizes[3][2] = { { { 13, 24, 18, 10 }, { 17, 31, 23, 13 } },
                                             { { 16, 30, 23, 12 }, { 21, 39, 30, 16 } },
                                             { { 19, 36, 28, 15 }, { 25, 47, 36, 20 } } };
    static const char *const names[3] = { "18 pt", "22 pt", "26 pt" };
    for (int lang = 0; lang < 2; lang++) {
        size_t len = 0;
        char *text = slurp(lang ? "reader-en.txt" : "reader-fr.txt", &len);
        CHECK(text != NULL);
        if (!text) return;
        const size_t need = orr_arena_bytes(text, len);
        void *ar = malloc(need);
        orr_bundle_t *b = orr_parse(text, len, ar, need);
        for (int z = 0; z < 3; z++) {
            tfont_t t;
            CHECK(tfont_make3(&t, &sizes[z][0], &COMPACT, &sizes[z][1], true));
            uint16_t *scr = malloc(t.scratch_px * 2);
            ot_fonts_t f = { .body = &t.font, .scratch = scr, .scratch_px = t.scratch_px, .work = &s_work };
            static rsvp_font_t lv, cv;
            ot_font_large_view(&t.font, &lv);
            ot_font_compact_view(&t.font, &cv);
            const rsvp_font_t *faces[3] = { &lv, &t.font, &cv };
            int lean[4] = { 0 }, brief[4] = { 0 }, prompt[4] = { 0 };   /* none, large, normal, compact */
            static char ls[ORR_LEAN_SCREENS][ORR_OUT_MIN];
            char *const lo[ORR_LEAN_SCREENS] = { ls[0], ls[1], ls[2], ls[3], ls[4] };
            const size_t lc[ORR_LEAN_SCREENS] = { ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN };
            for (int A = 0; A < 22; A++)
                for (int B = 0; B < 22; B += 3)
                    for (int C = 1; C < 22; C += 4) {
                        if (A == B || B == C || A == C) continue;
                        if (orr_compose_lean(b, A, B, C, lo, lc, NULL, NULL) != ORR_LEAN_SCREENS) continue;
                        for (int k = 0; k < ORR_LEAN_SCREENS; k++) {
                            if (!ls[k][0]) continue;
                            lean[1 + ot_box_pick(&f, faces, 3, ls[k], strlen(ls[k]), OT_FULL_X0, OT_FULL_X1, ot_text_y0(false), ot_text_y0(false) + OT_BOX_H)]++;
                        }
                    }
            for (int i = 0; i < 22; i++) {
                size_t bl;
                const char *br = orr_card_field(b, i, ORR_F_BRIEF, &bl);
                if (!bl) continue;
                brief[1 + ot_box_pick(&f, faces, 3, br, bl, OT_BESIDE_X0_UP, OT_BESIDE_X1_UP, ot_text_y0(false), ot_text_y0(false) + OT_BOX_H)]++;
            }
            size_t pl;
            const char *pr = orr_prompt(b, &pl);
            prompt[1 + ot_box_pick(&f, faces, 3, pr, pl, OT_BESIDE_X0_UP, OT_BESIDE_X1_UP, ot_text_y0(false), ot_text_y0(false) + OT_BOX_H)]++;
            pr = orr_prompt_armed(b, &pl);
            prompt[1 + ot_box_pick(&f, faces, 3, pr, pl, OT_BESIDE_X0_UP, OT_BESIDE_X1_UP, ot_text_y0(false), ot_text_y0(false) + OT_BOX_H)]++;
            printf("     %s %s: lean %d large / %d normal / %d compact / %d none; briefs beside the card %d / %d / %d, "
                   "no card %d; prompts %d / %d / %d / %d\n", lang ? "en" : "fr", names[z], lean[1], lean[2], lean[3],
                   lean[0], brief[1], brief[2], brief[3], brief[0], prompt[1], prompt[2], prompt[3], prompt[0]);
            CHECK_EQ(lean[0], 0);     /* every lean screen fits full width in some face */
            CHECK_EQ(prompt[0], 0);
            CHECK(brief[1] + brief[2] + brief[3] + brief[0] == 22);
            free(scr);
            tfont_free(&t);
        }
        free(ar);
        free(text);
    }
}

/* The three body sizes of §5f.3 (18 / 22 / 26 pt: cells ~24 / 30 / 36 px) with the real readings and paragraphs: the
 * reading and paragraph page counts at each size (nothing assumes a line count). */
static void test_sizes(void)
{
    static const face_spec_t sizes[3] = { { 13, 24, 18, 10 }, { 16, 30, 23, 12 }, { 19, 36, 28, 15 } };
    static const char *const names[3] = { "18 pt", "22 pt", "26 pt" };
    size_t len = 0;
    char *text = slurp("reader-fr.txt", &len);
    CHECK(text != NULL);
    if (!text) return;
    const size_t need = orr_arena_bytes(text, len);
    void *ar = malloc(need);
    orr_bundle_t *b = orr_parse(text, len, ar, need);
    for (int z = 0; z < 3; z++) {
        tfont_t body;
        CHECK(tfont_make(&body, &sizes[z], NULL, true));
        uint16_t *scr = malloc(body.scratch_px * 2);
        ot_fonts_t f = { .body = &body.font, .scratch = scr, .scratch_px = body.scratch_px, .work = &s_work };
        int rmax = 0, rtrunc = 0, pmax = 0, ptrunc = 0, psum = 0, rows = 0;
        for (int i = 0; i < 22; i++) {
            size_t rl;
            const char *rd = orr_card_field(b, i, ORR_F_READING, &rl);
            ot_info_t in;
            CHECK_EQ(ot_reading_info(&f, rd, rl, &in), 0);
            if (in.pages > rmax) rmax = in.pages;
            rtrunc += in.truncated;
        }
        char out[ORR_OUT_MIN];
        for (int k = 0; k < 7; k++)
            for (int A = 1; A < 22; A += 5) {
                const int B = (A + 7 + k) % 22, C = (A + 13 + 2 * k) % 22;
                if (A == B || B == C || A == C) continue;
                const int n = orr_compose(b, -1, A, B, C, out, sizeof out);
                ot_info_t in;
                CHECK(n > 0 && ot_paragraph_info(&f, out, (size_t)n, &in) == 0);
                if (in.pages > pmax) pmax = in.pages;
                ptrunc += in.truncated;
                psum += in.pages;
                rows++;
                CHECK(ot_draw_paragraph(&f, out, (size_t)n, in.pages - 1, s_fb, NULL) == 0);
            }
        CHECK_EQ(rtrunc, 0);
        CHECK_EQ(ptrunc, 0);
        /* §5f.7 / §5f.9: every lean screen of every row (reference rule) and every brief is one page above the hint
         * band at this size */
        int lean_over = 0, lean_n = 0, brief_over = 0;
        static char ls[ORR_LEAN_SCREENS][ORR_OUT_MIN];
        char *const lo[ORR_LEAN_SCREENS] = { ls[0], ls[1], ls[2], ls[3], ls[4] };
        const size_t lc[ORR_LEAN_SCREENS] = { ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN };
        for (int A = 0; A < 22; A++)
            for (int B = 0; B < 22; B += 3)
                for (int C = 1; C < 22; C += 4) {
                    if (A == B || B == C || A == C) continue;
                    if (orr_compose_lean(b, A, B, C, lo, lc, NULL, NULL) != ORR_LEAN_SCREENS) continue;
                    for (int k = 0; k < ORR_LEAN_SCREENS; k++) {
                        ot_info_t in;
                        if (!ls[k][0] || ot_paragraph_info(&f, ls[k], strlen(ls[k]), &in) != 0) continue;
                        lean_n++;
                        lean_over += in.pages > 1;
                    }
                }
        for (int i = 0; i < 22; i++) {
            size_t bl;
            const char *br = orr_card_field(b, i, ORR_F_BRIEF, &bl);
            ot_info_t in;
            if (bl && ot_paragraph_info(&f, br, bl, &in) == 0) brief_over += in.pages > 1;
        }
        printf("     %s: %d lean screens, %d longer than a page; briefs longer than a page: %d\n", names[z], lean_n,
               lean_over, brief_over);
        if (z < 2) CHECK(lean_over == 0 && brief_over == 0);
        printf("     %s (cell %u px): readings up to %d pages; paragraphs %.1f pages avg, up to %d (%d rows)\n", names[z],
               sizes[z].ch, rmax, (double)psum / rows, pmax, rows);
        free(scr);
        tfont_free(&body);
    }
    free(ar);
    free(text);
}

int main(void)
{
    if (!tfont_make(&s_body, &BODY, NULL, true) || !tfont_make(&s_big, &BIG, NULL, true)) {
        fprintf(stderr, "test fonts\n");
        return 1;
    }
    s_scratch = malloc((s_big.scratch_px > s_body.scratch_px ? s_big.scratch_px : s_body.scratch_px) * 2);
    RUN(test_prompt);
    RUN(test_face);
    RUN(test_question);
    RUN(test_reading_pages);
    RUN(test_real_bundles);
    RUN(test_paragraph_pages);
    RUN(test_sizes);
    RUN(test_arrow);
    RUN(test_boxes);
    RUN(test_layout);
    RUN(test_lean_fits);
    RUN(test_real_faces);
    tfont_free(&s_body);
    tfont_free(&s_big);
    free(s_scratch);
    return TH_DONE("test_oracle_text");
}
