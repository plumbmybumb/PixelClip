/* rsvp.h — Reader mode (RSVP speed reading, docs/PROTOCOL.md §5c).
 *
 * C11, no allocation, no I/O. Three parts:
 *
 *  1. Tokeniser. A streaming iterator (rsvp_tok_*) that is fed a UTF-8 text in chunks of any size
 *     (a 1 MB text can be indexed from flash or straight from the HTTP body with a few hundred bytes
 *     of state) and yields words as byte ranges with timing flags. rsvp_tokenize() is the one-shot
 *     convenience wrapper. UTF-8 safe: a word never ends inside a multibyte sequence, invalid bytes
 *     are counted (rsvp_stats_t.invalid) and become one glyph each.
 *  2. Timing and ORP: rsvp_word_ms() / rsvp_blank_ms() implement the §5c factors exactly,
 *     rsvp_orp_index() the Spritz rule (in glyphs).
 *  3. Font model and painter: rsvp_font_parse() reads the §5c font document, rsvp_font_bind()
 *     attaches the white/accent glyph atlases (.hca, frames in memory), rsvp_layout() places a word
 *     with its ORP glyph centred on a fixed column, rsvp_paint() draws it into an RGB565BE
 *     framebuffer and reports the dirty rectangle; rsvp_paint_end_card() / rsvp_paint_pause() draw
 *     the "fin" card and the pause mark with the same font.
 *
 * Word segmentation rules (normative for the firmware's word index, see core/README.md "Reader"):
 *  - Separators: ASCII whitespace and control characters (incl. NUL), U+0085, U+1680, U+2000–U+200B
 *    (except U+2007), U+2028, U+2029, U+205F, U+3000, U+FEFF. Everything else belongs to a word.
 *  - No-break spaces U+00A0, U+2007, U+202F join ("Bonjour !" is one word); the painter draws them
 *    as a space.
 *  - Apostrophes (U+0027, U+2019) and hyphens inside a word are part of it ("l’homme", "peut-être").
 *  - En/em dashes and U+2015 end the word they are attached to ("oui—non" → "oui—", "non"); a
 *    free-standing dash is a word of its own. A word ending in a dash pauses like a comma.
 *  - Words longer than RSVP_WORD_MAX_GLYPHS glyphs are split into pieces of that many glyphs.
 *  - Flags come from the last glyph that is not a closing quote/bracket or a no-break space:
 *    . ! ? … (and the full-width forms) → sentence end; , ; (and full-width) → comma pause. A blank line (two or more line breaks
 *    with only whitespace between) or U+2029 after a word → paragraph break. With RSVP_TOK_TITLE_BREAK
 *    the first line break of the text also counts as a paragraph break (the title line is read first,
 *    followed by the 300 ms blank).
 *  - "Length" for timing and the ORP is the word's core: from its first to its last letter/digit
 *    (leading/trailing punctuation excluded; a word without letters uses all its glyphs).
 */
#ifndef RSVP_H
#define RSVP_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "hca.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Constants (PROTOCOL §5c) ------------------------------------------------------------------ */

#define RSVP_WORD_MAX_GLYPHS 32      /* longer words are split */
#define RSVP_WORD_MAX_BYTES  (RSVP_WORD_MAX_GLYPHS * 4)   /* upper bound of rsvp_word_t.len */
#define RSVP_WPM_MIN        50
#define RSVP_WPM_MAX        1500
#define RSVP_WPM_DEFAULT    300
#define RSVP_PARA_BLANK_MS  300      /* blank shown after a word that ends a paragraph */
#define RSVP_ORP_X          230      /* screen column of the ORP glyph's centre */
#define RSVP_END_CARD_MS    3000
#define RSVP_MAX_GLYPHS     256      /* glyphs per font size (atlas frames) */
#define RSVP_FONT_JSON_MAX  16384    /* rsvp_font_parse rejects longer documents */
#define RSVP_TITLE_MAX      64       /* title buffer incl. NUL (rsvp_title) */
#define RSVP_TICK_COLOR     0x520Du  /* native RGB565 of the brand "dim" #52416B: ORP tick marks */
#define RSVP_PAUSE_COLOR    0xC51Fu  /* native RGB565 of the brand accent #C6A2FF: 5x7 pause mark */

