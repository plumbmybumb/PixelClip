/* rsvp_tok.c — UTF-8 decoding, word tokeniser, timing and ORP rules (docs/PROTOCOL.md §5c). */
#include <string.h>
#include "rsvp_internal.h"

/* ------------------------------------------------------------------------------------------ */
/* Character classes                                                                          */

int rsvp__class(uint32_t cp) {
    if (cp < 0x80) {
        if (cp == '\n' || cp == '\v' || cp == '\f' || cp == '\r') return RC_NEWLINE;
        if (cp <= 0x20 || cp == 0x7F) return RC_SPACE;
        if ((cp >= '0' && cp <= '9') || ((cp | 0x20u) >= 'a' && (cp | 0x20u) <= 'z')) return RC_LETTER;
        switch (cp) {
        case '.': case '!': case '?': return RC_SENT;
        case ',': case ';': return RC_PAUSE;
        case ')': case ']': case '}': case '"': case '\'': return RC_CLOSE;
        default: return RC_PUNCT;
        }
    }
    if (cp == RSVP_CP_INVALID) return RC_LETTER;
    if (cp < 0xA0) return cp == 0x85 ? RC_NEWLINE : RC_SPACE;            /* C1 controls */
    if (cp == 0xA0) return RC_JOIN;
    if (cp <= 0xBF) {
        switch (cp) {
        case 0xAA: case 0xB2: case 0xB3: case 0xB5: case 0xB9: case 0xBA: case 0xBC: case 0xBD: case 0xBE:
            return RC_LETTER;                                              /* ª ² ³ µ ¹ º ¼ ½ ¾ */
        case 0xBB: return RC_CLOSE;                                        /* » */
        default: return RC_PUNCT;                                          /* ¡ « ¿ · § © … */
        }
    }
    if (cp == 0xD7 || cp == 0xF7) return RC_PUNCT;                         /* × ÷ */
    if (cp < 0x1680) return RC_LETTER;
    if (cp == 0x1680) return RC_SPACE;
    if (cp >= 0x2000 && cp <= 0x206F) {
        if (cp == 0x2007 || cp == 0x202F) return RC_JOIN;
        if (cp <= 0x200B || cp == 0x205F) return RC_SPACE;
        if (cp == 0x2028) return RC_NEWLINE;
        if (cp == 0x2029) return RC_PARASEP;
        if (cp >= 0x2013 && cp <= 0x2015) return RC_DASH;
        if (cp == 0x2019 || cp == 0x201D || cp == 0x203A) return RC_CLOSE;  /* ’ ” › */
        if (cp == 0x2026 || cp == 0x203C || (cp >= 0x2047 && cp <= 0x2049)) return RC_SENT;  /* … ‼ ⁇ ⁈ ⁉ */
        if (cp >= 0x2060) return RC_SPACE;                                 /* invisible operators */
        return RC_PUNCT;
    }
    if (cp >= 0x2E00 && cp <= 0x2E7F) return RC_PUNCT;
    if (cp >= 0x3000 && cp <= 0x303F) {
        if (cp == 0x3000) return RC_SPACE;
        if (cp == 0x3001) return RC_PAUSE;
        if (cp == 0x3002) return RC_SENT;
        if (cp >= 0x3008 && cp <= 0x3011 && (cp & 1u)) return RC_CLOSE;
        return RC_PUNCT;
    }
    if (cp == 0xFEFF) return RC_SPACE;
    if (cp >= 0xFF01 && cp <= 0xFF65) {
        switch (cp) {
        case 0xFF01: case 0xFF0E: case 0xFF1F: return RC_SENT;
        case 0xFF0C: case 0xFF1B: return RC_PAUSE;
        case 0xFF09: case 0xFF3D: case 0xFF5D: return RC_CLOSE;
        default: break;
        }
        if ((cp >= 0xFF10 && cp <= 0xFF19) || (cp >= 0xFF21 && cp <= 0xFF3A) || (cp >= 0xFF41 && cp <= 0xFF5A)) return RC_LETTER;
        return RC_PUNCT;
    }
    return RC_LETTER;
}

/* ------------------------------------------------------------------------------------------ */
/* UTF-8                                                                                      */

