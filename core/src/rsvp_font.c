/* rsvp_font.c — reader font document parser (PROTOCOL §5c "Fonts") and atlas binding. */
#include <string.h>
#include <stdio.h>
#include "rsvp_internal.h"

#define JSON_MAX_DEPTH 16

typedef struct {
    const char *p, *e;
    char *err;
    size_t err_cap;
} jcur_t;

static bool fail(jcur_t *c, const char *msg) {
    if (c->err && c->err_cap && !c->err[0]) snprintf(c->err, c->err_cap, "%s", msg);
    return false;
}

static void jws(jcur_t *c) {
    while (c->p < c->e && (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r')) c->p++;
}
static bool jpeek(jcur_t *c, char ch) { jws(c); return c->p < c->e && *c->p == ch; }
static bool jeat(jcur_t *c, char ch) {
    if (!jpeek(c, ch)) return false;
    c->p++;
    return true;
}
static bool jword(jcur_t *c, const char *w) {
    size_t n = strlen(w);
    jws(c);
    if ((size_t)(c->e - c->p) < n || memcmp(c->p, w, n) != 0) return false;
    c->p += n;
    return true;
}
static int hexval(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}
static bool jhex4(jcur_t *c, unsigned *v) {
    if (c->e - c->p < 4) return false;
    unsigned r = 0;
    for (int i = 0; i < 4; i++) {
        int h = hexval(c->p[i]);
        if (h < 0) return false;
        r = (r << 4) | (unsigned)h;
    }
    c->p += 4;
    *v = r;
    return true;
}

/* Walk a JSON string, calling sink(ctx, cp) for every code point (escapes resolved, raw bytes decoded
 * as UTF-8; invalid UTF-8 or a lone surrogate fails). sink may be NULL (skip). */
typedef bool (*cp_sink_t)(void *ctx, uint32_t cp);

static bool jstring_cps(jcur_t *c, cp_sink_t sink, void *ctx) {
    if (!jeat(c, '"')) return false;
    rsvp_u8_t d = { 0 };
    for (;;) {
        if (c->p >= c->e) return false;
        uint8_t ch = (uint8_t)*c->p;
        if (d.need == 0 && ch == '"') { c->p++; break; }
        if (d.need == 0 && ch == '\\') {
            c->p++;
            if (c->p >= c->e) return false;
            char esc = *c->p++;
            uint32_t cp;
            switch (esc) {
            case '"': case '\\': case '/': cp = (uint8_t)esc; break;
            case 'b': cp = '\b'; break;
            case 'f': cp = '\f'; break;
            case 'n': cp = '\n'; break;
            case 'r': cp = '\r'; break;
            case 't': cp = '\t'; break;
            case 'u': {
                unsigned v;
                if (!jhex4(c, &v)) return false;
                if (v >= 0xD800 && v <= 0xDBFF) {
                    unsigned lo;
                    if (c->e - c->p < 6 || c->p[0] != '\\' || c->p[1] != 'u') return false;
                    c->p += 2;
                    if (!jhex4(c, &lo) || lo < 0xDC00 || lo > 0xDFFF) return false;
                    cp = 0x10000u + ((v - 0xD800u) << 10) + (lo - 0xDC00u);
                } else if (v >= 0xDC00 && v <= 0xDFFF) {
                    return false;
                } else {
                    cp = v;
                }
                break;
            }
            default: return false;
            }
            if (sink && !sink(ctx, cp)) return false;
            continue;
        }
        if (ch < 0x20) return false;
        c->p++;
        rsvp_gev_t ev[2];
        int k = rsvp__u8_step(&d, ch, 0, ev);
        for (int i = 0; i < k; i++) {
            if (ev[i].cp == RSVP_CP_INVALID) return false;
            if (sink && !sink(ctx, ev[i].cp)) return false;
        }
    }
    return d.need == 0;
}

typedef struct { char *buf; size_t cap, n; bool overflow; } str_sink_t;

static bool sink_str(void *ctx, uint32_t cp) {
    str_sink_t *s = ctx;
    char tmp[4];
    size_t k;
    if (cp < 0x80) { tmp[0] = (char)cp; k = 1; }
    else if (cp < 0x800) { tmp[0] = (char)(0xC0 | (cp >> 6)); tmp[1] = (char)(0x80 | (cp & 0x3F)); k = 2; }
    else if (cp < 0x10000) {
        tmp[0] = (char)(0xE0 | (cp >> 12)); tmp[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); tmp[2] = (char)(0x80 | (cp & 0x3F)); k = 3;
    } else {
        tmp[0] = (char)(0xF0 | (cp >> 18)); tmp[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        tmp[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); tmp[3] = (char)(0x80 | (cp & 0x3F)); k = 4;
    }
    if (s->n + k + 1 > s->cap) { s->overflow = true; return true; }
    memcpy(s->buf + s->n, tmp, k);
    s->n += k;
    s->buf[s->n] = '\0';
    return true;
}

static bool jnumber(jcur_t *c, int64_t *v, bool *is_int) {
    jws(c);
    const char *p = c->p, *e = c->e;
    bool neg = false, ok = true;
    int64_t acc = 0;
    int digits = 0;
    if (p < e && *p == '-') { neg = true; p++; }
    if (p >= e || *p < '0' || *p > '9') return false;
    while (p < e && *p >= '0' && *p <= '9') {
        if (digits < 18) acc = acc * 10 + (*p - '0');
        else ok = false;
        digits++;
        p++;
    }
    if (p < e && *p == '.') {
        p++;
        if (p >= e || *p < '0' || *p > '9') return false;
        while (p < e && *p >= '0' && *p <= '9') { if (*p != '0') ok = false; p++; }
    }
    if (p < e && (*p == 'e' || *p == 'E')) {
        p++;
        if (p < e && (*p == '+' || *p == '-')) p++;
        if (p >= e || *p < '0' || *p > '9') return false;
        while (p < e && *p >= '0' && *p <= '9') p++;
        ok = false;
    }
    c->p = p;
    if (v) *v = neg ? -acc : acc;
    if (is_int) *is_int = ok;
    return true;
}

static bool jint(jcur_t *c, int64_t lo, int64_t hi, int64_t *v) {
    bool is_int;
    return jnumber(c, v, &is_int) && is_int && *v >= lo && *v <= hi;
}

static bool jskip(jcur_t *c, int depth) {
    if (depth > JSON_MAX_DEPTH) return false;
    jws(c);
    if (c->p >= c->e) return false;
    switch (*c->p) {
    case '"': return jstring_cps(c, NULL, NULL);
    case 't': return jword(c, "true");
    case 'f': return jword(c, "false");
    case 'n': return jword(c, "null");
    case '{':
        c->p++;
        if (jeat(c, '}')) return true;
        for (;;) {
            if (!jstring_cps(c, NULL, NULL) || !jeat(c, ':') || !jskip(c, depth + 1)) return false;
            if (jeat(c, ',')) continue;
            return jeat(c, '}');
        }
    case '[':
        c->p++;
        if (jeat(c, ']')) return true;
        for (;;) {
            if (!jskip(c, depth + 1)) return false;
            if (jeat(c, ',')) continue;
            return jeat(c, ']');
        }
    default:
        return jnumber(c, NULL, NULL);
    }
}

static bool jkey(jcur_t *c, char *key, size_t cap) {
    str_sink_t s = { key, cap, 0, false };
    key[0] = '\0';
    if (!jstring_cps(c, sink_str, &s)) return false;
    if (s.overflow) key[0] = '\0';    /* too long to be one of ours: unknown */
    return jeat(c, ':');
}

static bool valid_id(const char *s) {
    size_t n = strlen(s);
    if (n < 1 || n > 32) return false;
    for (size_t i = 0; i < n; i++) {
        char ch = s[i];
        bool ok = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || (ch == '-' && i > 0);
        if (!ok) return false;
    }
    return true;
}

static bool jid(jcur_t *c, char out[33]) {
    str_sink_t s = { out, 33, 0, false };
    out[0] = '\0';
    return jstring_cps(c, sink_str, &s) && !s.overflow && valid_id(out);
}

/* ---- face parsing ---------------------------------------------------------------------------- */

typedef struct {
    rsvp_face_t *f;
    bool overflow;
} glyph_sink_t;

static bool sink_glyph(void *ctx, uint32_t cp) {
    glyph_sink_t *g = ctx;
    if (g->f->count >= RSVP_MAX_GLYPHS) { g->overflow = true; return true; }
    rsvp_cmap_t *m = &g->f->map[g->f->count];
    m->cp = cp;
    m->glyph = g->f->count;
    g->f->count++;
    return true;
}

enum { HAS_GLYPHS = 1, HAS_ADV = 2, HAS_W = 4, HAS_H = 8, HAS_BASE = 16, HAS_WHITE = 32, HAS_ACCENT = 64,
       HAS_ALL = 127 };

static bool parse_face(jcur_t *c, rsvp_face_t *f, rsvp_font_t *font, bool top, int depth) {
    unsigned have = 0;
    size_t nadv = 0;
    char key[16];
    memset(f, 0, sizeof *f);
    if (!jeat(c, '{')) return fail(c, "font document must be an object");
    if (!jeat(c, '}')) {
        for (;;) {
            if (!jkey(c, key, sizeof key)) return fail(c, "bad JSON");
            int64_t v;
            if (!strcmp(key, "glyphs")) {
                glyph_sink_t g = { f, false };
                f->count = 0;
                if (!jstring_cps(c, sink_glyph, &g)) return fail(c, "glyphs must be a valid UTF-8 string");
                if (g.overflow) return fail(c, "more than 256 glyphs");
                if (f->count == 0) return fail(c, "glyphs is empty");
                have |= HAS_GLYPHS;
            } else if (!strcmp(key, "advance")) {
                if (!jeat(c, '[')) return fail(c, "advance must be an array");
                nadv = 0;
                if (!jeat(c, ']')) {
                    for (;;) {
                        if (!jint(c, 0, 1024, &v)) return fail(c, "advance values must be integers 0..1024");
                        if (nadv >= RSVP_MAX_GLYPHS) return fail(c, "more than 256 advances");
                        f->map[nadv++].advance = (uint16_t)v;   /* positional: map is sorted later */
                        if (jeat(c, ',')) continue;
                        if (jeat(c, ']')) break;
                        return fail(c, "bad JSON");
                    }
                }
                have |= HAS_ADV;
            } else if (!strcmp(key, "cell_w")) {
                if (!jint(c, 1, 536, &v)) return fail(c, "cell_w must be 1..536");
                f->cell_w = (uint16_t)v;
                have |= HAS_W;
            } else if (!strcmp(key, "cell_h")) {
                if (!jint(c, 1, 240, &v)) return fail(c, "cell_h must be 1..240");
                f->cell_h = (uint16_t)v;
                have |= HAS_H;
            } else if (!strcmp(key, "baseline")) {
                if (!jint(c, 0, 240, &v)) return fail(c, "baseline must be 0..cell_h");
                f->baseline = (uint16_t)v;
                have |= HAS_BASE;
            } else if (!strcmp(key, "atlas_white")) {
                if (!jid(c, f->atlas_white)) return fail(c, "atlas_white must be an asset id");
                have |= HAS_WHITE;
            } else if (!strcmp(key, "atlas_accent")) {
                if (!jid(c, f->atlas_accent)) return fail(c, "atlas_accent must be an asset id");
                have |= HAS_ACCENT;
            } else if (top && !strcmp(key, "compact")) {
                if (jword(c, "null")) {
                    font->has_compact = false;
                } else {
                    if (!jpeek(c, '{')) return fail(c, "compact must be an object");
                    if (!parse_face(c, &font->compact, font, false, depth + 1)) return false;
                    font->has_compact = true;
                }
            } else if (top && !strcmp(key, "large")) {
                if (jword(c, "null")) {
                    font->has_large = false;
                } else {
                    if (!jpeek(c, '{')) return fail(c, "large must be an object");
                    if (!parse_face(c, &font->large, font, false, depth + 1)) return false;
                    font->has_large = true;
                }
            } else if (!jskip(c, depth + 1)) {
                return fail(c, "bad JSON");
            }
            if (jeat(c, ',')) continue;
            if (jeat(c, '}')) break;
            return fail(c, "bad JSON");
        }
    }
    if ((have & HAS_ALL) != HAS_ALL) {
        static const char *names[] = { "glyphs", "advance", "cell_w", "cell_h", "baseline", "atlas_white", "atlas_accent" };
        for (int i = 0; i < 7; i++) {
            if (!(have & (1u << i))) {
                char msg[48];
                snprintf(msg, sizeof msg, "%smissing \"%s\"", top ? "" : f == &font->large ? "large: " : "compact: ",
                         names[i]);
                return fail(c, msg);
            }
        }
    }
    if (f->baseline > f->cell_h) return fail(c, "baseline must be 0..cell_h");
    if (nadv != f->count) return fail(c, "advance must have one entry per glyph");
    /* sort by code point (insertion sort, <= 256 entries) and reject duplicates */
    for (uint16_t i = 1; i < f->count; i++) {
        rsvp_cmap_t m = f->map[i];
        int j = (int)i - 1;
        while (j >= 0 && f->map[j].cp > m.cp) {
            f->map[j + 1] = f->map[j];
            j--;
        }
        f->map[j + 1] = m;
    }
    for (uint16_t i = 1; i < f->count; i++) {
        if (f->map[i].cp == f->map[i - 1].cp) return fail(c, "duplicate glyph in glyphs");
    }
    f->qmark = (int16_t)rsvp__face_find(f, '?');
    int sp = rsvp__face_find(f, ' ');
    f->space_adv = (uint16_t)(sp >= 0 ? f->map[sp].advance : f->cell_w / 4);
    if (f->space_adv == 0) f->space_adv = (uint16_t)(f->cell_w / 4 ? f->cell_w / 4 : 1);
    return true;
}

rsvp_status_t rsvp_font_parse(const char *json, size_t len, rsvp_font_t *out, char *err, size_t err_cap) {
    if (err && err_cap) err[0] = '\0';
    if (!json || !out) return RSVP_ERR_ARG;
    jcur_t c = { json, json + len, err, err_cap };
    if (len > RSVP_FONT_JSON_MAX) {
        fail(&c, "font document larger than 16 KB");
        return RSVP_ERR_FONT;
    }
    memset(out, 0, sizeof *out);
    if (!parse_face(&c, &out->normal, out, true, 0)) {
        fail(&c, "bad JSON");
        return RSVP_ERR_FONT;
    }
    jws(&c);
    if (c.p != c.e) {
        fail(&c, "trailing data after the document");
        return RSVP_ERR_FONT;
    }
    return RSVP_OK;
}

int rsvp__face_find(const rsvp_face_t *f, uint32_t cp) {
    if (!f) return -1;
    int lo = 0, hi = (int)f->count - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        uint32_t m = f->map[mid].cp;
        if (m == cp) return mid;
        if (m < cp) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

int rsvp_face_lookup(const rsvp_face_t *f, uint32_t cp) {
    int i = rsvp__face_find(f, cp);
    return i < 0 ? -1 : f->map[i].glyph;
}

static bool atlas_fits(const rsvp_face_t *f, const hca_asset_t *a) {
    return a && a->data && (a->hdr.flags & HCA_FLAG_GLYPH_ATLAS) && a->hdr.width == f->cell_w &&
           a->hdr.height == f->cell_h && a->hdr.frame_count >= f->count;
}

rsvp_status_t rsvp_font_bind(rsvp_font_t *f, const hca_asset_t *white, const hca_asset_t *accent,
                             const hca_asset_t *cw, const hca_asset_t *ca) {
    if (!f) return RSVP_ERR_ARG;
    if (!atlas_fits(&f->normal, white) || !atlas_fits(&f->normal, accent)) return RSVP_ERR_ATLAS;
    bool compact = false;
    if (f->has_compact && (cw || ca)) {
        if (!atlas_fits(&f->compact, cw) || !atlas_fits(&f->compact, ca)) return RSVP_ERR_ATLAS;
        compact = true;
    }
    f->normal.white = white;
    f->normal.accent = accent;
    f->compact.white = compact ? cw : NULL;
    f->compact.accent = compact ? ca : NULL;
    f->compact_bound = compact;
    return RSVP_OK;
}

rsvp_status_t rsvp_font_bind_large(rsvp_font_t *f, const hca_asset_t *white, const hca_asset_t *accent) {
    if (!f || !f->has_large) return RSVP_ERR_ARG;
    if (!atlas_fits(&f->large, white) || !atlas_fits(&f->large, accent)) return RSVP_ERR_ATLAS;
    f->large.white = white;
    f->large.accent = accent;
    f->large_bound = true;
    return RSVP_OK;
}

size_t rsvp_font_scratch_px(const rsvp_font_t *f) {
    if (!f) return 0;
    size_t n = (size_t)f->normal.cell_w * f->normal.cell_h;
    if (f->compact_bound) {
        size_t m = (size_t)f->compact.cell_w * f->compact.cell_h;
        if (m > n) n = m;
    }
    if (f->large_bound) {
        size_t m = (size_t)f->large.cell_w * f->large.cell_h;
        if (m > n) n = m;
    }
    return n;
}