/* Word flags */
enum {
    RSVP_F_COMMA    = 1u << 0,   /* ends with , ; (or a dash): +50 % */
    RSVP_F_SENTENCE = 1u << 1,   /* ends a sentence: +100 % (wins over COMMA) */
    RSVP_F_PARA     = 1u << 2,   /* followed by a paragraph break: RSVP_PARA_BLANK_MS blank after it */
};

typedef struct {
    uint32_t off;      /* byte offset of the word's first byte in the text */
    uint16_t len;      /* bytes (<= RSVP_WORD_MAX_BYTES) */
    uint8_t  glyphs;   /* code points (invalid bytes count as one each), 1..RSVP_WORD_MAX_GLYPHS */
    uint8_t  lead;     /* glyphs before the first letter/digit */
    uint8_t  core;     /* glyphs from the first to the last letter/digit, 0 if there is none */
    uint8_t  flags;    /* RSVP_F_* */
} rsvp_word_t;

typedef struct {
    uint32_t words;
    uint32_t sentences;     /* words with RSVP_F_SENTENCE */
    uint32_t paragraphs;    /* words with RSVP_F_PARA */
    uint32_t invalid;       /* invalid UTF-8 sequences (each one glyph) */
    uint32_t nul;           /* NUL bytes (separators) */
    uint32_t bytes;         /* bytes fed */
    uint64_t factor_x10;    /* sum of rsvp_word_factor_x10() over all words (for rsvp_total_ms) */
    uint8_t  max_glyphs;    /* longest word */
} rsvp_stats_t;

/* ---- UTF-8 ------------------------------------------------------------------------------------ */

#define RSVP_CP_INVALID 0x110000u   /* code point reported for an invalid byte sequence */

/* Decode the first glyph of s[0..n): returns its length in bytes (1..4; 0 only when n == 0) and the
 * code point (RSVP_CP_INVALID for an invalid sequence, which then covers the bytes read until the
 * sequence broke, at least 1). Same segmentation as the tokeniser. */
size_t rsvp_utf8_next(const char *s, size_t n, uint32_t *cp);

/* ---- Tokeniser -------------------------------------------------------------------------------- */

enum { RSVP_TOK_TITLE_BREAK = 1u << 0 };

/* Streaming state (~100 bytes, plain data). Fields are private. */
typedef struct {
    uint32_t pos;                 /* absolute offset of the next byte */
    unsigned opts;
    /* UTF-8 decoder */
    uint32_t u_cp, u_min, u_start;
    uint8_t u_need, u_len;
    /* current word */
    bool in_word;
    uint8_t w_glyphs, w_first, w_last, w_term;
    bool w_has_letter;
    uint32_t w_off, w_end;
    /* separator run since the last word */
    uint8_t nl;
    bool prev_cr, seen_nl;
    /* finished word waiting for its paragraph flag */
    bool has_pending;
    rsvp_word_t pending;
    rsvp_stats_t st;
} rsvp_tok_t;

/* Start tokenising. `base_off` is the absolute offset of the first byte that will be fed (0 for a
 * whole file); `opts` is RSVP_TOK_* flags. */
void rsvp_tok_init(rsvp_tok_t *t, uint32_t base_off, unsigned opts);

/* Feed buf[0..len). Writes completed words to out[0..cap) and returns how many were written. Stops
 * early when `out` is nearly full (cap < 2 words of room); *consumed (may be NULL only if you know
 * cap is large enough: at most 2*len words can come out) receives the bytes actually consumed, feed
 * the rest again. */
size_t rsvp_tok_feed(rsvp_tok_t *t, const char *buf, size_t len, size_t *consumed,
                     rsvp_word_t *out, size_t cap);

/* End of text: flush a partial UTF-8 sequence and the last word(s). Needs cap >= 2. Returns the
 * number of words written. */
size_t rsvp_tok_finish(rsvp_tok_t *t, rsvp_word_t *out, size_t cap);

/* Statistics so far (complete after rsvp_tok_finish). */
static inline const rsvp_stats_t *rsvp_tok_stats(const rsvp_tok_t *t) { return &t->st; }