int rsvp__u8_step(rsvp_u8_t *d, uint8_t b, uint32_t pos, rsvp_gev_t ev[2]) {
    int k = 0;
    if (d->need) {
        if ((b & 0xC0u) == 0x80u) {
            d->cp = (d->cp << 6) | (b & 0x3Fu);
            d->len++;
            if (--d->need == 0) {
                bool ok = d->cp >= d->min && d->cp <= 0x10FFFFu && !(d->cp >= 0xD800u && d->cp <= 0xDFFFu);
                ev[k].cp = ok ? d->cp : RSVP_CP_INVALID;
                ev[k].start = d->start;
                ev[k].len = d->len;
                k++;
            }
            return k;
        }
        /* broken sequence: what was read so far is one invalid glyph, then `b` starts afresh */
        ev[k].cp = RSVP_CP_INVALID;
        ev[k].start = d->start;
        ev[k].len = d->len;
        k++;
        d->need = 0;
    }
    if (b < 0x80u) {
        ev[k].cp = b; ev[k].start = pos; ev[k].len = 1; k++;
    } else if (b >= 0xC2u && b <= 0xDFu) {
        d->need = 1; d->cp = b & 0x1Fu; d->min = 0x80u; d->start = pos; d->len = 1;
    } else if (b >= 0xE0u && b <= 0xEFu) {
        d->need = 2; d->cp = b & 0x0Fu; d->min = 0x800u; d->start = pos; d->len = 1;
    } else if (b >= 0xF0u && b <= 0xF4u) {
        d->need = 3; d->cp = b & 0x07u; d->min = 0x10000u; d->start = pos; d->len = 1;
    } else {
        ev[k].cp = RSVP_CP_INVALID; ev[k].start = pos; ev[k].len = 1; k++;
    }
    return k;
}

int rsvp__u8_finish(rsvp_u8_t *d, rsvp_gev_t *ev) {
    if (!d->need) return 0;
    ev->cp = RSVP_CP_INVALID;
    ev->start = d->start;
    ev->len = d->len;
    d->need = 0;
    return 1;
}

size_t rsvp_utf8_next(const char *s, size_t n, uint32_t *cp) {
    if (!s || n == 0) {
        if (cp) *cp = RSVP_CP_INVALID;
        return 0;
    }
    rsvp_u8_t d = { 0 };
    rsvp_gev_t ev[2];
    for (size_t i = 0; i < n && i < 4; i++) {
        if (rsvp__u8_step(&d, (uint8_t)s[i], (uint32_t)i, ev) > 0) {
            if (cp) *cp = ev[0].cp;
            return ev[0].len;
        }
    }
    rsvp__u8_finish(&d, ev);
    if (cp) *cp = ev[0].cp;
    return ev[0].len;
}

/* ------------------------------------------------------------------------------------------ */
/* Tokeniser                                                                                  */

void rsvp_tok_init(rsvp_tok_t *t, uint32_t base_off, unsigned opts) {
    if (!t) return;
    memset(t, 0, sizeof *t);
    t->pos = base_off;
    t->opts = opts;
}

static void end_word(rsvp_tok_t *t) {
    rsvp_word_t w;
    memset(&w, 0, sizeof w);
    w.off = t->w_off;
    w.len = (uint16_t)(t->w_end - t->w_off);
    w.glyphs = t->w_glyphs;
    if (t->w_has_letter) {
        w.lead = t->w_first;
        w.core = (uint8_t)(t->w_last - t->w_first + 1);
    }
    if (t->w_term == RC_SENT) w.flags = RSVP_F_SENTENCE;
    else if (t->w_term == RC_PAUSE || t->w_term == RC_DASH) w.flags = RSVP_F_COMMA;
    t->pending = w;
    t->has_pending = true;
    t->in_word = false;
    t->nl = 0;
}

static void emit(rsvp_tok_t *t, rsvp_word_t *out, size_t *n) {
    rsvp_word_t *w = &t->pending;
    t->has_pending = false;
    t->st.words++;
    if (w->flags & RSVP_F_SENTENCE) t->st.sentences++;
    if (w->flags & RSVP_F_PARA) t->st.paragraphs++;
    t->st.factor_x10 += rsvp_word_factor_x10(w);
    if (w->glyphs > t->st.max_glyphs) t->st.max_glyphs = w->glyphs;
    out[(*n)++] = *w;
}

static void count_newline(rsvp_tok_t *t, unsigned n) {
    if ((t->opts & RSVP_TOK_TITLE_BREAK) && !t->seen_nl) n += 1;   /* end of the title line */
    t->seen_nl = true;
    unsigned v = t->nl + n;
    t->nl = (uint8_t)(v > 200 ? 200 : v);
}

