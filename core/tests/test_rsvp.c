/* test_rsvp.c — Reader mode (rsvp.h): tokeniser, timing, ORP, font document, layout, painter. */
#include "tharness.h"
#include "rsvp.h"
#include <time.h>

/* ------------------------------------------------------------------------------------------ */
/* Helpers                                                                                    */

static size_t tok(const char *s, rsvp_word_t *w, size_t cap, rsvp_stats_t *st) {
    return rsvp_tokenize(s, strlen(s), w, cap, st);
}

static int word_is(const char *text, const rsvp_word_t *w, const char *expect) {
    return w->len == strlen(expect) && memcmp(text + w->off, expect, w->len) == 0;
}

#define CHECK_WORD(text, w, s) do { th_checks++; if (!word_is(text, w, s)) { th_failures++; \
    fprintf(stderr, "%s:%d: word \"%.*s\" != \"%s\"\n", __FILE__, __LINE__, (int)(w)->len, (text) + (w)->off, s); } } while (0)

/* ---- test font: geometric glyphs; every glyph's pixels carry a colour that identifies it ---- */

/* glyph set: UTF-8, one entry per glyph */
static const char *k_glyphs[] = {
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
    "u", "v", "w", "x", "y", "z", "A", "B", "C", "L", "P", "T", "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", "?", ".", ",", ";", "!", "-", "\xE2\x80\x99" /* ’ */, "\xC3\xA9" /* é */, "\xC3\xA0" /* à */,
    "\xE2\x80\x94" /* — */, "\xC2\xB7" /* · */, " ", "\xE2\x8F\xB8" /* ⏸ */,
};
#define NG ((int)(sizeof k_glyphs / sizeof k_glyphs[0]))

typedef struct { uint16_t cw, ch, base; uint16_t white_tag, accent_tag; int adv_scale; } face_spec_t;
static const face_spec_t NORMAL = { 12, 20, 16, 0x8000, 0x4000, 10 };
static const face_spec_t COMPACT = { 8, 14, 11, 0x2000, 0x1000, 6 };

static int adv_of(int g, const face_spec_t *fs) {
    const char *s = k_glyphs[g];
    if (!strcmp(s, "i") || !strcmp(s, "l") || !strcmp(s, ".") || !strcmp(s, ",")) return fs->adv_scale / 2;
    if (!strcmp(s, "m") || !strcmp(s, "w") || !strcmp(s, "\xE2\x80\x94")) return fs->adv_scale + fs->adv_scale / 2;
    return fs->adv_scale;
}

/* colour (native) of glyph g in an atlas tagged `tag` */
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
        uint16_t c = th_be(tag_px(accent ? fs->accent_tag : fs->white_tag, g));
        for (int y = fs->base - fs->ch / 2; y < fs->base; y++)
            for (int x = 0; x < w; x++) f[(size_t)y * fs->cw + (size_t)x] = c;
    }
    size_t cap = npx * 2 * NG + 4096 + (size_t)NG * 16;
    uint8_t *out = malloc(cap);
    *size = th_build_hca(px, fs->cw, fs->ch, NG, HCA_COMP_RLE16, HCA_FLAG_GLYPH_ATLAS, NULL, out, cap);
    free(px);
    return out;
}

static size_t face_json(char *buf, size_t cap, const face_spec_t *fs, const char *white, const char *accent, int ng) {
    size_t o = 0;
    o += (size_t)snprintf(buf + o, cap - o, "{\"glyphs\":\"");
    for (int g = 0; g < ng; g++) o += (size_t)snprintf(buf + o, cap - o, "%s", k_glyphs[g]);
    o += (size_t)snprintf(buf + o, cap - o, "\",\"advance\":[");
    for (int g = 0; g < ng; g++) o += (size_t)snprintf(buf + o, cap - o, "%s%d", g ? "," : "", adv_of(g, fs));
    o += (size_t)snprintf(buf + o, cap - o, "],\"cell_w\":%u,\"cell_h\":%u,\"baseline\":%u,\"atlas_white\":\"%s\",\"atlas_accent\":\"%s\"",
                          fs->cw, fs->ch, fs->base, white, accent);
    return o;
}