/* One-shot: tokenise utf8[0..len) (offsets relative to utf8), store the first `cap` words in `out`
 * (out may be NULL with cap 0 to just count), fill *st (may be NULL). Returns the number stored. */
size_t rsvp_tokenize(const char *utf8, size_t len, rsvp_word_t *out, size_t cap, rsvp_stats_t *st);

/* The word that starts at buf[0] (as the tokeniser would emit it when a word starts at that byte),
 * looking at no more than n bytes; `at_end` says buf[n] is the end of the text. Used to re-read a
 * word from its index offset. Returns false if no word starts within buf. out->off is 0-based;
 * RSVP_F_PARA is never set (it depends on what follows; the index stores it). */
bool rsvp_word_at(const char *buf, size_t n, bool at_end, rsvp_word_t *out);

/* The title: the first line of the text (a leading BOM and surrounding whitespace removed),
 * truncated to cap-1 bytes at a code point boundary, NUL-terminated. Returns its length. */
size_t rsvp_title(const char *utf8, size_t len, char *out, size_t cap);

/* ---- Timing and ORP --------------------------------------------------------------------------- */

/* Spritz rule, in glyphs: 0 → 0, 1 → 0, 2–5 → 1, 6–9 → 2, 10–13 → 3, else 4. */
unsigned rsvp_orp_index(unsigned len_glyphs);

/* ORP glyph index within the word: lead + rsvp_orp_index(core) (core 0: rsvp_orp_index(glyphs)),
 * clamped to glyphs-1. */
unsigned rsvp_word_orp(const rsvp_word_t *w);

/* §5c factor in tenths: length factor (10; 13 for >= 8 glyphs; 16 for >= 12) plus 10 at a sentence
 * end, else 5 after a comma/semicolon (or dash). The bonuses add to the factor (×1.6 + 100 % = ×2.6). */
unsigned rsvp_word_factor_x10(const rsvp_word_t *w);

/* On-screen time of the word: round(60000/wpm × factor) ms; wpm is clamped to
 * [RSVP_WPM_MIN, RSVP_WPM_MAX]. */
uint32_t rsvp_word_ms(const rsvp_word_t *w, uint16_t wpm);

/* Blank shown after the word: RSVP_PARA_BLANK_MS at a paragraph break, else 0. */
uint32_t rsvp_blank_ms(const rsvp_word_t *w);

/* Whole-text estimate from the statistics: factor_x10 × 6000/wpm + paragraphs × 300 ms. */
uint64_t rsvp_total_ms(uint64_t factor_x10, uint32_t paragraphs, uint16_t wpm);

/* ---- Font ------------------------------------------------------------------------------------- */

typedef enum {
    RSVP_OK = 0,
    RSVP_ERR_ARG,        /* NULL pointer / bad argument */
    RSVP_ERR_FONT,       /* font document malformed (rsvp_font_parse) */
    RSVP_ERR_ATLAS,      /* atlas missing, not a glyph atlas, wrong cell size or too few frames */
} rsvp_status_t;

typedef struct { uint32_t cp; uint16_t glyph; uint16_t advance; } rsvp_cmap_t;

/* One size of a reader font: glyph i of the atlases is the i-th code point of the document's
 * "glyphs" string. Glyph i is drawn with its pen origin at the cell's left edge and its baseline
 * `baseline` px below the cell top; black atlas pixels are transparent (cells may overlap). */
typedef struct {
    uint16_t cell_w, cell_h, baseline;
    uint16_t count;                       /* glyphs in the document */
    int16_t qmark;                        /* map[] index of '?' (missing-glyph substitute), -1 if absent */
    uint16_t space_adv;                   /* advance of ' ' (font's, else cell_w/4) */
    rsvp_cmap_t map[RSVP_MAX_GLYPHS];     /* sorted by code point */
    char atlas_white[33], atlas_accent[33];
    const hca_asset_t *white, *accent;    /* set by rsvp_font_bind */
} rsvp_face_t;

