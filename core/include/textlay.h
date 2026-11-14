/* textlay.h — text layout: UTF-8 text word-wrapped with a reader font (§5c atlas pair, rsvp.h) into centred lines.
 *
 * C11, no allocation, no I/O. The caller owns the textlay_layout_t (~13 KB); nothing is allocated. The Oracle's text
 * screens (oracle_text.h) wrap every text with it.
 *
 * Scroll style (textlay_layout_style(..., TEXTLAY_STYLE_SCROLL, ...), the only style): the whole text (at most
 * TEXTLAY_LAYOUT_TEXT_MAX = 900 bytes are used, PROTOCOL §5f.1) wrapped at the normal face (the compact face is never
 * used) into at most TEXTLAY_SCROLL_MAX_LINES lines (beyond: the last line is cut so that it ends with "…", at a word
 * boundary when that keeps >= 60 % of the line). It is one page (page[0]) whose block is a window of
 * W = min(TEXTLAY_MAX_LINES, screen_h / cell_h) lines (at least 1), centred vertically:
 * block_y = (screen_h - W * cell_h) / 2 whatever the text's length; line i's top is block_y + i * cell_h (lines past
 * the window continue below it).
 *
 * Wrapping rules (normative, see core/README.md "Text layout"):
 *  - Words are separated by whitespace (runs collapse; leading/trailing whitespace is dropped). A line
 *    feed in the text is a hard line break. No-break spaces (U+00A0, U+202F, U+2007) join and are drawn
 *    as a space.
 *  - French punctuation stays with its word: a space before ! ? : ; » ” … and after « “ never breaks.
 *  - A word wider than the line is broken after a hyphen/dash/slash if possible, else between glyphs.
 *  - The space at a line break is not drawn.
 *  - Lines are centred on their pen extent (x0 = floor((screen_w - width) / 2)).
 */
#ifndef TEXTLAY_H
#define TEXTLAY_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "rsvp.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Constants --------------------------------------------------------------------------------- */

#define TEXTLAY_LAYOUT_TEXT_MAX 900     /* bytes textlay_layout_style lays out (the Oracle's paragraph, §5f.1) */
#define TEXTLAY_MAX_LINES       3       /* lines of the window at most */
#define TEXTLAY_MAX_GLYPHS      (TEXTLAY_LAYOUT_TEXT_MAX + 3)   /* + "..." */
#define TEXTLAY_SCROLL_MAX_LINES 64     /* lines of a text (beyond: the 64th ends with "…") */
#define TEXTLAY_BAR_DIM_COLOR   0x520Du /* native RGB565 of the brand "dim" #52416B */
#define TEXTLAY_CURSOR_COLOR    0xC51Fu /* native RGB565 of the brand accent #C6A2FF */

typedef enum {
    TEXTLAY_STYLE_SCROLL = 0,   /* one wrapped column behind a window of <= 3 lines */
} textlay_style_t;

typedef enum {
    TEXTLAY_OK = 0,
    TEXTLAY_ERR_ARG,        /* NULL pointer / bad argument / font not bound */
} textlay_status_t;

/* ---- Layout ------------------------------------------------------------------------------------ */

typedef struct {
    int16_t x;          /* cell left edge on screen (pen position) */
    uint16_t glyph;     /* atlas frame, or RSVP_GLYPH_NONE (space / missing with no '?') */
    uint16_t advance;
    uint8_t line;       /* index into textlay_layout_t.line */
} textlay_glyph_t;

typedef struct {
    int16_t x0, x1;     /* pen extent [x0, x1): x0 = floor((screen_w - width) / 2) */
    int16_t top;        /* cell top of the line */
    uint16_t first;     /* index of its first glyph in textlay_layout_t.g */
    uint16_t count;
} textlay_line_t;

typedef struct {
    uint8_t first_line, lines;
    uint16_t first;      /* first glyph */
    uint16_t n;          /* glyphs on the page */
    int16_t block_y, block_h;   /* the window: block_h = W * pitch, block_y = (screen_h - block_h) / 2 */
} textlay_page_t;

typedef struct {
    const rsvp_face_t *face;   /* the normal face */
    uint8_t style;             /* textlay_style_t */
    uint8_t window;            /* W, lines the window can show (>= 1) */
    bool truncated;            /* more than TEXTLAY_SCROLL_MAX_LINES lines: the last line ends with "…" */
    uint8_t pages;             /* 0 for an empty / blank text, else 1 (page[0] = the whole text, block = window) */
    uint8_t lines;
    int16_t pitch;             /* line pitch = face->cell_h */
    int16_t screen_w, screen_h;
    uint16_t n;                /* glyphs placed, line by line */
    int missing;               /* code points drawn with '?' (or nothing) */
    textlay_page_t page[1];
    textlay_line_t line[TEXTLAY_SCROLL_MAX_LINES];   /* top = position with the window not scrolled */
    textlay_glyph_t g[TEXTLAY_MAX_GLYPHS];
    struct {                   /* private work area of textlay_layout_style (keeps it off the stack) */
        uint32_t cpk[TEXTLAY_LAYOUT_TEXT_MAX];
        uint16_t adv[TEXTLAY_LAYOUT_TEXT_MAX];
    } work;
} textlay_layout_t;            /* ~13 KB */

/* Lay out text[0..len) (UTF-8; invalid bytes are drawn as '?'; at most TEXTLAY_LAYOUT_TEXT_MAX bytes are used) on a
 * screen_w x screen_h screen with `margin` px left and right, in `style`. TEXTLAY_ERR_ARG if the font's normal face is
 * not bound or the arguments are bad. An empty / blank text gives pages = lines = n = 0. */
textlay_status_t textlay_layout_style(const rsvp_font_t *f, const char *text, size_t len, int screen_w, int screen_h,
                                      int margin, textlay_style_t style, textlay_layout_t *out);

#ifdef __cplusplus
}
#endif
#endif /* TEXTLAY_H */