static char *font_json(int ng, bool compact) {
    char *buf = malloc(8192);
    size_t o = face_json(buf, 8192, &NORMAL, "tw", "ta", ng);
    if (compact) {
        o += (size_t)snprintf(buf + o, 8192 - o, ",\"compact\":");
        o += face_json(buf + o, 8192 - o, &COMPACT, "cw", "ca", ng);
        o += (size_t)snprintf(buf + o, 8192 - o, "}");
    }
    snprintf(buf + o, 8192 - o, ",\"extra\":{\"nested\":[1,2,{\"x\":null}]}}");
    return buf;
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

static bool tfont_make(tfont_t *t, int ng, bool compact) {
    memset(t, 0, sizeof *t);
    char *j = font_json(ng, compact);
    char err[80];
    rsvp_status_t st = rsvp_font_parse(j, strlen(j), &t->font, err, sizeof err);
    free(j);
    if (st != RSVP_OK) { fprintf(stderr, "font parse: %s\n", err); return false; }
    const face_spec_t *fs[4] = { &NORMAL, &NORMAL, &COMPACT, &COMPACT };
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

#define FW 536
#define FH 240

/* ------------------------------------------------------------------------------------------ */
/* UTF-8 + tokeniser                                                                          */

static void test_utf8(void) {
    uint32_t cp;
    CHECK_EQ(rsvp_utf8_next("A", 1, &cp), 1); CHECK_EQ(cp, 'A');
    CHECK_EQ(rsvp_utf8_next("\xC3\xA9x", 3, &cp), 2); CHECK_EQ(cp, 0xE9);
    CHECK_EQ(rsvp_utf8_next("\xE2\x80\x99", 3, &cp), 3); CHECK_EQ(cp, 0x2019);
    CHECK_EQ(rsvp_utf8_next("\xF0\x9F\x98\x80", 4, &cp), 4); CHECK_EQ(cp, 0x1F600);
    CHECK_EQ(rsvp_utf8_next("\x80", 1, &cp), 1); CHECK_EQ(cp, RSVP_CP_INVALID);           /* lone continuation */
    CHECK_EQ(rsvp_utf8_next("\xC3" "A", 2, &cp), 1); CHECK_EQ(cp, RSVP_CP_INVALID);        /* broken sequence */
    CHECK_EQ(rsvp_utf8_next("\xE2\x80", 2, &cp), 2); CHECK_EQ(cp, RSVP_CP_INVALID);        /* truncated */
    CHECK_EQ(rsvp_utf8_next("\xED\xA0\x80", 3, &cp), 3); CHECK_EQ(cp, RSVP_CP_INVALID);    /* surrogate */
    CHECK_EQ(rsvp_utf8_next("\xE0\x80\xAF", 3, &cp), 3); CHECK_EQ(cp, RSVP_CP_INVALID);    /* overlong */
    CHECK_EQ(rsvp_utf8_next("\xC0\xAF", 2, &cp), 1); CHECK_EQ(cp, RSVP_CP_INVALID);        /* C0 never valid */
    CHECK_EQ(rsvp_utf8_next("\xF4\x90\x80\x80", 4, &cp), 4); CHECK_EQ(cp, RSVP_CP_INVALID);/* > U+10FFFF */
    CHECK_EQ(rsvp_utf8_next("", 0, &cp), 0);
}

static void test_tok_ascii(void) {
    const char *t = "Hello, world. This is  a test!\n\nNew para; here";
    rsvp_word_t w[16];
    rsvp_stats_t st;
    size_t n = tok(t, w, 16, &st);
    CHECK_EQ(n, 9);
    CHECK_EQ(st.words, 9);
    CHECK_WORD(t, &w[0], "Hello,");   CHECK_EQ(w[0].flags, RSVP_F_COMMA); CHECK_EQ(w[0].off, 0);
    CHECK_WORD(t, &w[1], "world.");   CHECK_EQ(w[1].flags, RSVP_F_SENTENCE);
    CHECK_WORD(t, &w[2], "This");     CHECK_EQ(w[2].flags, 0);
    CHECK_WORD(t, &w[4], "a");        CHECK_EQ(w[4].off, 23);
    CHECK_WORD(t, &w[5], "test!");    CHECK_EQ(w[5].flags, RSVP_F_SENTENCE | RSVP_F_PARA);
    CHECK_WORD(t, &w[7], "para;");    CHECK_EQ(w[7].flags, RSVP_F_COMMA);
    CHECK_WORD(t, &w[8], "here");     CHECK_EQ(w[8].flags, 0);
    CHECK_EQ(w[0].glyphs, 6); CHECK_EQ(w[0].lead, 0); CHECK_EQ(w[0].core, 5);
    CHECK_EQ(st.sentences, 2);
    CHECK_EQ(st.paragraphs, 1);
    CHECK_EQ(st.invalid, 0);
    CHECK_EQ(st.bytes, strlen(t));
    unsigned long long fsum = 0;
    for (size_t i = 0; i < n; i++) fsum += rsvp_word_factor_x10(&w[i]);
    CHECK_EQ(st.factor_x10, fsum);
    /* empty / whitespace only */
    CHECK_EQ(tok("", w, 16, &st), 0); CHECK_EQ(st.words, 0);
    CHECK_EQ(tok(" \n\t \r\n ", w, 16, &st), 0); CHECK_EQ(st.words, 0);
    /* count beyond capacity */
    CHECK_EQ(tok("a b c d e", w, 2, &st), 2); CHECK_EQ(st.words, 5);
    CHECK_EQ(rsvp_tokenize("a b c", 5, NULL, 0, &st), 0); CHECK_EQ(st.words, 3);
}

static void test_tok_french(void) {
    /* typographic apostrophes, accents, guillemets with ordinary spaces, an em dash on its own */
    const char *t = "L\xE2\x80\x99" "\xC3\xA9t\xC3\xA9, \xC3\xA0 Paris \xE2\x80\x94 c\xE2\x80\x99" "\xC3\xA9tait "
                    "\xC2\xAB magnifique \xC2\xBB ! Peut-\xC3\xAAtre\xE2\x80\xA6";
    rsvp_word_t w[16];
    rsvp_stats_t st;
    size_t n = tok(t, w, 16, &st);
    CHECK_EQ(n, 10);
    CHECK_WORD(t, &w[0], "L\xE2\x80\x99\xC3\xA9t\xC3\xA9,");
    CHECK_EQ(w[0].glyphs, 6); CHECK_EQ(w[0].len, 10); CHECK_EQ(w[0].core, 5); CHECK_EQ(w[0].flags, RSVP_F_COMMA);
    CHECK_WORD(t, &w[1], "\xC3\xA0"); CHECK_EQ(w[1].glyphs, 1);
    CHECK_WORD(t, &w[3], "\xE2\x80\x94"); CHECK_EQ(w[3].flags, RSVP_F_COMMA); CHECK_EQ(w[3].core, 0);
    CHECK_WORD(t, &w[4], "c\xE2\x80\x99\xC3\xA9tait"); CHECK_EQ(w[4].glyphs, 7); CHECK_EQ(w[4].core, 7);
    CHECK_WORD(t, &w[5], "\xC2\xAB");
    CHECK_WORD(t, &w[7], "\xC2\xBB");
    CHECK_WORD(t, &w[8], "!"); CHECK_EQ(w[8].flags, RSVP_F_SENTENCE);
    CHECK_WORD(t, &w[9], "Peut-\xC3\xAAtre\xE2\x80\xA6"); CHECK_EQ(w[9].flags, RSVP_F_SENTENCE);
    CHECK_EQ(w[9].glyphs, 10); CHECK_EQ(w[9].core, 9); CHECK_EQ(w[9].lead, 0);
    CHECK_EQ(st.invalid, 0);

    /* French typography: no-break spaces keep guillemets and ! with their word */
    const char *t2 = "\xC2\xAB\xC2\xA0" "Bonjour\xC2\xA0" "!\xC2\xA0" "\xC2\xBB dit-il.";
    n = tok(t2, w, 16, &st);
    CHECK_EQ(n, 2);
    CHECK_WORD(t2, &w[0], "\xC2\xAB\xC2\xA0" "Bonjour\xC2\xA0" "!\xC2\xA0" "\xC2\xBB");
    CHECK_EQ(w[0].flags, RSVP_F_SENTENCE);          /* the closing » is skipped, the ! counts */
    CHECK_EQ(w[0].lead, 2); CHECK_EQ(w[0].core, 7);
    CHECK_EQ(rsvp_word_orp(&w[0]), 2 + 2);          /* "Bonjour": 7 letters -> index 2, after « + nbsp */
    CHECK_WORD(t2, &w[1], "dit-il."); CHECK_EQ(w[1].flags, RSVP_F_SENTENCE);

    /* em dash attached on both sides splits after the dash; en dash in a range too */
    const char *t3 = "oui\xE2\x80\x94non 1914\xE2\x80\x93" "1918";
    n = tok(t3, w, 16, &st);
    CHECK_EQ(n, 4);
    CHECK_WORD(t3, &w[0], "oui\xE2\x80\x94"); CHECK_EQ(w[0].flags, RSVP_F_COMMA);
    CHECK_WORD(t3, &w[1], "non");
    CHECK_WORD(t3, &w[2], "1914\xE2\x80\x93");
    CHECK_WORD(t3, &w[3], "1918");
}

static void test_tok_numbers_space(void) {
    const char *t = "Il a 1 234,56 \xE2\x82\xAC et 3.14 ou 42%. (vraiment) \"Oui.\"";
    rsvp_word_t w[16];
    rsvp_stats_t st;
    size_t n = tok(t, w, 16, &st);
    CHECK_EQ(n, 11);
    CHECK_WORD(t, &w[3], "234,56"); CHECK_EQ(w[3].flags, 0);
    CHECK_WORD(t, &w[4], "\xE2\x82\xAC");
    CHECK_WORD(t, &w[6], "3.14");   CHECK_EQ(w[6].flags, 0);
    CHECK_WORD(t, &w[8], "42%.");   CHECK_EQ(w[8].flags, RSVP_F_SENTENCE); CHECK_EQ(w[8].core, 2);
    CHECK_WORD(t, &w[9], "(vraiment)"); CHECK_EQ(w[9].lead, 1); CHECK_EQ(w[9].core, 8); CHECK_EQ(w[9].flags, 0);
    CHECK_WORD(t, &w[10], "\"Oui.\""); CHECK_EQ(w[10].flags, RSVP_F_SENTENCE);

    /* whitespace runs: CRLF blank line, spaces on the blank line, single newlines, U+2029, tabs */
    const char *t2 = "a  \t b\r\n\r\nc\n \n d\ne\xE2\x80\xA9" "f\xE2\x80\x83g";
    n = tok(t2, w, 16, &st);
    CHECK_EQ(n, 7);
    CHECK_WORD(t2, &w[0], "a"); CHECK_EQ(w[0].flags, 0);
    CHECK_WORD(t2, &w[1], "b"); CHECK_EQ(w[1].flags, RSVP_F_PARA);
    CHECK_WORD(t2, &w[2], "c"); CHECK_EQ(w[2].flags, RSVP_F_PARA);
    CHECK_WORD(t2, &w[3], "d"); CHECK_EQ(w[3].flags, 0);
    CHECK_WORD(t2, &w[4], "e"); CHECK_EQ(w[4].flags, RSVP_F_PARA);   /* U+2029 paragraph separator */
    CHECK_WORD(t2, &w[5], "f"); CHECK_EQ(w[5].flags, 0);             /* U+2003 em space separates */
    CHECK_WORD(t2, &w[6], "g");
    CHECK_EQ(st.paragraphs, 3);
    /* "\r\r" is two line breaks (old Mac), "\r\n" one */
    n = tok("x\r\ry\r\nz", w, 16, &st);
    CHECK_EQ(n, 3); CHECK_EQ(w[0].flags, RSVP_F_PARA); CHECK_EQ(w[1].flags, 0);
    /* NUL and control characters separate and are counted */
    const char t3[] = { 'a', 0, 'b', 1, 'c' };
    n = rsvp_tokenize(t3, sizeof t3, w, 16, &st);
    CHECK_EQ(n, 3); CHECK_EQ(st.nul, 1);
    /* a BOM is a separator */
    n = tok("\xEF\xBB\xBFHi there", w, 16, &st);
    CHECK_EQ(n, 2); CHECK_EQ(w[0].off, 3);
}

static void test_tok_long_and_invalid(void) {
    char t[64];
    memset(t, 'x', 40);
    t[40] = '\0';
    rsvp_word_t w[8];
    rsvp_stats_t st;
    size_t n = tok(t, w, 8, &st);
    CHECK_EQ(n, 2); CHECK_EQ(w[0].glyphs, 32); CHECK_EQ(w[1].glyphs, 8); CHECK_EQ(w[1].off, 32);
    CHECK_EQ(st.max_glyphs, 32);
    /* 40 x "é": split at 32 glyphs = 64 bytes, never inside a sequence */
    char t2[128];
    for (int i = 0; i < 40; i++) { t2[2 * i] = (char)0xC3; t2[2 * i + 1] = (char)0xA9; }
    n = rsvp_tokenize(t2, 80, w, 8, &st);
    CHECK_EQ(n, 2); CHECK_EQ(w[0].len, 64); CHECK_EQ(w[1].off, 64); CHECK_EQ(w[1].len, 16);
    /* invalid bytes are glyphs of their own, counted */
    const char *t3 = "ab\xFF" "cd \xC3 e\x80";
    n = tok(t3, w, 8, &st);
    CHECK_EQ(n, 3); CHECK_EQ(w[0].glyphs, 5); CHECK_EQ(w[1].glyphs, 1); CHECK_EQ(w[2].glyphs, 2);
    CHECK_EQ(st.invalid, 3);
    /* a sequence cut by the end of the text */
    n = rsvp_tokenize("ab\xE2\x80", 4, w, 8, &st);
    CHECK_EQ(n, 1); CHECK_EQ(w[0].len, 4); CHECK_EQ(w[0].glyphs, 3); CHECK_EQ(st.invalid, 1);
}

static void test_tok_title_break(void) {
    const char *t = "Le titre\nPremier mot. Suite\n\nFin";
    rsvp_tok_t tk;
    rsvp_word_t w[16];
    rsvp_tok_init(&tk, 0, RSVP_TOK_TITLE_BREAK);
    size_t used, n = rsvp_tok_feed(&tk, t, strlen(t), &used, w, 16);
    n += rsvp_tok_finish(&tk, w + n, 16 - n);
    CHECK_EQ(used, strlen(t));
    CHECK_EQ(n, 6);
    CHECK_WORD(t, &w[1], "titre"); CHECK_EQ(w[1].flags, RSVP_F_PARA);   /* end of the title line */
    CHECK_EQ(w[3].flags, RSVP_F_SENTENCE);
    CHECK_WORD(t, &w[4], "Suite"); CHECK_EQ(w[4].flags, RSVP_F_PARA);
    CHECK_EQ(rsvp_tok_stats(&tk)->paragraphs, 2);
    /* without the option the first single newline is not a break */
    n = tok(t, w, 16, NULL);
    CHECK_EQ(w[1].flags, 0);
    /* base offset */
    rsvp_tok_init(&tk, 1000, 0);
    n = rsvp_tok_feed(&tk, "aa bb", 5, &used, w, 16);
    n += rsvp_tok_finish(&tk, w + n, 16 - n);
    CHECK_EQ(n, 2); CHECK_EQ(w[0].off, 1000); CHECK_EQ(w[1].off, 1003);
}

static void test_title(void) {
    char out[RSVP_TITLE_MAX];
    CHECK_EQ(rsvp_title("\xEF\xBB\xBF  Le Petit Livre  \nreste", 30, out, sizeof out), 14);
    CHECK(!strcmp(out, "Le Petit Livre"));
    CHECK_EQ(rsvp_title("Une ligne", 9, out, sizeof out), 9);
    CHECK_EQ(rsvp_title("\r\nx", 3, out, sizeof out), 0);
    CHECK(!strcmp(out, ""));
    /* truncation at a code point boundary: "ééé" into 6 bytes -> "éé" */
    char small[6];
    CHECK_EQ(rsvp_title("\xC3\xA9\xC3\xA9\xC3\xA9", 6, small, sizeof small), 4);
    CHECK(!strcmp(small, "\xC3\xA9\xC3\xA9"));
    /* invalid bytes become '?', tabs inside become spaces */
    CHECK_EQ(rsvp_title("a\xFF\tb", 4, out, sizeof out), 4);
    CHECK(!strcmp(out, "a? b"));
}

/* Chunked streaming must give exactly the one-shot result; rsvp_word_at re-reads each word. */
static void check_streaming(const char *t, size_t len) {
    static rsvp_word_t a[4096], b[4096];
    rsvp_stats_t sa;
    size_t na = rsvp_tokenize(t, len, a, 4096, &sa);
    rsvp_tok_t tk;
    rsvp_tok_init(&tk, 0, 0);
    size_t nb = 0, pos = 0;
    while (pos < len) {
        size_t chunk = 1 + th_rand() % 17;
        if (chunk > len - pos) chunk = len - pos;
        size_t cap = 2 + th_rand() % 4, used = 0;
        rsvp_word_t tmp[8];
        size_t k = rsvp_tok_feed(&tk, t + pos, chunk, &used, tmp, cap);
        for (size_t i = 0; i < k; i++) if (nb < 4096) b[nb++] = tmp[i];
        pos += used;
    }
    rsvp_word_t tmp[2];
    size_t k = rsvp_tok_finish(&tk, tmp, 2);
    for (size_t i = 0; i < k; i++) if (nb < 4096) b[nb++] = tmp[i];
    CHECK_EQ(na, nb);
    CHECK_EQ(sa.words, rsvp_tok_stats(&tk)->words);
    CHECK_EQ(sa.factor_x10, rsvp_tok_stats(&tk)->factor_x10);
    int bad = 0, bad_at = 0;
    for (size_t i = 0; i < na && i < nb; i++) {
        if (memcmp(&a[i], &b[i], sizeof a[i]) != 0) bad++;
        rsvp_word_t r;
        size_t avail = len - a[i].off;
        if (avail > RSVP_WORD_MAX_BYTES + 8) avail = RSVP_WORD_MAX_BYTES + 8;
        bool ok = rsvp_word_at(t + a[i].off, avail, a[i].off + avail == len, &r);
        if (!ok || r.off != 0 || r.len != a[i].len || r.glyphs != a[i].glyphs || r.core != a[i].core ||
            r.lead != a[i].lead || r.flags != (a[i].flags & (uint8_t)~RSVP_F_PARA)) bad_at++;
    }
    CHECK_EQ(bad, 0);
    CHECK_EQ(bad_at, 0);
}

static void test_tok_streaming(void) {
    const char *t = "Le titre\n\n\xC2\xAB\xC2\xA0Oui\xC2\xA0!\xC2\xA0\xC2\xBB r\xC3\xA9pondit-il \xE2\x80\x94 "
                    "c\xE2\x80\x99\xC3\xA9tait l\xE2\x80\x99\xC3\xA9t\xC3\xA9, 1 234 fois\xE2\x80\xA6\r\n\r\n"
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx fin.";
    for (int r = 0; r < 50; r++) check_streaming(t, strlen(t));
}

/* ------------------------------------------------------------------------------------------ */
/* Timing + ORP                                                                               */

static void test_orp_rule(void) {
    static const unsigned expect[] = { 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4 };
    for (unsigned n = 0; n <= 20; n++) CHECK_EQ(rsvp_orp_index(n), expect[n]);
    CHECK_EQ(rsvp_orp_index(1000), 4);
    rsvp_word_t w[4];
    const char *t = "\"quoi\" !? (l\xE2\x80\x99homme)";
    size_t n = tok(t, w, 4, NULL);
    CHECK_EQ(n, 3);
    CHECK_EQ(rsvp_word_orp(&w[0]), 1 + 1);   /* lead 1, core "quoi" 4 -> 1 */
    CHECK_EQ(rsvp_word_orp(&w[1]), 1);       /* no letters: 2 glyphs -> 1 */
    CHECK_EQ(rsvp_word_orp(&w[2]), 1 + 2);   /* lead 1, core 7 (l’homme) -> 2 */
    rsvp_word_t z = { 0 };
    CHECK_EQ(rsvp_word_orp(&z), 0);
}

static void test_timing(void) {
    /* table at 300 wpm (base 200 ms) */
    struct { uint8_t core; uint8_t flags; uint32_t ms; } tab[] = {
        { 3, 0, 200 }, { 7, 0, 200 }, { 8, 0, 260 }, { 11, 0, 260 }, { 12, 0, 320 }, { 20, 0, 320 },
        { 3, RSVP_F_COMMA, 300 }, { 3, RSVP_F_SENTENCE, 400 }, { 3, RSVP_F_COMMA | RSVP_F_SENTENCE, 400 },
        { 8, RSVP_F_COMMA, 360 }, { 12, RSVP_F_SENTENCE, 520 }, { 5, RSVP_F_PARA, 200 },
    };
    for (size_t i = 0; i < sizeof tab / sizeof tab[0]; i++) {
        rsvp_word_t w = { .len = tab[i].core, .glyphs = tab[i].core, .core = tab[i].core, .flags = tab[i].flags };
        CHECK_EQ(rsvp_word_ms(&w, 300), tab[i].ms);
    }
    rsvp_word_t w = { .len = 5, .glyphs = 5, .core = 5 };
    CHECK_EQ(rsvp_word_ms(&w, 250), 240);
    CHECK_EQ(rsvp_word_ms(&w, 600), 100);
    CHECK_EQ(rsvp_word_ms(&w, 1000), 60);
    CHECK_EQ(rsvp_word_ms(&w, 450), 133);            /* 133.33 rounded */
    CHECK_EQ(rsvp_word_ms(&w, 0), 1200);             /* clamped to 50 wpm */
    CHECK_EQ(rsvp_word_ms(&w, 60000), 40);           /* clamped to 1500 wpm */
    CHECK_EQ(rsvp_blank_ms(&w), 0);
    w.flags = RSVP_F_PARA;
    CHECK_EQ(rsvp_blank_ms(&w), RSVP_PARA_BLANK_MS);
    /* a word without letters uses its glyph count */
    rsvp_word_t p = { .len = 12, .glyphs = 12 };
    CHECK_EQ(rsvp_word_ms(&p, 300), 320);
    /* totals */
    rsvp_word_t ws[64];
    rsvp_stats_t st;
    const char *t = "One two three, four.\n\nFive extraordinary words here.";
    size_t n = tok(t, ws, 64, &st);
    uint64_t sum = 0;
    for (size_t i = 0; i < n; i++) sum += rsvp_word_ms(&ws[i], 300) + rsvp_blank_ms(&ws[i]);
    CHECK_EQ(rsvp_total_ms(st.factor_x10, st.paragraphs, 300), sum);   /* exact at 300 wpm */
    CHECK_EQ(rsvp_minutes(0), 1);
    CHECK_EQ(rsvp_minutes(89999), 1);
    CHECK_EQ(rsvp_minutes(90000), 2);
    CHECK_EQ(rsvp_minutes(240000), 4);
}

/* ------------------------------------------------------------------------------------------ */
/* Font document                                                                              */

static void test_font_parse(void) {
    rsvp_font_t *f = malloc(sizeof *f);
    char err[80];
    char *j = font_json(NG, true);
    CHECK_EQ(rsvp_font_parse(j, strlen(j), f, err, sizeof err), RSVP_OK);
    CHECK_EQ(f->normal.count, NG);
    CHECK(f->has_compact);
    CHECK_EQ(f->normal.cell_w, 12); CHECK_EQ(f->compact.cell_h, 14);
    CHECK(!strcmp(f->normal.atlas_white, "tw")); CHECK(!strcmp(f->compact.atlas_accent, "ca"));
    CHECK_EQ(rsvp_face_lookup(&f->normal, 'a'), 0);
    CHECK_EQ(rsvp_face_lookup(&f->normal, 0xE9), glyph_index("\xC3\xA9"));
    CHECK_EQ(rsvp_face_lookup(&f->normal, 0x23F8), glyph_index("\xE2\x8F\xB8"));
    CHECK_EQ(rsvp_face_lookup(&f->normal, 'Z'), -1);
    CHECK(f->normal.qmark >= 0);
    CHECK_EQ(f->normal.space_adv, 10);
    for (int i = 1; i < f->normal.count; i++) CHECK(f->normal.map[i - 1].cp < f->normal.map[i].cp);
    free(j);

    /* escapes: \u00e9, a surrogate pair, \" and \/ ; any key order; compact null */
    const char *esc = "{\"atlas_accent\":\"a2\",\"compact\":null,\"advance\":[5,6,7,8,9],\"baseline\":3,"
                      "\"glyphs\":\"\\u00e9\\ud83d\\ude00\\\"\\/x\",\"cell_h\":4,\"cell_w\":4,\"atlas_white\":\"a1\"}";
    CHECK_EQ(rsvp_font_parse(esc, strlen(esc), f, err, sizeof err), RSVP_OK);
    CHECK_EQ(f->normal.count, 5);
    CHECK(!f->has_compact);
    CHECK_EQ(rsvp_face_lookup(&f->normal, 0xE9), 0);
    CHECK_EQ(rsvp_face_lookup(&f->normal, 0x1F600), 1);
    CHECK_EQ(rsvp_face_lookup(&f->normal, '"'), 2);
    CHECK_EQ(rsvp_face_lookup(&f->normal, '/'), 3);
    CHECK_EQ(f->normal.qmark, -1);
    CHECK_EQ(f->normal.space_adv, 1);   /* no space glyph: cell_w/4 */

    struct { const char *doc; const char *why; } bad[] = {
        { "{\"glyphs\":\"ab\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "advance count" },
        { "{\"glyphs\":\"aa\",\"advance\":[1,1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "duplicate" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"A\",\"atlas_accent\":\"b\"}", "bad id" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":5,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "baseline" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":537,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "cell_w" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":0,\"baseline\":0,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "cell_h" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\"}", "missing accent" },
        { "{\"glyphs\":\"\",\"advance\":[],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "empty" },
        { "{\"glyphs\":\"a\",\"advance\":[1.5],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "fraction" },
        { "{\"glyphs\":\"a\",\"advance\":[-1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "negative" },
        { "{\"glyphs\":\"\xC3\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "bad utf8" },
        { "{\"glyphs\":\"\\ud800\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}", "lone surrogate" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"} x", "trailing" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\",\"compact\":{}}", "empty compact" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\",\"compact\":5}", "compact not object" },
        { "[1,2]", "not an object" },
        { "", "empty doc" },
        { "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\",\"x\":[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]}", "too deep" },
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        err[0] = '\0';
        rsvp_status_t st = rsvp_font_parse(bad[i].doc, strlen(bad[i].doc), f, err, sizeof err);
        if (st != RSVP_ERR_FONT) fprintf(stderr, "bad font doc accepted: %s\n", bad[i].why);
        CHECK_EQ(st, RSVP_ERR_FONT);
        CHECK(err[0] != '\0');
    }
    /* 257 glyphs */
    char *big = malloc(8192);
    size_t o = (size_t)snprintf(big, 8192, "{\"glyphs\":\"");
    for (int i = 0; i < 257; i++) o += (size_t)snprintf(big + o, 8192 - o, "\\u%04x", 0x100 + i);
    o += (size_t)snprintf(big + o, 8192 - o, "\",\"advance\":[");
    for (int i = 0; i < 257; i++) o += (size_t)snprintf(big + o, 8192 - o, "%s1", i ? "," : "");
    snprintf(big + o, 8192 - o, "],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\",\"atlas_accent\":\"b\"}");
    CHECK_EQ(rsvp_font_parse(big, strlen(big), f, err, sizeof err), RSVP_ERR_FONT);
    free(big);
    CHECK_EQ(rsvp_font_parse(NULL, 0, f, err, sizeof err), RSVP_ERR_ARG);
    /* §5f.11 a "large" face: parsed like compact, bound on its own; null = none; broken = refused */
    const char *lg = "{\"glyphs\":\"ab\",\"advance\":[3,4],\"cell_w\":4,\"cell_h\":6,\"baseline\":5,\"atlas_white\":\"a\","
                     "\"atlas_accent\":\"b\",\"large\":{\"glyphs\":\"ab\",\"advance\":[5,6],\"cell_w\":6,\"cell_h\":9,"
                     "\"baseline\":7,\"atlas_white\":\"lw\",\"atlas_accent\":\"la\"}}";
    CHECK_EQ(rsvp_font_parse(lg, strlen(lg), f, err, sizeof err), RSVP_OK);
    CHECK(f->has_large && !f->large_bound && !f->has_compact);
    CHECK(f->large.cell_h == 9 && !strcmp(f->large.atlas_white, "lw") && f->large.map[1].advance == 6);
    const char *ln = "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\","
                     "\"atlas_accent\":\"b\",\"large\":null}";
    CHECK_EQ(rsvp_font_parse(ln, strlen(ln), f, err, sizeof err), RSVP_OK);
    CHECK(!f->has_large);
    const char *lb = "{\"glyphs\":\"a\",\"advance\":[1],\"cell_w\":4,\"cell_h\":4,\"baseline\":3,\"atlas_white\":\"a\","
                     "\"atlas_accent\":\"b\",\"large\":{\"glyphs\":\"a\"}}";
    CHECK_EQ(rsvp_font_parse(lb, strlen(lb), f, err, sizeof err), RSVP_ERR_FONT);
    CHECK(strstr(err, "large") != NULL);
    CHECK_EQ(rsvp_font_bind_large(f, NULL, NULL), RSVP_ERR_ARG);   /* (the failed parse left no large face) */
    free(f);
}

static void test_font_bind(void) {
    tfont_t t;
    CHECK(tfont_make(&t, NG, true));
    CHECK(t.font.compact_bound);
    CHECK_EQ(t.scratch_px, 12 * 20);
    /* wrong cell size, not an atlas, too few frames */
    rsvp_font_t f2 = t.font;
    CHECK_EQ(rsvp_font_bind(&f2, &t.a[2], &t.a[1], NULL, NULL), RSVP_ERR_ATLAS);
    hca_asset_t na = t.a[0];
    na.hdr.flags = 0;
    CHECK_EQ(rsvp_font_bind(&f2, &na, &t.a[1], NULL, NULL), RSVP_ERR_ATLAS);
    hca_asset_t few = t.a[0];
    few.hdr.frame_count = NG - 1;
    CHECK_EQ(rsvp_font_bind(&f2, &few, &t.a[1], NULL, NULL), RSVP_ERR_ATLAS);
    CHECK_EQ(rsvp_font_bind(&f2, &t.a[0], &t.a[1], &t.a[0], &t.a[1]), RSVP_ERR_ATLAS);   /* compact geometry */
    CHECK_EQ(rsvp_font_bind(&f2, NULL, &t.a[1], NULL, NULL), RSVP_ERR_ATLAS);
    /* compact atlases omitted: compact unused */
    CHECK_EQ(rsvp_font_bind(&f2, &t.a[0], &t.a[1], NULL, NULL), RSVP_OK);
    CHECK(!f2.compact_bound);
    /* §5f.11 the large face: bound with its own atlases (here the normal ones, same geometry), widens the scratch */
    rsvp_font_t f3 = t.font;
    CHECK_EQ(rsvp_font_bind_large(&f3, &t.a[0], &t.a[1]), RSVP_ERR_ARG);   /* the document has none */
    f3.has_large = true;
    f3.large = f3.normal;
    f3.large.white = f3.large.accent = NULL;
    CHECK_EQ(rsvp_font_bind_large(&f3, &t.a[2], &t.a[1]), RSVP_ERR_ATLAS);   /* compact geometry */
    CHECK(!f3.large_bound);
    CHECK_EQ(rsvp_font_bind_large(&f3, &t.a[0], &t.a[1]), RSVP_OK);
    CHECK(f3.large_bound && f3.large.white == &t.a[0]);
    CHECK_EQ(rsvp_font_scratch_px(&f3), 12 * 20);
    tfont_free(&t);
}

/* ------------------------------------------------------------------------------------------ */
/* Layout                                                                                     */

static void test_layout_centring(void) {
    tfont_t t;
    CHECK(tfont_make(&t, NG, true));
    const char *words[] = { "a", "to", "the", "word", "lumen", "almost", "catalog", "pqrstuvw", "abcdefghi",
                            "\"quoi\"", ("l\xE2\x80\x99" "\xC3\xA9t\xC3\xA9,"), "milliwatts", "i", "mmm", "...", "\xE2\x80\x94" };
    for (size_t k = 0; k < sizeof words / sizeof words[0]; k++) {
        rsvp_glyph_pos_t pos[64];
        rsvp_layout_t lay;
        CHECK_EQ(rsvp_layout(&t.font, words[k], strlen(words[k]), RSVP_ORP_X, FW, 8, pos, 64, &lay), RSVP_OK);
        CHECK(!lay.compact);
        CHECK(!lay.shifted && !lay.clipped);
        /* centre of the ORP glyph's advance at the ORP column, within 1 px */
        int c2 = 2 * pos[lay.orp].x + pos[lay.orp].advance;   /* twice the centre */
        CHECK(abs(c2 - 2 * RSVP_ORP_X) <= 2);
        CHECK_EQ(pos[lay.orp].accent, 1);
        int accents = 0;
        for (int i = 0; i < lay.n; i++) accents += pos[i].accent;
        CHECK_EQ(accents, 1);
        /* matches the tokeniser's ORP */
        rsvp_word_t w;
        CHECK(rsvp_word_at(words[k], strlen(words[k]), true, &w));
        CHECK_EQ(lay.orp, rsvp_word_orp(&w));
        /* pens advance monotonically by the advances */
        for (int i = 1; i < lay.n; i++) CHECK_EQ(pos[i].x, pos[i - 1].x + pos[i - 1].advance);
    }
    tfont_free(&t);
}

static void test_layout_compact(void) {
    tfont_t t;
    CHECK(tfont_make(&t, NG, true));
    rsvp_glyph_pos_t pos[64];
    rsvp_layout_t lay;
    /* normal advance 10: 30 glyphs = 300 px; ORP index 4 at 230 -> right edge 230-45+300 = 485 fits;
     * with a narrow screen (300 px) it does not fit normal, compact (6 px) does */
    const char *w = "abcdefghijklmnopqrstuvwxyzabcd";
    CHECK_EQ(rsvp_layout(&t.font, w, strlen(w), 120, 300, 8, pos, 64, &lay), RSVP_OK);
    CHECK(lay.compact);
    CHECK(lay.face == &t.font.compact);
    CHECK(!lay.shifted && !lay.clipped);
    CHECK(abs(2 * pos[lay.orp].x + pos[lay.orp].advance - 240) <= 2);
    CHECK(lay.text_x0 >= 8 && lay.text_x1 <= 292);
    /* fits only when shifted: compact 30*6 = 180 px, ORP pinned near the left edge */
    CHECK_EQ(rsvp_layout(&t.font, w, strlen(w), 20, 300, 8, pos, 64, &lay), RSVP_OK);
    CHECK(lay.compact && lay.shifted && !lay.clipped);
    CHECK_EQ(lay.text_x0, 8);
    /* too wide even compact: clipped, ORP pinned */
    CHECK_EQ(rsvp_layout(&t.font, w, strlen(w), 60, 120, 8, pos, 64, &lay), RSVP_OK);
    CHECK(lay.compact && lay.clipped && !lay.shifted);
    CHECK(abs(2 * pos[lay.orp].x + pos[lay.orp].advance - 120) <= 2);
    /* without compact: the normal size is shifted / clipped */
    tfont_t n;
    CHECK(tfont_make(&n, NG, false));
    CHECK_EQ(rsvp_layout(&n.font, w, strlen(w), 120, 330, 8, pos, 64, &lay), RSVP_OK);
    CHECK(!lay.compact && lay.shifted);
    CHECK_EQ(rsvp_layout(&n.font, w, strlen(w), 120, 300, 8, pos, 64, &lay), RSVP_OK);
    CHECK(!lay.compact && lay.clipped);
    /* errors */
    CHECK_EQ(rsvp_layout(&n.font, "", 0, 120, 300, 8, pos, 64, &lay), RSVP_ERR_ARG);
    rsvp_font_t unbound = n.font;
    unbound.normal.white = NULL;
    CHECK_EQ(rsvp_layout(&unbound, "a", 1, 120, 300, 8, pos, 64, &lay), RSVP_ERR_ARG);
    /* cap limits the glyphs placed */
    CHECK_EQ(rsvp_layout(&n.font, w, strlen(w), 120, 536, 8, pos, 5, &lay), RSVP_OK);
    CHECK_EQ(lay.n, 5);
    tfont_free(&n);
    tfont_free(&t);
}

/* ------------------------------------------------------------------------------------------ */
/* Painting                                                                                   */

static uint16_t *new_fb(void) { return calloc((size_t)FW * FH, 2); }

static int count_px(const uint16_t *fb, int x0, int y0, int x1, int y1, uint16_t native) {
    int n = 0;
    uint16_t v = th_be(native);
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) n += fb[y * FW + x] == v;
    return n;
}

/* every pixel that differs between a and b lies inside r */
static bool diff_inside(const uint16_t *a, const uint16_t *b, rsvp_rect_t r) {
    for (int y = 0; y < FH; y++)
        for (int x = 0; x < FW; x++)
            if (a[y * FW + x] != b[y * FW + x] && !(x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)) return false;
    return true;
}

static void test_paint_word(void) {
    tfont_t t;
    CHECK(tfont_make(&t, NG, true));
    rsvp_painter_t p;
    rsvp_painter_init(&p, &t.font, FW, FH, RSVP_ORP_X);
    CHECK_EQ(p.band_h, 20);                 /* normal asc 16 + desc 4 covers compact 11 + 3 */
    CHECK_EQ(p.band_y, (FH - 20) / 2);
    CHECK_EQ(p.baseline_y, p.band_y + 16);
    uint16_t *fb = new_fb(), *prev = new_fb(), *ref = new_fb();
    for (int i = 0; i < FW * FH; i++) fb[i] = 0xABCD;   /* garbage: the first paint clears everything */
    rsvp_rect_t d;
    rsvp_layout_t lay;
    CHECK_EQ(rsvp_paint(&p, &t.font, "catalog", 7, fb, t.scratch, t.scratch_px, &d, &lay), 0);
    CHECK(d.x == 0 && d.y == 0 && d.w == FW && d.h == FH);
    CHECK_EQ(lay.orp, 2);
    /* ticks: 2 px wide at orp_x-1..orp_x, 12 px above and below the band */
    CHECK_EQ(count_px(fb, 0, 0, FW, p.band_y, RSVP_TICK_COLOR), 2 * 12);
    CHECK_EQ(count_px(fb, 0, p.band_y + p.band_h, FW, FH, RSVP_TICK_COLOR), 2 * 12);
    CHECK_EQ(count_px(fb, RSVP_ORP_X - 1, 0, RSVP_ORP_X + 1, p.band_y, RSVP_TICK_COLOR), 24);
    /* the ORP glyph ('t') from the accent atlas sits on the ORP column; other letters are white */
    int gt = glyph_index("t"), gc = glyph_index("c");
    int y_mid = p.baseline_y - 2;
    CHECK_EQ(fb[y_mid * FW + RSVP_ORP_X], th_be(tag_px(NORMAL.accent_tag, gt)));
    CHECK(count_px(fb, 0, 0, FW, FH, tag_px(NORMAL.accent_tag, gt)) > 0);
    CHECK_EQ(count_px(fb, 0, 0, FW, FH, tag_px(NORMAL.white_tag, gt)), 0);
    CHECK(count_px(fb, 0, 0, FW, FH, tag_px(NORMAL.white_tag, gc)) > 0);
    /* nothing outside the band except the ticks */
    int stray = 0;
    for (int y = 0; y < FH; y++)
        for (int x = 0; x < FW; x++)
            if ((y < p.band_y || y >= p.band_y + p.band_h) && fb[y * FW + x] && fb[y * FW + x] != th_be(RSVP_TICK_COLOR)) stray++;
    CHECK_EQ(stray, 0);

    /* second word: partial repaint restores black where "catalog" was; result == a fresh full paint */
    memcpy(prev, fb, (size_t)FW * FH * 2);
    CHECK_EQ(rsvp_paint(&p, &t.font, "a", 1, fb, t.scratch, t.scratch_px, &d, &lay), 0);
    CHECK_EQ(d.y, p.band_y); CHECK_EQ(d.h, p.band_h);
    CHECK(d.w > 0 && d.w < FW);
    CHECK(diff_inside(prev, fb, d));
    rsvp_painter_t q;
    rsvp_painter_init(&q, &t.font, FW, FH, RSVP_ORP_X);
    rsvp_rect_t d2;
    rsvp_paint(&q, &t.font, "a", 1, ref, t.scratch, t.scratch_px, &d2, NULL);
    CHECK(memcmp(ref, fb, (size_t)FW * FH * 2) == 0);
    /* the dirty rect covers the union of both words' cells */
    rsvp_layout_t la, lb;
    rsvp_glyph_pos_t pp[64];
    rsvp_layout(&t.font, "catalog", 7, RSVP_ORP_X, FW, 8, pp, 64, &la);
    rsvp_layout(&t.font, "a", 1, RSVP_ORP_X, FW, 8, pp, 64, &lb);
    CHECK_EQ(d.x, la.x0 < lb.x0 ? la.x0 : lb.x0);
    CHECK_EQ(d.x + d.w, la.x1 > lb.x1 ? la.x1 : lb.x1);

    /* a run of words: after each paint the framebuffer equals a fresh render and diffs stay inside */
    const char *seq[] = { "milliwatts", "to", "\xE2\x80\x94", "abcdefghijklmnopqrstuvwxyzabcdefgh", "i", "",
                          "l\xE2\x80\x99\xC3\xA9t\xC3\xA9,", "mmm" };
    for (size_t k = 0; k < sizeof seq / sizeof seq[0]; k++) {
        memcpy(prev, fb, (size_t)FW * FH * 2);
        rsvp_paint(&p, &t.font, seq[k], strlen(seq[k]), fb, t.scratch, t.scratch_px, &d, NULL);
        CHECK(diff_inside(prev, fb, d));
        rsvp_painter_init(&q, &t.font, FW, FH, RSVP_ORP_X);
        rsvp_paint(&q, &t.font, seq[k], strlen(seq[k]), ref, t.scratch, t.scratch_px, &d2, NULL);
        CHECK(memcmp(ref, fb, (size_t)FW * FH * 2) == 0);
    }
    /* blank (paragraph pause): band cleared, ticks stay */
    rsvp_paint(&p, &t.font, "word", 4, fb, t.scratch, t.scratch_px, &d, NULL);
    rsvp_paint(&p, &t.font, NULL, 0, fb, t.scratch, t.scratch_px, &d, NULL);
    CHECK(d.w > 0);
    CHECK_EQ(count_px(fb, 0, p.band_y, FW, p.band_y + p.band_h, 0), FW * p.band_h);
    CHECK_EQ(count_px(fb, 0, 0, FW, FH, RSVP_TICK_COLOR), 48);
    /* blank after blank: nothing to do */
    rsvp_paint(&p, &t.font, NULL, 0, fb, t.scratch, t.scratch_px, &d, NULL);
    CHECK(d.w == 0 || d.h == 0);
    /* invalidate -> full repaint */
    rsvp_painter_invalidate(&p);
    rsvp_paint(&p, &t.font, "a", 1, fb, t.scratch, t.scratch_px, &d, NULL);
    CHECK(d.w == FW && d.h == FH);
    /* scratch too small: glyphs reported as failed, no overflow */
    CHECK(rsvp_paint(&p, &t.font, "abc", 3, fb, t.scratch, 10, &d, NULL) == 3);
    free(fb); free(prev); free(ref);
    tfont_free(&t);
}

static void test_paint_compact_and_missing(void) {
    tfont_t t;
    CHECK(tfont_make(&t, NG, true));
    rsvp_painter_t p;
    rsvp_painter_init(&p, &t.font, 300, 60, 120);
    uint16_t *fb = calloc(300 * 60, 2);
    rsvp_rect_t d;
    rsvp_layout_t lay;
    const char *w = "abcdefghijklmnopqrstuvwxyzabcd";
    rsvp_paint(&p, &t.font, w, strlen(w), fb, t.scratch, t.scratch_px, &d, &lay);
    CHECK(lay.compact);
    int compact_px = 0, normal_px = 0;
    for (int i = 0; i < 300 * 60; i++) {
        uint16_t v = th_be(fb[i]);   /* back to native */
        if ((v & 0xF000) == COMPACT.white_tag || (v & 0xF000) == COMPACT.accent_tag) compact_px++;
        if ((v & 0xF000) == NORMAL.white_tag || (v & 0xF000) == NORMAL.accent_tag) normal_px++;
    }
    CHECK(compact_px > 0);
    CHECK_EQ(normal_px, 0);
    /* compact glyphs share the baseline: the ORP column at baseline-2 is the accent glyph */
    int go = glyph_index("e");   /* 30 letters, core 30 -> ORP index 4 = 'e' */
    CHECK_EQ(lay.orp, 4);
    CHECK_EQ(fb[(p.baseline_y - 2) * 300 + 120], th_be(tag_px(COMPACT.accent_tag, go)));
    free(fb);

    /* missing glyph -> '?' ; a font without '?' draws nothing for it */
    uint16_t *big = new_fb();
    rsvp_painter_init(&p, &t.font, FW, FH, RSVP_ORP_X);
    rsvp_paint(&p, &t.font, "\xE2\x98\x83", 3, big, t.scratch, t.scratch_px, &d, &lay);   /* ☃ */
    int gq = glyph_index("?");
    CHECK(count_px(big, 0, 0, FW, FH, tag_px(NORMAL.accent_tag, gq)) > 0);
    tfont_t nq;
    CHECK(tfont_make(&nq, glyph_index("?"), false));   /* glyph set stops before '?' */
    CHECK_EQ(nq.font.normal.qmark, -1);
    rsvp_painter_init(&p, &nq.font, FW, FH, RSVP_ORP_X);
    CHECK_EQ(rsvp_paint(&p, &nq.font, "Z\xE2\x98\x83", 4, big, nq.scratch, nq.scratch_px, &d, &lay), 0);
    int ink = 0;
    for (int i = 0; i < FW * FH; i++) ink += big[i] && big[i] != th_be(RSVP_TICK_COLOR);
    CHECK_EQ(ink, 0);
    tfont_free(&nq);
    free(big);
    tfont_free(&t);
}

static void test_end_card(void) {
    char s[64];
    CHECK(rsvp_end_card_text(1234, 4, s, sizeof s) > 0);
    CHECK(!strcmp(s, "1 234 words \xC2\xB7 4 min"));
    rsvp_end_card_text(1, 1, s, sizeof s);
    CHECK(!strcmp(s, "1 word \xC2\xB7 1 min"));
    rsvp_end_card_text(1234567, 300, s, sizeof s);
    CHECK(!strcmp(s, "1 234 567 words \xC2\xB7 300 min"));
    rsvp_end_card_text(999, 2, s, sizeof s);
    CHECK(!strcmp(s, "999 words \xC2\xB7 2 min"));
    CHECK_EQ(rsvp_end_card_text(1234, 4, s, 8), 0);

    tfont_t t;
    CHECK(tfont_make(&t, NG, true));
    rsvp_painter_t p;
    rsvp_painter_init(&p, &t.font, FW, FH, RSVP_ORP_X);
    uint16_t *fb = new_fb();
    for (int i = 0; i < FW * FH; i++) fb[i] = 0x1234;
    rsvp_rect_t d;
    CHECK_EQ(rsvp_paint_end_card(&p, &t.font, 1234, 4, fb, t.scratch, t.scratch_px, &d), 0);
    CHECK(d.w == FW && d.h == FH);
    CHECK(p.full);
    int old = 0;
    for (int i = 0; i < FW * FH; i++) old += fb[i] == 0x1234;
    CHECK_EQ(old, 0);   /* old content gone */
    int gf = glyph_index("f"), g1 = glyph_index("1"), gdot = glyph_index("\xC2\xB7");
    CHECK(count_px(fb, 0, 0, FW, FH, tag_px(NORMAL.accent_tag, gf)) > 0);    /* "fin" in accent, normal size */
    CHECK(count_px(fb, 0, 0, FW, FH, tag_px(NORMAL.white_tag, g1)) > 0);     /* second line fits normal */
    CHECK(count_px(fb, 0, 0, FW, FH, tag_px(NORMAL.white_tag, gdot)) > 0);
    /* symmetric-ish: ink is centred horizontally */
    int minx = FW, maxx = -1;
    for (int y = 0; y < FH; y++)
        for (int x = 0; x < FW; x++)
            if (fb[y * FW + x]) { if (x < minx) minx = x; if (x > maxx) maxx = x; }
    CHECK(abs((minx + maxx) / 2 - FW / 2) <= 12);
    /* a narrow screen forces a smaller size for the second line */
    rsvp_painter_t pn;
    rsvp_painter_init(&pn, &t.font, 160, 100, 60);
    uint16_t *small = calloc(160 * 100, 2);
    CHECK_EQ(rsvp_paint_end_card(&pn, &t.font, 1234, 4, small, t.scratch, t.scratch_px, &d), 0);
    int cpx = 0;
    for (int i = 0; i < 160 * 100; i++) cpx += (th_be(small[i]) & 0xF000) == COMPACT.white_tag;
    CHECK(cpx > 0);
    free(small);
    /* missing glyphs ('·' and 'w' absent: glyph set cut before them) are substituted with '?' */
    tfont_t nd;
    CHECK(tfont_make(&nd, glyph_index("w"), false));
    rsvp_painter_init(&p, &nd.font, FW, FH, RSVP_ORP_X);
    int missing = rsvp_paint_end_card(&p, &nd.font, 1234, 4, fb, nd.scratch, nd.scratch_px, &d);
    CHECK_EQ(missing, 7);   /* digits 1 2 3 4 4, 'w', '·' ('?' is absent too: drawn as nothing) */
    tfont_free(&nd);
    free(fb);
    tfont_free(&t);
}

static void test_pause_mark(void) {
    tfont_t t;
    CHECK(tfont_make(&t, NG, true));
    rsvp_painter_t p;
    rsvp_painter_init(&p, &t.font, FW, FH, RSVP_ORP_X);
    uint16_t *fb = new_fb();
    rsvp_rect_t d;
    rsvp_paint(&p, &t.font, "word", 4, fb, t.scratch, t.scratch_px, &d, NULL);
    rsvp_paint_pause(&p, &t.font, true, fb, t.scratch, t.scratch_px, &d);
    CHECK(d.w == p.pause_box.w && d.h == p.pause_box.h && d.x == p.pause_box.x);
    CHECK(d.x + d.w <= FW && d.y >= 0);
    int gp = glyph_index("\xE2\x8F\xB8");
    CHECK(count_px(fb, d.x, d.y, d.x + d.w, d.y + d.h, tag_px(NORMAL.accent_tag, gp)) > 0);
    rsvp_paint_pause(&p, &t.font, false, fb, t.scratch, t.scratch_px, &d);
    CHECK_EQ(count_px(fb, d.x, d.y, d.x + d.w, d.y + d.h, 0), d.w * d.h);
    /* font without ⏸: 5x7 fallback, 2 bars x 2 columns x 7 rows of 3x3 px */
    tfont_t np;
    CHECK(tfont_make(&np, gp, false));
    rsvp_painter_init(&p, &np.font, FW, FH, RSVP_ORP_X);
    rsvp_paint_pause(&p, &np.font, true, fb, np.scratch, np.scratch_px, &d);
    CHECK_EQ(count_px(fb, d.x, d.y, d.x + d.w, d.y + d.h, RSVP_PAUSE_COLOR), 4 * 7 * 9);
    rsvp_paint_pause(&p, NULL, true, fb, NULL, 0, &d);   /* no font at all: fallback too */
    CHECK_EQ(count_px(fb, d.x, d.y, d.x + d.w, d.y + d.h, RSVP_PAUSE_COLOR), 4 * 7 * 9);
    tfont_free(&np);
    free(fb);
    tfont_free(&t);
}

/* ------------------------------------------------------------------------------------------ */
/* Fuzz + bench                                                                               */

static int fuzz_scale(void) {
    const char *e = getenv("RSVP_FUZZ_SCALE");
    int s = e ? atoi(e) : 1;
    return s < 1 ? 1 : s;
}

static void test_fuzz_tokeniser(void) {
    int iters = 400 * fuzz_scale();
    static char buf[4096];
    static const char *pieces[] = { " ", "\n", "\r\n", "\n\n", "\xC3\xA9", "\xE2\x80\x99", "\xE2\x80\x94", "\xC2\xA0",
                                    ".", ",", "!", "\xC2\xBB", "a", "Z", "9", "\xF0\x9F\x98\x80", "\xE2\x80\xA9", "\xC3" };
    int fails = 0;
    for (int it = 0; it < iters; it++) {
        size_t len = th_rand() % sizeof buf;
        bool structured = th_rand() & 1;
        size_t i = 0;
        while (i < len) {
            if (structured) {
                const char *pc = pieces[th_rand() % (sizeof pieces / sizeof pieces[0])];
                size_t k = strlen(pc);
                if (i + k > len) break;
                memcpy(buf + i, pc, k);
                i += k;
            } else {
                buf[i++] = (char)th_rand();
            }
        }
        len = i;
        check_streaming(buf, len);
        rsvp_word_t w[64];
        rsvp_stats_t st;
        size_t n = rsvp_tokenize(buf, len, w, 64, &st);
        for (size_t k = 0; k < n; k++) {
            if (w[k].off + w[k].len > len || w[k].glyphs == 0 || w[k].glyphs > RSVP_WORD_MAX_GLYPHS ||
                w[k].len > RSVP_WORD_MAX_BYTES || w[k].lead + w[k].core > w[k].glyphs) fails++;
            if (k && w[k].off < w[k - 1].off + w[k - 1].len) fails++;   /* ordered, non-overlapping */
        }
        if (st.bytes != len) fails++;
        char title[RSVP_TITLE_MAX];
        size_t tl = rsvp_title(buf, len, title, sizeof title);
        if (tl >= sizeof title || strlen(title) != tl) fails++;
    }
    CHECK_EQ(fails, 0);
}

static void test_fuzz_font_and_paint(void) {
    tfont_t t;
    CHECK(tfont_make(&t, NG, true));
    char *j = font_json(NG, true);
    size_t jl = strlen(j);
    rsvp_font_t *f = malloc(sizeof *f);
    char *m = malloc(jl + 1);
    int iters = 300 * fuzz_scale();
    for (int it = 0; it < iters; it++) {
        memcpy(m, j, jl);
        int muts = 1 + (int)(th_rand() % 4);
        for (int k = 0; k < muts; k++) m[th_rand() % jl] = (char)(th_rand() % 3 == 0 ? th_rand() : "{}[]\",:0\\u"[th_rand() % 11]);
        size_t ml = th_rand() % 8 == 0 ? th_rand() % jl : jl;
        char err[64];
        rsvp_font_parse(m, ml, f, err, sizeof err);   /* must not crash or read out of bounds */
    }
    free(m);
    free(f);
    free(j);
    /* random words through layout + paint */
    rsvp_painter_t p;
    rsvp_painter_init(&p, &t.font, FW, FH, RSVP_ORP_X);
    uint16_t *fb = new_fb();
    char w[200];
    int bad = 0;
    for (int it = 0; it < iters; it++) {
        size_t len = 1 + th_rand() % sizeof w;
        for (size_t i = 0; i < len; i++) w[i] = (char)(th_rand() % 4 ? 'a' + th_rand() % 26 : th_rand());
        int orp = (int)(th_rand() % 700) - 80;
        rsvp_painter_t q = p;
        q.orp_x = (int16_t)orp;   /* off-screen ORP columns too */
        rsvp_rect_t d;
        rsvp_paint(&q, &t.font, w, len, fb, t.scratch, t.scratch_px, &d, NULL);
        if (d.w < 0 || d.h < 0 || d.x < 0 || d.y < 0 || d.x + d.w > FW || d.y + d.h > FH) bad++;
        p.last_x0 = q.last_x0;
        p.last_x1 = q.last_x1;
        p.full = q.full;
    }
    CHECK_EQ(bad, 0);
    free(fb);
    tfont_free(&t);
}

static double now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

/* Host timing of layout + paint of a word with a realistically sized font (64x120 / 40x76 cells). */
static void bench_paint(void) {
    static const face_spec_t BN = { 72, 114, 92, 0x8000, 0x4000, 52 }, BC = { 44, 70, 56, 0x2000, 0x1000, 32 };
    char *buf = malloc(8192);
    size_t o = face_json(buf, 8192, &BN, "tw", "ta", NG);
    o += (size_t)snprintf(buf + o, 8192 - o, ",\"compact\":");
    o += face_json(buf + o, 8192 - o, &BC, "cw", "ca", NG);
    snprintf(buf + o, 8192 - o, "}}");
    rsvp_font_t *f = malloc(sizeof *f);
    CHECK_EQ(rsvp_font_parse(buf, strlen(buf), f, NULL, 0), RSVP_OK);
    uint8_t *d[4];
    hca_asset_t a[4];
    const face_spec_t *fs[4] = { &BN, &BN, &BC, &BC };
    for (int i = 0; i < 4; i++) {
        size_t n;
        d[i] = build_atlas(fs[i], i & 1, &n);
        CHECK_EQ(hca_open(&a[i], d[i], n), HCA_OK);
    }
    CHECK_EQ(rsvp_font_bind(f, &a[0], &a[1], &a[2], &a[3]), RSVP_OK);
    size_t sp = rsvp_font_scratch_px(f);
    uint16_t *scratch = malloc(sp * 2), *fb = new_fb();
    rsvp_painter_t p;
    rsvp_painter_init(&p, f, FW, FH, RSVP_ORP_X);
    const char *words[] = { "the", "catalog", "almost", "l\xE2\x80\x99\xC3\xA9t\xC3\xA9,", "milliwatts", "a" };
    rsvp_rect_t r;
    rsvp_paint(&p, f, "x", 1, fb, scratch, sp, &r, NULL);
    const int N = 2000;
    double t0 = now_us();
    long long area = 0;
    for (int i = 0; i < N; i++) {
        const char *w = words[i % 6];
        rsvp_paint(&p, f, w, strlen(w), fb, scratch, sp, &r, NULL);
        area += (long long)r.w * r.h;
    }
    double dt = (now_us() - t0) / N;
    printf("bench: layout+paint %.2f us/word (72x114 cells, avg dirty %lld px = %.1f%% of the frame)\n", dt,
           area / N, 100.0 * (double)(area / N) / (FW * FH));
    t0 = now_us();
    rsvp_glyph_pos_t pos[64];
    rsvp_layout_t lay;
    for (int i = 0; i < N * 10; i++) rsvp_layout(f, words[i % 6], strlen(words[i % 6]), RSVP_ORP_X, FW, 8, pos, 64, &lay);
    printf("bench: layout alone %.3f us/word\n", (now_us() - t0) / (N * 10));
    /* tokeniser throughput */
    size_t tl = 1 << 20;
    char *text = malloc(tl);
    const char *src = "L\xE2\x80\x99\xC3\xA9t\xC3\xA9 \xC3\xA9tait chaud, et la ville dormait. ";
    for (size_t i = 0; i < tl; i++) text[i] = src[i % strlen(src)];
    rsvp_stats_t st;
    t0 = now_us();
    rsvp_tokenize(text, tl, NULL, 0, &st);
    printf("bench: tokenise 1 MiB in %.1f ms (%u words)\n", (now_us() - t0) / 1000.0, (unsigned)st.words);
    free(text);
    for (int i = 0; i < 4; i++) free(d[i]);
    free(scratch); free(fb); free(f); free(buf);
}

int main(void) {
    RUN(test_utf8);
    RUN(test_tok_ascii);
    RUN(test_tok_french);
    RUN(test_tok_numbers_space);
    RUN(test_tok_long_and_invalid);
    RUN(test_tok_title_break);
    RUN(test_title);
    RUN(test_tok_streaming);
    RUN(test_orp_rule);
    RUN(test_timing);
    RUN(test_font_parse);
    RUN(test_font_bind);
    RUN(test_layout_centring);
    RUN(test_layout_compact);
    RUN(test_paint_word);
    RUN(test_paint_compact_and_missing);
    RUN(test_end_card);
    RUN(test_pause_mark);
    RUN(test_fuzz_tokeniser);
    RUN(test_fuzz_font_and_paint);
    bench_paint();
    return TH_DONE("test_rsvp");
}