typedef struct {
    rsvp_face_t normal;
    rsvp_face_t compact;
    bool has_compact;                     /* the document has "compact" */
    bool compact_bound;                   /* ... and its atlases are bound */
    rsvp_face_t large;                    /* §5f.11: the Oracle's text screens only (the Reader ignores it) */
    bool has_large;                       /* the document has "large" */
    bool large_bound;                     /* ... and its atlases are bound (rsvp_font_bind_large) */
} rsvp_font_t;

/* Parse the §5c font document:
 *   {"glyphs":"ABC…","advance":[…],"cell_w":64,"cell_h":120,"baseline":92,
 *    "atlas_white":"id","atlas_accent":"id","compact":{…same keys…},"large":{…same keys…}}
 * Any key order, unknown keys ignored (nesting <= 16), "compact" and "large" (§5f.11) optional (or null). Rules: glyphs is a
 * non-empty valid UTF-8/JSON string of at most RSVP_MAX_GLYPHS code points without duplicates;
 * advance has exactly one integer 0..1024 per glyph; cell_w 1..536, cell_h 1..240, baseline
 * 0..cell_h; atlas ids are asset ids ([a-z0-9][a-z0-9-]{0,31}). On failure *out is unspecified and,
 * if err != NULL, a short reason is written to err. Uses well under 1 KB of stack. */
rsvp_status_t rsvp_font_parse(const char *json, size_t len, rsvp_font_t *out, char *err, size_t err_cap);

/* Attach the atlases (whole .hca files in memory, hca_open'ed). Each must be flagged as a glyph
 * atlas, cell_w × cell_h, with at least `count` frames. compact_* may be NULL (compact unused).
 * RSVP_ERR_ATLAS if a given atlas does not fit; nothing is bound then. */
rsvp_status_t rsvp_font_bind(rsvp_font_t *f, const hca_asset_t *white, const hca_asset_t *accent,
                             const hca_asset_t *compact_white, const hca_asset_t *compact_accent);

/* §5f.11 attach the "large" face's atlases (after rsvp_font_bind; the same rules). RSVP_ERR_ARG when the document
 * has no "large", RSVP_ERR_ATLAS when an atlas does not fit (nothing bound then). */
rsvp_status_t rsvp_font_bind_large(rsvp_font_t *f, const hca_asset_t *white, const hca_asset_t *accent);

/* Atlas frame (glyph index) of code point `cp` in `face`, or -1 (binary search). */
int rsvp_face_lookup(const rsvp_face_t *face, uint32_t cp);

/* Scratch pixels the painter needs (largest bound cell). */
size_t rsvp_font_scratch_px(const rsvp_font_t *f);

/* ---- Layout ----------------------------------------------------------------------------------- */

#define RSVP_GLYPH_NONE 0xFFFFu   /* a space or a glyph missing together with '?': nothing drawn */

typedef struct {
    int16_t x;          /* cell left edge on screen */
    uint16_t glyph;     /* atlas frame or RSVP_GLYPH_NONE */
    uint16_t advance;
    uint8_t accent;     /* 1 for the ORP glyph (drawn from the accent atlas) */
} rsvp_glyph_pos_t;

typedef struct {
    const rsvp_face_t *face;   /* normal or compact */
    uint8_t n;                 /* glyphs placed */
    uint8_t orp;               /* index of the ORP glyph */
    bool compact;              /* the normal size did not fit */
    bool shifted;              /* still too wide with the ORP pinned: moved to fit (ORP off-column) */
    bool clipped;              /* wider than the screen even in the smallest size: edges cut */
    int16_t x0, x1;            /* pixel extent covered by the cells, [x0, x1) */
    int16_t text_x0, text_x1;  /* pen extent (first cell left .. last pen position) */
} rsvp_layout_t;

/* Place word[0..len) so the centre of its ORP glyph (pen x + advance/2) lands on x = orp_x. The
 * normal size is used when the pen extent fits in [margin, screen_w - margin); otherwise compact
 * (if bound); otherwise the smaller size is shifted to fit if it can, else clipped with the ORP
 * pinned. At most `cap` glyphs (and RSVP_WORD_MAX_GLYPHS * 2) are placed. RSVP_ERR_ARG if the font is
 * not bound or the word is empty. */
rsvp_status_t rsvp_layout(const rsvp_font_t *f, const char *word, size_t len, int orp_x, int screen_w,
                          int margin, rsvp_glyph_pos_t *pos, size_t cap, rsvp_layout_t *out);