static void on_glyph(rsvp_tok_t *t, const rsvp_gev_t *ev, rsvp_word_t *out, size_t *n) {
    if (ev->cp == RSVP_CP_INVALID) t->st.invalid++;
    int cls = rsvp__class(ev->cp);
    if (cls == RC_SPACE || cls == RC_NEWLINE || cls == RC_PARASEP) {
        if (t->in_word) end_word(t);
        if (cls == RC_NEWLINE) {
            bool crlf = ev->cp == '\n' && t->prev_cr;
            t->prev_cr = ev->cp == '\r';
            if (!crlf) count_newline(t, 1);
        } else {
            t->prev_cr = false;
            if (cls == RC_PARASEP) count_newline(t, 2);
        }
        return;
    }
    t->prev_cr = false;
    if (t->in_word && t->w_glyphs >= RSVP_WORD_MAX_GLYPHS) end_word(t);
    if (!t->in_word) {
        if (t->has_pending) {
            if (t->nl >= 2) t->pending.flags |= RSVP_F_PARA;
            emit(t, out, n);
        }
        t->in_word = true;
        t->w_off = ev->start;
        t->w_glyphs = 0;
        t->w_has_letter = false;
        t->w_first = t->w_last = 0;
        t->w_term = RC_LETTER;
        t->nl = 0;
    }
    uint8_t idx = t->w_glyphs++;
    t->w_end = ev->start + ev->len;
    if (cls == RC_LETTER) {
        if (!t->w_has_letter) {
            t->w_has_letter = true;
            t->w_first = idx;
        }
        t->w_last = idx;
    }
    if (cls != RC_CLOSE && cls != RC_JOIN) t->w_term = (uint8_t)cls;   /* "!\u00a0»" ends a sentence */
    if (cls == RC_DASH) end_word(t);
}

size_t rsvp_tok_feed(rsvp_tok_t *t, const char *buf, size_t len, size_t *consumed,
                     rsvp_word_t *out, size_t cap) {
    size_t n = 0, i = 0;
    if (!t || (!buf && len) || !out) {
        if (consumed) *consumed = 0;
        return 0;
    }
    rsvp_u8_t d = { t->u_cp, t->u_min, t->u_start, t->u_need, t->u_len };
    for (; i < len; i++) {
        if (cap - n < 2) break;
        uint8_t b = (uint8_t)buf[i];
        rsvp_gev_t ev[2];
        int k = rsvp__u8_step(&d, b, t->pos, ev);
        t->pos++;
        t->st.bytes++;
        if (b == 0) t->st.nul++;
        for (int j = 0; j < k; j++) on_glyph(t, &ev[j], out, &n);
    }
    t->u_cp = d.cp; t->u_min = d.min; t->u_start = d.start; t->u_need = d.need; t->u_len = d.len;
    if (consumed) *consumed = i;
    return n;
}

size_t rsvp_tok_finish(rsvp_tok_t *t, rsvp_word_t *out, size_t cap) {
    size_t n = 0;
    if (!t || !out || cap < 2) return 0;
    rsvp_u8_t d = { t->u_cp, t->u_min, t->u_start, t->u_need, t->u_len };
    rsvp_gev_t ev;
    if (rsvp__u8_finish(&d, &ev)) on_glyph(t, &ev, out, &n);
    t->u_need = 0;
    if (t->in_word) end_word(t);
    if (t->has_pending) emit(t, out, &n);
    return n;
}

size_t rsvp_tokenize(const char *utf8, size_t len, rsvp_word_t *out, size_t cap, rsvp_stats_t *st) {
    rsvp_tok_t t;
    rsvp_word_t tmp[64];
    size_t stored = 0, pos = 0;
    rsvp_tok_init(&t, 0, 0);
    if (!out) cap = 0;
    if (utf8 || len == 0) {
        while (pos < len) {
            size_t used = 0;
            size_t k = rsvp_tok_feed(&t, utf8 + pos, len - pos, &used, tmp, 64);
            for (size_t i = 0; i < k; i++) if (stored < cap) out[stored++] = tmp[i];
            pos += used;
        }
        size_t k = rsvp_tok_finish(&t, tmp, 64);
        for (size_t i = 0; i < k; i++) if (stored < cap) out[stored++] = tmp[i];
    }
    if (st) *st = t.st;
    return stored;
}

bool rsvp_word_at(const char *buf, size_t n, bool at_end, rsvp_word_t *out) {
    if (!buf || !out) return false;
    rsvp_tok_t t;
    rsvp_word_t tmp[2];
    rsvp_tok_init(&t, 0, 0);
    rsvp_u8_t d = { 0 };
    for (size_t i = 0; i < n; i++) {
        rsvp_gev_t ev[2];
        size_t m = 0;
        int k = rsvp__u8_step(&d, (uint8_t)buf[i], (uint32_t)i, ev);
        for (int j = 0; j < k; j++) {
            on_glyph(&t, &ev[j], tmp, &m);
            if (m) {               /* cannot happen before a first word ended, but be safe */
                *out = tmp[0];
                out->flags &= (uint8_t)~RSVP_F_PARA;
                return true;
            }
            if (t.has_pending) {
                *out = t.pending;
                out->flags &= (uint8_t)~RSVP_F_PARA;
                return true;
            }
        }
    }
    rsvp_gev_t ev;
    size_t m = 0;
    if (at_end && rsvp__u8_finish(&d, &ev)) on_glyph(&t, &ev, tmp, &m);
    if (t.has_pending) {
        *out = t.pending;
    } else if (t.in_word) {
        end_word(&t);              /* buffer ended inside the word (short read): best effort */
        *out = t.pending;
    } else {
        return false;
    }
    out->flags &= (uint8_t)~RSVP_F_PARA;
    return true;
}

