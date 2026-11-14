/* rsvp_internal.h — private helpers shared by rsvp_tok.c, rsvp_font.c and rsvp_paint.c. */
#ifndef RSVP_INTERNAL_H
#define RSVP_INTERNAL_H
#include "rsvp.h"

/* Code point classes used by the tokeniser and the layout (they must agree). */
enum {
    RC_LETTER = 0,   /* letters, digits, symbols: the word's core */
    RC_PUNCT,        /* other punctuation (leading/trailing, not core) */
    RC_SENT,         /* . ! ? … and full-width forms: sentence end */
    RC_PAUSE,        /* , ; and full-width forms: comma pause */
    RC_CLOSE,        /* closing quotes/brackets: ignored when looking for the terminal mark */
    RC_DASH,         /* en/em dash, horizontal bar: ends the word */
    RC_JOIN,         /* no-break spaces: part of the word, drawn as a space */
    RC_SPACE,        /* separator */
    RC_NEWLINE,      /* separator + line break */
    RC_PARASEP,      /* U+2029: separator + paragraph break */
};

int rsvp__class(uint32_t cp);

/* Byte-wise UTF-8 decoder shared by the tokeniser and rsvp_utf8_next. */
typedef struct { uint32_t cp, min, start; uint8_t need, len; } rsvp_u8_t;
typedef struct { uint32_t cp, start; uint8_t len; } rsvp_gev_t;

/* Feed byte `b` at absolute offset `pos`. Writes 0..2 glyph events to ev and returns the count. */
int rsvp__u8_step(rsvp_u8_t *d, uint8_t b, uint32_t pos, rsvp_gev_t ev[2]);
/* End of input: a partial sequence becomes an invalid glyph. Returns 0 or 1. */
int rsvp__u8_finish(rsvp_u8_t *d, rsvp_gev_t *ev);

/* Index into face->map of code point `cp`, or -1 (binary search). */
int rsvp__face_find(const rsvp_face_t *f, uint32_t cp);

/* Native RGB565 -> in-memory RGB565BE. */
static inline uint16_t rsvp__be(uint16_t v) {
    union { uint8_t b[2]; uint16_t v; } u;
    u.b[0] = (uint8_t)(v >> 8);
    u.b[1] = (uint8_t)v;
    return u.v;
}

#endif /* RSVP_INTERNAL_H */