/* ---- Painter ---------------------------------------------------------------------------------- */

typedef struct { int16_t x, y, w, h; } rsvp_rect_t;    /* w == 0 or h == 0: nothing */

typedef struct {
    int16_t fb_w, fb_h;
    int16_t orp_x;          /* RSVP_ORP_X */
    int16_t margin;         /* horizontal margin for the fit test (8) */
    int16_t baseline_y;     /* common baseline of both sizes */
    int16_t band_y, band_h; /* rows cleared for each word (covers both sizes) */
    int16_t tick_len, tick_gap;
    uint16_t tick_px;       /* RGB565BE (in-memory) colour of the tick marks */
    rsvp_rect_t pause_box;  /* corner box of the pause mark */
    /* state */
    int16_t last_x0, last_x1;   /* columns painted by the previous word ([x0,x1), empty if x1 <= x0) */
    bool full;                  /* next paint clears the whole framebuffer and draws the ticks */
} rsvp_painter_t;

/* Geometry for a fb_w × fb_h screen: both sizes share one baseline, the band is centred vertically,
 * tick marks (2 px wide, RSVP_TICK_COLOR) sit just above and below the band at orp_x-1..orp_x. The
 * first paint is a full one. */
void rsvp_painter_init(rsvp_painter_t *p, const rsvp_font_t *f, int fb_w, int fb_h, int orp_x);

/* Something else painted the framebuffer: the next rsvp_paint repaints everything. */
static inline void rsvp_painter_invalidate(rsvp_painter_t *p) { p->full = true; }

/* Paint word[0..len) (len 0 / NULL: blank band, e.g. the paragraph pause). Clears what the previous
 * word covered (or, after init/invalidate, the whole framebuffer and the tick marks), blits the
 * glyphs (white atlas, ORP glyph from the accent atlas) and writes the changed rectangle to *dirty
 * (band rows × union of old and new columns; the whole framebuffer after init/invalidate).
 * `scratch` holds at least rsvp_font_scratch_px() pixels. `lay` (may be NULL) receives the layout.
 * Glyph frames that fail to decode are skipped (counted in the return value: 0 = all drawn). */
int rsvp_paint(rsvp_painter_t *p, const rsvp_font_t *f, const char *word, size_t len,
               uint16_t *fb, uint16_t *scratch, size_t scratch_px, rsvp_rect_t *dirty, rsvp_layout_t *lay);

/* Draw (on) or clear (off) the pause mark in p->pause_box (top-right corner): the font's U+23F8 "⏸"
 * glyph in the largest size that fits the box, else a 5x7 two-bar mark ×3 in RSVP_PAUSE_COLOR.
 * *dirty = the box. */
void rsvp_paint_pause(const rsvp_painter_t *p, const rsvp_font_t *f, bool on, uint16_t *fb,
                      uint16_t *scratch, size_t scratch_px, rsvp_rect_t *dirty);

/* The end card: "fin" (accent atlas) above "1 234 words · 4 min" (white atlas), each line in the
 * largest size (normal, compact, then 1/2, 1/3, 1/4 subsampled) that fits fb_w minus margins,
 * centred. Clears the framebuffer; *dirty = whole framebuffer; marks the painter for a full repaint.
 * Glyphs missing from the font use '?'. Returns the number of glyphs that had to be substituted. */
int rsvp_paint_end_card(rsvp_painter_t *p, const rsvp_font_t *f, uint32_t words, uint32_t minutes,
                        uint16_t *fb, uint16_t *scratch, size_t scratch_px, rsvp_rect_t *dirty);

/* Text of the end card's second line ("1 234 words · 4 min", "1 word · 1 min"), NUL-terminated
 * UTF-8. Returns the length (0 if cap is too small). */
size_t rsvp_end_card_text(uint32_t words, uint32_t minutes, char *out, size_t cap);

/* Minutes shown on the end card for a reading of total_ms: rounded, at least 1. */
uint32_t rsvp_minutes(uint64_t total_ms);

const char *rsvp_status_str(rsvp_status_t s);

#ifdef __cplusplus
}
#endif
#endif /* RSVP_H */