size_t rsvp_title(const char *utf8, size_t len, char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    out[0] = '\0';
    if (!utf8) return 0;
    size_t i = 0;
    if (len >= 3 && (uint8_t)utf8[0] == 0xEF && (uint8_t)utf8[1] == 0xBB && (uint8_t)utf8[2] == 0xBF) i = 3;
    size_t end = i;
    while (end < len && utf8[end] != '\n' && utf8[end] != '\r') end++;
    size_t o = 0, last_ink = 0;
    bool started = false;
    while (i < end) {
        uint32_t cp;
        size_t k = rsvp_utf8_next(utf8 + i, end - i, &cp);
        int cls = rsvp__class(cp);
        bool space = cls == RC_SPACE || cls == RC_JOIN || cls == RC_NEWLINE || cls == RC_PARASEP;
        if (!started && space) { i += k; continue; }
        started = true;
        const char *src = utf8 + i;
        size_t sl = k;
        if (cp == RSVP_CP_INVALID) { src = "?"; sl = 1; }
        else if (cp < 0x20 || cp == 0x7F) { src = " "; sl = 1; space = true; }
        if (o + sl + 1 > cap) break;
        memcpy(out + o, src, sl);
        o += sl;
        if (!space) last_ink = o;
        i += k;
    }
    out[last_ink] = '\0';
    return last_ink;
}

/* ------------------------------------------------------------------------------------------ */
/* Timing and ORP                                                                             */

unsigned rsvp_orp_index(unsigned len) {
    if (len <= 1) return 0;
    if (len <= 5) return 1;
    if (len <= 9) return 2;
    if (len <= 13) return 3;
    return 4;
}

unsigned rsvp_word_orp(const rsvp_word_t *w) {
    if (!w || w->glyphs == 0) return 0;
    unsigned i = w->core ? w->lead + rsvp_orp_index(w->core) : rsvp_orp_index(w->glyphs);
    return i < w->glyphs ? i : (unsigned)w->glyphs - 1u;
}

unsigned rsvp_word_factor_x10(const rsvp_word_t *w) {
    if (!w) return 10;
    unsigned len = w->core ? w->core : w->glyphs;
    unsigned f = len >= 12 ? 16 : len >= 8 ? 13 : 10;
    if (w->flags & RSVP_F_SENTENCE) f += 10;
    else if (w->flags & RSVP_F_COMMA) f += 5;
    return f;
}

static uint32_t clamp_wpm(uint16_t wpm) {
    return wpm < RSVP_WPM_MIN ? RSVP_WPM_MIN : wpm > RSVP_WPM_MAX ? RSVP_WPM_MAX : wpm;
}

uint32_t rsvp_word_ms(const rsvp_word_t *w, uint16_t wpm) {
    uint32_t v = clamp_wpm(wpm);
    return (60000u * rsvp_word_factor_x10(w) + v * 5u) / (v * 10u);
}

uint32_t rsvp_blank_ms(const rsvp_word_t *w) {
    return (w && (w->flags & RSVP_F_PARA)) ? RSVP_PARA_BLANK_MS : 0;
}

uint64_t rsvp_total_ms(uint64_t factor_x10, uint32_t paragraphs, uint16_t wpm) {
    uint64_t v = clamp_wpm(wpm);
    return (factor_x10 * 6000u + v / 2u) / v + (uint64_t)paragraphs * RSVP_PARA_BLANK_MS;
}

uint32_t rsvp_minutes(uint64_t total_ms) {
    uint64_t m = (total_ms + 30000u) / 60000u;
    if (m < 1) m = 1;
    return m > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)m;
}

const char *rsvp_status_str(rsvp_status_t s) {
    switch (s) {
    case RSVP_OK: return "ok";
    case RSVP_ERR_ARG: return "bad argument";
    case RSVP_ERR_FONT: return "malformed font document";
    case RSVP_ERR_ATLAS: return "atlas does not match the font";
    default: return "?";
    }
}
