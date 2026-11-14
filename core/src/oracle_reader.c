/* oracle_reader.c — the sentence reader (see include/oracle_reader.h, PROTOCOL §5f.1). */
#include "oracle_reader.h"

#include <string.h>

#define SENT_CAP  (ORR_SENTENCE_MAX + 2)   /* one byte past the cut point (UTF-8 boundary test) + NUL */

/* Fixed phrase sections (ids 0..NPHRASE-1, in this order). */
enum { P_RISING = 0, P_FALLING, P_PEAK, P_DIP, P_PLATEAU, P_STILL, P_FACING, P_BACK, P_FOLLOW, P_FRONT,
       P_CENTER_LEFT, P_CENTER_RIGHT, P_SUM21, P_SAME, P_POSITIONS, P_ECHO,
       P_STEP_UP, P_STEP_DOWN, P_STEP_RESTART, P_WHEEL_FIRST, P_WHEEL_LATER, P_WORLD_FIRST,
       P_WORLD_LAST, P_FOOL_BEFORE, P_FOOL_AFTER, P_HSUM, P_HSUM_DRAWN, P_ROW_OPEN_LEFT, P_ROW_OPEN_RIGHT, P_ROW_CLOSED,
       P_SHORT_CARD, P_SHORT_POSITIONS, NPHRASE };
static const char *const s_phrase[NPHRASE] = {
    "arc.rising", "arc.falling", "arc.peak", "arc.dip", "arc.plateau", "arc.still",
    "gaze.facing", "gaze.back", "gaze.follow", "gaze.front", "gaze.center.left", "gaze.center.right",
    "kin.sum21", "kin.same", "positions", "echo",
    "step.up", "step.down", "step.restart", "place.wheel.first", "place.wheel.later",
    "place.world.first", "place.world.last", "place.fool.before", "place.fool.after", "hsum", "hsum.drawn",
    "row.open.left", "row.open.right", "row.closed", "short.card", "short.positions",
};
static const char *const s_field[ORR_FIELDS] = {
    "name", "kw", "num", "role", "from", "to", "closing", "question", "gaze", "degree", "row", "symbols", "printed", "reading",
    "srole", "brief",
};
static const char *const s_tag[ORR_TAGS] = {
    "water", "sun", "moon", "animal", "tower", "crown", "book", "sword", "cup", "coin", "staff", "child",
    "angel", "star", "wheel", "hand", "path", "flower", "egg", "mountain",
};

/* Pair sections "<prefix><a>-<b><suffix>" (a, b < ORR_MAX_CARDS, a != b): id = PAIR_BASE + kind * 78 * 78 + a * 78 + b
 * (< 0x1000 + 6 * 6084 = 40600, fits the 16-bit section id). */
enum { K_COUPLE = 0, K_COUPLE_ANY, K_MEET, K_KSUM, K_KSAME, K_SUCC, NPAIRKIND };
static const char *const s_pair_prefix[NPAIRKIND] = { "couple.", "couple.", "meet.", "kin.sum21.", "kin.same.", "succ." };
static const char *const s_pair_suffix[NPAIRKIND] = { "", ".any", "", "", "", "" };
#define PAIR_BASE 0x1000
#define SEC_PAIR(kind, a, b) (PAIR_BASE + (kind) * ORR_MAX_CARDS * ORR_MAX_CARDS + (a) * ORR_MAX_CARDS + (b))

/* Placeholder cards: {q} {A} {B} {C} the row, {X} {Y} the cards a finding names (qsum.two, place.*), {S} the hidden sum. */
enum { W_Q = 0, W_A, W_B, W_C, W_X, W_Y, W_S, NWHO };
static const char s_who[NWHO] = { 'q', 'A', 'B', 'C', 'X', 'Y', 'S' };

/* Sentence slots, in writing order (findings in descending strength, ties in the §5f.1 v3 order). */
enum { S_QUESTION = 0 /* §5f.6: never written (the short reading's scratch) */, S_COUPLE,
       S_QSUM /* §5f.6: never written */, S_MEET, S_CENTER, S_FB1, S_FB2, S_KIN, S_SUCC, S_STEP, S_ARC, S_PLACE, S_HSUM,
       S_ROW, S_FOLLOW, S_ECHO, S_POSITIONS, S_CLOSING, NSENT };
static const uint8_t s_strength[NSENT] = { 0, 5, 5, 4, 4, 3, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 0, 0 };   /* 0 = never dropped */
_Static_assert(ORR_DROP_COUPLE == 1u << S_COUPLE && ORR_DROP_ECHO == 1u << S_ECHO && ORR_DROP_ROW == 1u << S_ROW,
               "ORR_DROP_* = 1 << slot");

typedef struct { uint32_t off; uint16_t len; uint16_t sec; } orr_line_t;   /* len 0 = absent */

struct orr_bundle {
    const char *text;
    size_t len;
    uint16_t ncards, nlines;
    orr_line_t depth, prompt, armed, lead;   /* [depth], [prompt], [prompt.armed] (§5f.8), [question.lead] (§5f.2) */
    orr_line_t hint[ORR_HINTS];              /* [hint.waits|armed|next|back|end] (§5f.9) */
    orr_line_t tag[ORR_TAGS];
    orr_line_t *card;        /* ncards x ORR_FIELDS */
    orr_line_t *line;        /* phrase variants in bundle order, .sec = section id */
    char *sent;              /* NSENT x SENT_CAP */
    uint16_t slen[NSENT];
    uint16_t ssec[NSENT];    /* section id + 1 of each written phrase sentence (0 = none / the closing) */
    unsigned dropped;
};

uint32_t orr_fnv1a(uint32_t h, const void *p, size_t n)
{
    const uint8_t *b = (const uint8_t *)p;
    for (size_t i = 0; i < n; i++) h = (h ^ b[i]) * 16777619u;
    return h;
}

/* ---- parsing ----------------------------------------------------------------------------------------------- */

static bool utf8_ok(const uint8_t *s, size_t n)
{
    size_t i = 0;
    while (i < n) {
        const uint8_t c = s[i];
        if (c < 0x80) { i++; continue; }
        size_t k;
        uint32_t cp, min;
        if ((c & 0xE0) == 0xC0) { k = 1; cp = c & 0x1F; min = 0x80; }
        else if ((c & 0xF0) == 0xE0) { k = 2; cp = c & 0x0F; min = 0x800; }
        else if ((c & 0xF8) == 0xF0) { k = 3; cp = c & 0x07; min = 0x10000; }
        else return false;
        if (n - i <= k) return false;
        for (size_t j = 1; j <= k; j++) {
            if ((s[i + j] & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (s[i + j] & 0x3F);
        }
        if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        i += k + 1;
    }
    return true;
}

static bool eq(const char *s, size_t n, const char *lit)
{
    const size_t m = strlen(lit);
    return n == m && memcmp(s, lit, n) == 0;
}

static int lookup(const char *s, size_t n, const char *const *tab, int count)
{
    for (int i = 0; i < count; i++) {
        if (eq(s, n, tab[i])) return i;
    }
    return -1;
}

/* A placeholder key ("A.kw", "tag"): 0 = {tag}, 1 + who * 8 + field for the text fields, -1 = invalid. */
static int ph_key(const char *s, size_t n)
{
    if (eq(s, n, "tag")) return 0;
    if (n < 3 || s[1] != '.') return -1;
    int w = -1;
    for (int i = 0; i < NWHO; i++) {
        if (s[0] == s_who[i]) w = i;
    }
    int f = lookup(s + 2, n - 2, s_field, ORR_F_QUESTION + 1);
    if (f < 0 && eq(s + 2, n - 2, "srole")) f = ORR_F_SROLE;   /* §5f.4 the short role (else the role) */
    return (w < 0 || f < 0) ? -1 : 1 + w * 16 + f;
}

static bool phrase_ok(const char *s, size_t n)
{
    size_t i = 0;
    while (i < n) {
        if (s[i] != '{') { i++; continue; }
        size_t k = i + 1;
        while (k < n && s[k] != '}') k++;
        if (k >= n || ph_key(s + i + 1, k - i - 1) < 0) return false;
        i = k + 1;
    }
    return true;
}

typedef enum { K_NONE, K_IGNORE, K_PHRASE, K_DEPTH, K_TAG, K_CARD, K_PROMPT, K_ARMED, K_LEAD, K_HINT } kind_t;

/* 1-2 ASCII digits at s[*i] (value < ORR_MAX_CARDS), -1 otherwise. */
static int card_num(const char *s, size_t n, size_t *i)
{
    int v = 0;
    size_t d = 0;
    while (*i < n && s[*i] >= '0' && s[*i] <= '9' && d < 3) { v = v * 10 + (s[*i] - '0'); (*i)++; d++; }
    return (d < 1 || d > 2 || v >= ORR_MAX_CARDS) ? -1 : v;
}

/* A pair section ("couple.3-4", "couple.3-4.any", "meet.6-1", "kin.sum21.1-20", "kin.same.3-13", "succ.12-13"):
 * its id, or -1. */
static int pair_section(const char *s, size_t n)
{
    for (int kind = 0; kind < NPAIRKIND; kind++) {
        const size_t pl = strlen(s_pair_prefix[kind]), sl = strlen(s_pair_suffix[kind]);
        if (n <= pl + sl || memcmp(s, s_pair_prefix[kind], pl) != 0) continue;
        if (sl && memcmp(s + n - sl, s_pair_suffix[kind], sl) != 0) continue;
        const size_t end = n - sl;
        size_t i = pl;
        const int a = card_num(s, end, &i);
        if (a < 0 || i >= end || s[i] != '-') continue;
        i++;
        const int b = card_num(s, end, &i);
        if (b < 0 || i != end || a == b) continue;
        return SEC_PAIR(kind, a, b);
    }
    return -1;
}

static kind_t classify(const char *s, size_t n, int *a, int *f)
{
    int p = lookup(s, n, s_phrase, NPHRASE);
    if (p >= 0) { *a = p; return K_PHRASE; }
    p = pair_section(s, n);
    if (p >= 0) { *a = p; return K_PHRASE; }
    if (eq(s, n, "depth")) return K_DEPTH;
    if (eq(s, n, "prompt")) return K_PROMPT;
    if (eq(s, n, "prompt.armed")) return K_ARMED;
    if (eq(s, n, "question.lead")) return K_LEAD;
    if (n > 5 && memcmp(s, "hint.", 5) == 0) {
        static const char *const hints[ORR_HINTS] = { "waits", "armed", "next", "back", "end" };
        for (int h = 0; h < ORR_HINTS; h++) {
            if (eq(s + 5, n - 5, hints[h])) {
                *a = h;
                return K_HINT;
            }
        }
        return K_IGNORE;
    }
    if (n > 4 && memcmp(s, "tag.", 4) == 0) {
        p = lookup(s + 4, n - 4, s_tag, ORR_TAGS);
        if (p >= 0) { *a = p; return K_TAG; }
        return K_IGNORE;
    }
    /* card\.([0-9]{1,2})\.([a-z]+) */
    if (n > 5 && memcmp(s, "card.", 5) == 0) {
        size_t i = 5;
        const int v = card_num(s, n, &i);
        if (v < 0 || i >= n || s[i] != '.') return K_IGNORE;
        i++;
        const int fl = lookup(s + i, n - i, s_field, ORR_FIELDS);
        if (fl < 0) return K_IGNORE;
        *a = v;
        *f = fl;
        return K_CARD;
    }
    return K_IGNORE;
}

/* One pass over the text. b == NULL: count only (lines stored, highest card). */
static void scan(const char *text, size_t len, orr_bundle_t *b, uint16_t *nlines, uint16_t *ncards)
{
    kind_t cur = K_NONE;
    int ca = 0, cf = 0;
    size_t pos = 0;
    uint16_t nl = 0, nc = 0;
    while (pos < len) {
        const char *nlp = memchr(text + pos, '\n', len - pos);
        const size_t end = nlp ? (size_t)(nlp - text) : len;
        size_t s = pos, e = end;
        pos = nlp ? end + 1 : len;
        if (e > s && text[e - 1] == '\r') e--;
        const size_t n = e - s;
        const char *l = text + s;
        if (n > ORR_LINE_MAX) continue;
        bool ctl = false, blank = true;
        for (size_t i = 0; i < n; i++) {
            const uint8_t c = (uint8_t)l[i];
            if ((c < 0x20 && c != '\t') || c == 0x7F) ctl = true;
            if (c != ' ' && c != '\t') blank = false;
        }
        if (ctl || !utf8_ok((const uint8_t *)l, n)) continue;
        if (n >= 2 && l[0] == '[' && l[n - 1] == ']') {
            cur = classify(l + 1, n - 2, &ca, &cf);
            continue;
        }
        if (cur == K_NONE || cur == K_IGNORE || blank) continue;
        const orr_line_t ln = { (uint32_t)s, (uint16_t)n, 0 };
        switch (cur) {
        case K_PHRASE:
            if (!phrase_ok(l, n) || nl == UINT16_MAX) break;   /* (a 64 K-line bundle: the rest is ignored) */
            if (b) {
                b->line[nl] = ln;
                b->line[nl].sec = (uint16_t)ca;
            }
            nl++;
            break;
        case K_DEPTH:
            if (b && !b->depth.len) b->depth = ln;
            break;
        case K_PROMPT:
            if (b && !b->prompt.len) b->prompt = ln;
            break;
        case K_ARMED:
            if (b && !b->armed.len) b->armed = ln;
            break;
        case K_HINT:
            if (b && !b->hint[ca].len) b->hint[ca] = ln;
            break;
        case K_LEAD:
            if (b && !b->lead.len) b->lead = ln;
            break;
        case K_TAG:
            if (b && !b->tag[ca].len) b->tag[ca] = ln;
            break;
        case K_CARD:
            if (b && !b->card[ca * ORR_FIELDS + cf].len) b->card[ca * ORR_FIELDS + cf] = ln;
            if (ca + 1 > nc) nc = (uint16_t)(ca + 1);
            break;
        default:
            break;
        }
    }
    *nlines = nl;
    *ncards = nc;
}

static size_t align8(size_t n) { return (n + 7u) & ~(size_t)7u; }

static size_t need_bytes(uint16_t nl, uint16_t nc)
{
    return 8 + align8(sizeof(orr_bundle_t)) + align8((size_t)nc * ORR_FIELDS * sizeof(orr_line_t)) +
           align8((size_t)nl * sizeof(orr_line_t)) + (size_t)NSENT * SENT_CAP;
}

size_t orr_arena_bytes(const char *text, size_t len)
{
    if (!text) return 0;
    uint16_t nl, nc;
    scan(text, len, NULL, &nl, &nc);
    return need_bytes(nl, nc);
}

orr_bundle_t *orr_parse(const char *text, size_t len, void *arena, size_t arena_bytes)
{
    if (!text || !arena) return NULL;
    uint16_t nl, nc;
    scan(text, len, NULL, &nl, &nc);
    if (arena_bytes < need_bytes(nl, nc)) return NULL;
    uint8_t *p = (uint8_t *)arena;
    p += (8u - ((uintptr_t)p & 7u)) & 7u;
    orr_bundle_t *b = (orr_bundle_t *)(void *)p;
    memset(b, 0, sizeof *b);
    p += align8(sizeof *b);
    b->card = (orr_line_t *)(void *)p;
    memset(b->card, 0, (size_t)nc * ORR_FIELDS * sizeof(orr_line_t));
    p += align8((size_t)nc * ORR_FIELDS * sizeof(orr_line_t));
    b->line = (orr_line_t *)(void *)p;
    p += align8((size_t)nl * sizeof(orr_line_t));
    b->sent = (char *)p;
    b->text = text;
    b->len = len;
    uint16_t nl2, nc2;
    scan(text, len, b, &nl2, &nc2);
    b->nlines = nl2;
    b->ncards = nc2;
    return b;
}

unsigned orr_dropped(const orr_bundle_t *b) { return b ? b->dropped : 0; }

static size_t sec_name(int sec, char *out);
int orr_cards(const orr_bundle_t *b) { return b ? b->ncards : 0; }

static orr_line_t field(const orr_bundle_t *b, int card, int f)
{
    const orr_line_t none = { 0, 0, 0 };
    if (card < 0 || card >= b->ncards) return none;
    return b->card[card * ORR_FIELDS + f];
}

const char *orr_card_field(const orr_bundle_t *b, int card, orr_field_t f, size_t *len)
{
    if (len) *len = 0;
    if (!b || (unsigned)f >= ORR_FIELDS) return "";
    const orr_line_t l = field(b, card, f);
    if (len) *len = l.len;
    return l.len ? b->text + l.off : "";
}

/* ---- composing --------------------------------------------------------------------------------------------- */

static bool has(const orr_bundle_t *b, int i) { return i >= 0 && field(b, i, ORR_F_NAME).len > 0; }

/* The value of a numeric line: 1-3 ASCII digits, anything else (or absent) is 0. */
static int num_of(const orr_bundle_t *b, int card, int f)
{
    const orr_line_t l = field(b, card, f);
    if (l.len < 1 || l.len > 3) return 0;
    int v = 0;
    for (uint16_t i = 0; i < l.len; i++) {
        const char c = b->text[l.off + i];
        if (c < '0' || c > '9') return 0;
        v = v * 10 + (c - '0');
    }
    return v;
}

static int deg(const orr_bundle_t *b, int i)
{
    const int d = num_of(b, i, ORR_F_DEGREE);
    return d == 21 ? 11 : d;
}

static int number(const orr_bundle_t *b, int i)
{
    const int r = num_of(b, i, ORR_F_ROW), d = num_of(b, i, ORR_F_DEGREE);
    return r == 0 ? 0 : r == 3 ? 21 : r == 2 ? d + 10 : d;
}

enum { G_OTHER, G_LEFT, G_RIGHT, G_FRONT };
static int gaze(const orr_bundle_t *b, int i)
{
    const orr_line_t l = field(b, i, ORR_F_GAZE);
    const char *s = b->text + l.off;
    if (eq(s, l.len, "left")) return G_LEFT;
    if (eq(s, l.len, "right")) return G_RIGHT;
    if (eq(s, l.len, "front")) return G_FRONT;
    return G_OTHER;
}

static bool has_tag(const orr_bundle_t *b, int i, const char *tag)
{
    const orr_line_t l = field(b, i, ORR_F_SYMBOLS);
    const char *s = b->text + l.off, *e = s + l.len;
    const char *t = s;
    for (const char *p = s; p <= e; p++) {
        if (p == e || *p == ',') {
            if (eq(t, (size_t)(p - t), tag)) return true;
            t = p + 1;
        }
    }
    return false;
}

static size_t put_int(char *dst, int v)
{
    char tmp[12];
    size_t n = 0;
    unsigned u = v < 0 ? (unsigned)(-v) : (unsigned)v;
    do { tmp[n++] = (char)('0' + u % 10); u /= 10; } while (u);
    size_t k = 0;
    if (v < 0) dst[k++] = '-';
    while (n) dst[k++] = tmp[--n];
    return k;
}


typedef struct {
    char key[64];            /* "q,A,B,C," */
    size_t key_len;
} hkey_t;

/* The section's name as hashed ("arc.rising", "couple.3-4.any", "kin.sum21.1-20"). */
static size_t sec_name(int sec, char *out)
{
    if (sec < NPHRASE) {
        const size_t n = strlen(s_phrase[sec]);
        memcpy(out, s_phrase[sec], n);
        return n;
    }
    const int v = sec - PAIR_BASE, kind = v / (ORR_MAX_CARDS * ORR_MAX_CARDS), ab = v % (ORR_MAX_CARDS * ORR_MAX_CARDS);
    size_t n = strlen(s_pair_prefix[kind]);
    memcpy(out, s_pair_prefix[kind], n);
    n += put_int(out + n, ab / ORR_MAX_CARDS);
    out[n++] = '-';
    n += put_int(out + n, ab % ORR_MAX_CARDS);
    const size_t sl = strlen(s_pair_suffix[kind]);
    memcpy(out + n, s_pair_suffix[kind], sl);
    return n + sl;
}

static unsigned variants(const orr_bundle_t *b, int sec)
{
    unsigned n = 0;
    for (uint16_t i = 0; i < b->nlines; i++) n += b->line[i].sec == sec;
    return n;
}

/* The variant of phrase section `sec`, or NULL (no valid line). */
/* The variant of `sec` hashed under `name` (NULL = the section's own name). */
static const orr_line_t *pick_as(const orr_bundle_t *b, const hkey_t *k, int sec, const char *name_in, size_t name_len)
{
    const unsigned n = variants(b, sec);
    if (!n) return NULL;
    char name[48];
    size_t nl = name_len;
    if (name_in) memcpy(name, name_in, nl);
    else nl = sec_name(sec, name);
    const uint32_t h = orr_fnv1a(orr_fnv1a(2166136261u, k->key, k->key_len), name, nl);
    unsigned want = h % n;
    for (uint16_t i = 0; i < b->nlines; i++) {
        if (b->line[i].sec != sec) continue;
        if (!want--) return &b->line[i];
    }
    return NULL;
}

typedef struct {
    char *d;
    size_t n, cap;           /* bytes written (<= cap) */
} sink_t;

static void put(sink_t *s, const char *p, size_t n)
{
    const size_t room = s->cap - s->n;
    if (n > room) n = room;
    memcpy(s->d + s->n, p, n);
    s->n += n;
}

/* Finish a sentence written with cap ORR_SENTENCE_MAX + 1: cut to ORR_SENTENCE_MAX at a UTF-8 boundary. */
static uint16_t cut_sentence(char *d, size_t n)
{
    if (n > ORR_SENTENCE_MAX) {
        n = ORR_SENTENCE_MAX;
        while (n > 0 && ((uint8_t)d[n] & 0xC0) == 0x80) n--;
    }
    d[n] = '\0';
    return (uint16_t)n;
}

/* Fill template `t` into sentence slot `slot`; who[] = the cards {q} {A} {B} {C} {X} {Y} {S} stand for (-1: empty). */
static const orr_line_t *pick(const orr_bundle_t *b, const hkey_t *k, int sec) { return pick_as(b, k, sec, NULL, 0); }

static void fill(orr_bundle_t *b, int slot, const orr_line_t *t, const int who[NWHO], const orr_line_t *tag, bool depth)
{
    char *d = b->sent + (size_t)slot * SENT_CAP;
    sink_t s = { d, 0, ORR_SENTENCE_MAX + 1 };
    const char *p = b->text + t->off, *e = p + t->len;
    while (p < e) {
        if (*p != '{') {
            const char *q = p;
            while (q < e && *q != '{') q++;
            put(&s, p, (size_t)(q - p));
            p = q;
            continue;
        }
        const char *c = p + 1;
        while (c < e && *c != '}') c++;       /* validated at parse: always closed and valid */
        const int k = ph_key(p + 1, (size_t)(c - p - 1));
        p = c + 1;
        if (k == 0) {
            if (tag && tag->len) put(&s, b->text + tag->off, tag->len);
        } else if (k > 0) {
            const int card = who[(k - 1) / 16];
            int f = (k - 1) % 16;
            if (card < 0) continue;
            if (f == ORR_F_SROLE && !field(b, card, f).len) f = ORR_F_ROLE;
            const orr_line_t v = field(b, card, f);
            put(&s, b->text + v.off, v.len);
            if (depth && f == ORR_F_KW && num_of(b, card, ORR_F_ROW) == 2 && b->depth.len) {
                put(&s, " ", 1);
                put(&s, b->text + b->depth.off, b->depth.len);
            }
        }
    }
    b->slen[slot] = cut_sentence(d, s.n);
}

/* Write a variant of `sec` into `slot`; false when the section has no valid variant (the slot stays empty). */
static bool say(orr_bundle_t *b, int slot, const hkey_t *k, int sec, const int who[NWHO], const orr_line_t *tag, bool depth)
{
    const orr_line_t *t = pick(b, k, sec);
    if (t) {
        fill(b, slot, t, who, tag, depth);
        b->ssec[slot] = (uint16_t)(sec + 1);
    }
    return t != NULL;
}

/* Remove " ?\([^)]*\)" matches (leftmost first, as Python's re.sub). */
static void strip_numerals(orr_bundle_t *b, int slot)
{
    char *s = b->sent + (size_t)slot * SENT_CAP;
    const size_t n = b->slen[slot];
    size_t r = 0, w = 0;
    while (r < n) {
        size_t open = SIZE_MAX;
        if (s[r] == ' ' && r + 1 < n && s[r + 1] == '(') open = r + 1;
        else if (s[r] == '(') open = r;
        if (open != SIZE_MAX) {
            const char *close = memchr(s + open + 1, ')', n - open - 1);
            if (close) {
                r = (size_t)(close - s) + 1;
                continue;
            }
        }
        s[w++] = s[r++];
    }
    s[w] = '\0';
    b->slen[slot] = (uint16_t)w;
}

static size_t joined_len(const orr_bundle_t *b)
{
    size_t t = 0, k = 0;
    for (int i = 0; i < NSENT; i++) {
        if (b->slen[i]) { t += b->slen[i]; k++; }
    }
    return k ? t + k - 1 : 0;
}

/* The first `limit` bytes of the joined paragraph into out (no NUL); returns the bytes written. */
static size_t join(const orr_bundle_t *b, char *out, size_t limit)
{
    sink_t s = { out, 0, limit };
    bool first = true;
    for (int i = 0; i < NSENT; i++) {
        if (!b->slen[i]) continue;
        if (!first) put(&s, " ", 1);
        put(&s, b->sent + (size_t)i * SENT_CAP, b->slen[i]);
        first = false;
    }
    return s.n;
}

/* The order pairs are scanned in, with the order of appearance (q is drawn first, then A, B, C). */
/* Le Mat counts 22 in sums (question sum, hidden sum); a sum over 22 is reduced by adding its digits until <= 22. */
static int n22(const orr_bundle_t *b, int i) { return num_of(b, i, ORR_F_ROW) == 0 ? 22 : number(b, i); }

static int reduce22(int x)
{
    while (x > 22) {
        int d = 0;
        for (; x; x /= 10) d += x % 10;
        x = d;
    }
    return x;
}

static bool same_pair(int x, int y, int cx, int cy) { return (x == cx && y == cy) || (x == cy && y == cx); }

/* who[] = the row, with {X} {Y} {S} empty. */
static void who_base(int w[NWHO], int q, int A, int B, int C)
{
    w[W_Q] = q;
    w[W_A] = A;
    w[W_B] = B;
    w[W_C] = C;
    w[W_X] = w[W_Y] = w[W_S] = -1;
}

/* The row with {A} {B} replaced (a pair finding). */
static void who_pair(int w[NWHO], const int base[NWHO], int a, int bb)
{
    memcpy(w, base, sizeof(int) * NWHO);
    w[W_A] = a;
    w[W_B] = bb;
}

/* Every sentence of the row into the bundle's slots (no budget): the question, the findings, the positions, the
 * closing. -1: bad arguments / cards. */
static int build(orr_bundle_t *b, int q, int A, int B, int C, hkey_t *kout)
{
    if (!b || q != -1) return -1;   /* §5f.6: no question card */
    {
        const int in[3] = { A, B, C };
        for (int i = 0; i < 3; i++) {
            if (!has(b, in[i])) return -1;
        }
    }
    hkey_t k;
    size_t n = 0;
    const int v[4] = { q, A, B, C };
    for (int i = 0; i < 4; i++) {
        n += put_int(k.key + n, v[i]);
        k.key[n++] = ',';
    }
    k.key_len = n;
    memset(b->slen, 0, sizeof b->slen);
    memset(b->ssec, 0, sizeof b->ssec);
    b->dropped = 0;
    int base[NWHO], w[NWHO];
    who_base(base, q, A, B, C);
    const int row[3] = { A, B, C };

    {
        const int pr[3][2] = { { A, B }, { B, C }, { A, C } };
        const int adj[2][2] = { { A, B }, { B, C } };

        /* couple (5): the first pair of the scan with a section: in its order (couple.<x>-<y>), else unordered
         * (couple.<lo>-<hi>.any) */
        int cx = -1, cy = -1;
        for (int i = 0; i < 3; i++) {
            const int x = pr[i][0], y = pr[i][1];
            if (x == y) continue;
            const int lo = x < y ? x : y, hi = x < y ? y : x;
            who_pair(w, base, x, y);
            bool said = say(b, S_COUPLE, &k, SEC_PAIR(K_COUPLE, x, y), w, NULL, false);
            if (!said) {
                who_pair(w, base, lo, hi);
                said = say(b, S_COUPLE, &k, SEC_PAIR(K_COUPLE_ANY, lo, hi), w, NULL, false);
            }
            if (said) {
                cx = x;
                cy = y;
                break;
            }
        }

        /* encounter (4): the first pair with meet.<x>-<y> (order of appearance), else meet.<y>-<x> */
        for (int i = 0; i < 3; i++) {
            const int x = pr[i][0], y = pr[i][1];
            if (x == y) continue;
            who_pair(w, base, x, y);
            if (say(b, S_MEET, &k, SEC_PAIR(K_MEET, x, y), w, NULL, false)) break;
            who_pair(w, base, y, x);
            if (say(b, S_MEET, &k, SEC_PAIR(K_MEET, y, x), w, NULL, false)) break;
        }

        /* centre gaze (4): B addresses A (left), C (right) or you (front) */
        const int gB = gaze(b, B);
        bool cover_ab = false, cover_bc = false;
        if (gB == G_LEFT) cover_ab = say(b, S_CENTER, &k, P_CENTER_LEFT, base, NULL, false);
        else if (gB == G_RIGHT) cover_bc = say(b, S_CENTER, &k, P_CENTER_RIGHT, base, NULL, false);
        else if (gB == G_FRONT) say(b, S_CENTER, &k, P_FRONT, base, NULL, false);

        /* facing / back to back (3) for (A,B), (B,C), skipping a pair the centre gaze covers;
         * follow (1): the first pair (not covered) whose cards look the same way, the follower as {A} */
        int fb = S_FB1;
        bool followed = false;
        for (int i = 0; i < 2; i++) {
            if (i == 0 ? cover_ab : cover_bc) continue;
            const int x = adj[i][0], y = adj[i][1], gx = gaze(b, x), gy = gaze(b, y);
            if ((gx != G_LEFT && gx != G_RIGHT) || (gy != G_LEFT && gy != G_RIGHT)) continue;
            who_pair(w, base, x, y);
            if (gx == G_RIGHT && gy == G_LEFT) {
                if (say(b, fb, &k, P_FACING, w, NULL, false)) fb++;
            } else if (gx == G_LEFT && gy == G_RIGHT) {
                if (say(b, fb, &k, P_BACK, w, NULL, false)) fb++;
            } else if (!followed) {
                who_pair(w, base, gx == G_RIGHT ? x : y, gx == G_RIGHT ? y : x);
                followed = say(b, S_FOLLOW, &k, P_FOLLOW, w, NULL, false);
            }
        }

        /* kinship (3): outside the couple's pair, the first pair summing to 21, else the first of one degree in rows 1
         * and 2; its own section (kin.sum21.<lo>-<hi> / kin.same.<lo>-<hi>, {A} = lo) or the generic one ({A} = x) */
        {
            int kx = -1, ky = -1, kpass = -1;
            for (int pass = 0; pass < 2 && kpass < 0; pass++) {
                for (int i = 0; i < 3; i++) {
                    const int x = pr[i][0], y = pr[i][1];
                    if (x == y || same_pair(x, y, cx, cy)) continue;
                    const int rx = num_of(b, x, ORR_F_ROW), ry = num_of(b, y, ORR_F_ROW);
                    const bool hit = pass == 0 ? number(b, x) + number(b, y) == 21
                                               : deg(b, x) == deg(b, y) && ((rx == 1 && ry == 2) || (rx == 2 && ry == 1));
                    if (hit) {
                        kx = x;
                        ky = y;
                        kpass = pass;
                        break;
                    }
                }
            }
            if (kpass >= 0) {
                const int lo = kx < ky ? kx : ky, hi = kx < ky ? ky : kx;
                who_pair(w, base, lo, hi);
                if (!say(b, S_KIN, &k, SEC_PAIR(kpass == 0 ? K_KSUM : K_KSAME, lo, hi), w, NULL, false)) {
                    who_pair(w, base, kx, ky);
                    say(b, S_KIN, &k, kpass == 0 ? P_SUM21 : P_SAME, w, NULL, false);
                }
            }
        }

        /* succession (3): (A,B) then (B,C), the first with succ.<x>-<y> */
        int sx = -1, sy = -1;
        for (int i = 0; i < 2; i++) {
            const int x = adj[i][0], y = adj[i][1];
            who_pair(w, base, x, y);
            if (say(b, S_SUCC, &k, SEC_PAIR(K_SUCC, x, y), w, NULL, false)) {
                sx = x;
                sy = y;
                break;
            }
        }

        /* degree step (2): (A,B) then (B,C), both in rows 1-2, not the couple's nor the succession's pair: 10 then 1
         * = step.restart, one degree up / down = step.up / step.down; the first written */
        for (int i = 0; i < 2; i++) {
            const int x = adj[i][0], y = adj[i][1];
            if (same_pair(x, y, cx, cy) || same_pair(x, y, sx, sy)) continue;
            const int rx = num_of(b, x, ORR_F_ROW), ry = num_of(b, y, ORR_F_ROW);
            if (rx < 1 || rx > 2 || ry < 1 || ry > 2) continue;
            const int dx = deg(b, x), dy = deg(b, y);
            const int sec = (dx == 10 && dy == 1) ? P_STEP_RESTART : dy == dx + 1 ? P_STEP_UP : dy == dx - 1 ? P_STEP_DOWN : -1;
            who_pair(w, base, x, y);
            if (sec >= 0 && say(b, S_STEP, &k, sec, w, NULL, false)) break;
        }

        /* arc (2) */
        {
            const int dA = deg(b, A), dB = deg(b, B), dC = deg(b, C);
            int sec;
            if (dA == dB && dB == dC) sec = P_STILL;
            else if (dA == dB || dB == dC || dA == dC) sec = P_PLATEAU;
            else if (dA < dB && dB < dC) sec = P_RISING;
            else if (dA > dB && dB > dC) sec = P_FALLING;
            else if (dB > dA && dB > dC) sec = P_PEAK;
            else sec = P_DIP;
            say(b, S_ARC, &k, sec, base, NULL, true);
        }

        /* placement (2), the first of: La Roue de Fortune (card 10) first / later, Le Monde (21) first / last, Le Mat (0)
         * walking towards the card on his right ({X}; in C: towards B), unless that pair is the couple's */
        {
            int psec = -1, px = -1;
            if (A == 10) { psec = P_WHEEL_FIRST; px = 10; }
            else if (B == 10 || C == 10) { psec = P_WHEEL_LATER; px = 10; }
            else if (A == 21) { psec = P_WORLD_FIRST; px = 21; }
            else if (C == 21) { psec = P_WORLD_LAST; px = 21; }
            else if (A == 0 || B == 0 || C == 0) {
                const int p = A == 0 ? 0 : B == 0 ? 1 : 2;
                const int nb = p < 2 ? row[p + 1] : B;
                if (!same_pair(0, nb, cx, cy)) {
                    psec = p < 2 ? P_FOOL_BEFORE : P_FOOL_AFTER;
                    px = nb;
                }
            }
            if (psec >= 0) {
                memcpy(w, base, sizeof w);
                w[W_X] = px;
                say(b, S_PLACE, &k, psec, w, NULL, false);
            }
        }

        /* hidden sum (2): the card S = reduced nA + nB + nC (22 = Le Mat); hsum.drawn when it is in the row; not after
         * qsum.three (the same sum) */
        {
            const int S = reduce22(n22(b, A) + n22(b, B) + n22(b, C)) % 22;
            memcpy(w, base, sizeof w);
            w[W_S] = S;
            say(b, S_HSUM, &k, (S == A || S == B || S == C) ? P_HSUM_DRAWN : P_HSUM, w, NULL, false);
        }

        /* open / closed (1): A looks out to the left, else C out to the right, else A and C look in */
        {
            const int gA = gaze(b, A), gC = gaze(b, C);
            const int sec = gA == G_LEFT ? P_ROW_OPEN_LEFT : gC == G_RIGHT ? P_ROW_OPEN_RIGHT
                          : (gA == G_RIGHT && gC == G_LEFT) ? P_ROW_CLOSED : -1;
            if (sec >= 0) say(b, S_ROW, &k, sec, base, NULL, false);
        }

        /* echo (1): the first tag (fixed order, with a gloss) on two or three of A, B, C */
        for (int t = 0; t < ORR_TAGS; t++) {
            if (!b->tag[t].len) continue;
            int c = 0;
            for (int i = 0; i < 3; i++) c += has_tag(b, row[i], s_tag[t]);
            if (c >= 2) {
                say(b, S_ECHO, &k, P_ECHO, base, &b->tag[t], false);
                break;
            }
        }

        say(b, S_POSITIONS, &k, P_POSITIONS, base, NULL, false);
    }

    {
        const orr_line_t cl = field(b, B, ORR_F_CLOSING);   /* §5f.6: the centre card's closing */
        char *d = b->sent + (size_t)S_CLOSING * SENT_CAP;
        sink_t s = { d, 0, ORR_SENTENCE_MAX + 1 };
        put(&s, b->text + cl.off, cl.len);
        b->slen[S_CLOSING] = cut_sentence(d, s.n);
    }
    if (kout) *kout = k;
    return 0;
}

int orr_compose(orr_bundle_t *b, int q, int A, int B, int C, char *out, size_t cap)
{
    if (!b || !out || cap < ORR_OUT_MIN) return -1;
    out[0] = '\0';
    if (build(b, q, A, B, C, NULL) < 0) return -1;
    size_t n;

    /* the budget: the weakest finding first (equal strengths: the one written later first); the arc first loses its
     * " (...)" numerals, and is dropped only if that is not enough */
    size_t total = joined_len(b);
    for (int str = 1; str <= 5 && total > ORR_TEXT_MAX; str++) {
        if (str == 2 && b->slen[S_ARC]) {
            const uint16_t before = b->slen[S_ARC];
            strip_numerals(b, S_ARC);
            if (b->slen[S_ARC] != before) {
                b->dropped |= ORR_DROP_NUMERALS;
                total = joined_len(b);
            }
        }
        for (int s = NSENT - 1; s >= 0 && total > ORR_TEXT_MAX; s--) {
            if (s_strength[s] != str || !b->slen[s]) continue;
            b->slen[s] = 0;
            b->dropped |= 1u << s;
            total = joined_len(b);
        }
    }
    if (total <= ORR_TEXT_MAX) {
        n = join(b, out, total);
    } else {
        /* the prefix up to byte ORR_TEXT_MAX - 3 inclusive decides the cut */
        const size_t lim = ORR_TEXT_MAX - 3;
        n = join(b, out, lim + 1);
        size_t cut = 0;
        for (size_t i = lim + 1; i-- > 1;) {
            if (out[i] == ' ') { cut = i; break; }
        }
        if (!cut) {
            cut = lim;
            while (cut > 0 && ((uint8_t)out[cut] & 0xC0) == 0x80) cut--;
        }
        memcpy(out + cut, "\xE2\x80\xA6", 3);
        n = cut + 3;
        b->dropped |= ORR_DROP_CUT;
    }
    out[n] = '\0';
    return (int)n;
}

size_t orr_sections(const orr_bundle_t *b, char *out, size_t cap)
{
    if (!out || !cap) return 0;
    out[0] = '\0';
    if (!b) return 0;
    size_t n = 0;
    for (int i = 0; i < NSENT; i++) {
        if (!b->slen[i]) continue;
        char name[32];
        size_t m;
        if (i == S_CLOSING) {
            memcpy(name, "closing", 7);
            m = 7;
        } else {
            if (!b->ssec[i]) continue;
            m = sec_name(b->ssec[i] - 1, name);
        }
        if (n + (n ? 1 : 0) + m + 1 > cap) break;
        if (n) out[n++] = ',';
        memcpy(out + n, name, m);
        n += m;
        out[n] = '\0';
    }
    return n;
}

const char *orr_prompt(const orr_bundle_t *b, size_t *len)
{
    if (len) *len = b ? b->prompt.len : 0;
    return b && b->prompt.len ? b->text + b->prompt.off : "";
}

const char *orr_prompt_armed(const orr_bundle_t *b, size_t *len)
{
    if (b && !b->armed.len) return orr_prompt(b, len);
    if (len) *len = b ? b->armed.len : 0;
    return b ? b->text + b->armed.off : "";
}

const char *orr_hint(const orr_bundle_t *b, orr_hint_t h, size_t *len)
{
    const bool ok = b && (unsigned)h < ORR_HINTS && b->hint[h].len;
    if (len) *len = ok ? b->hint[h].len : 0;
    return ok ? b->text + b->hint[h].off : "";
}

const char *orr_question_lead(const orr_bundle_t *b, size_t *len)
{
    if (len) *len = b ? b->lead.len : 0;
    return b && b->lead.len ? b->text + b->lead.off : "";
}

/* ---- the short reading (§5f.4) --------------------------------------------------------------------------------- */

/* Copy sentence slot `slot` into out (cap bytes, NUL-terminated, cut at a UTF-8 boundary); returns the length. */
static size_t copy_slot(const orr_bundle_t *b, int slot, char *out, size_t cap)
{
    size_t n = b->slen[slot];
    if (n > cap - 1) {
        n = cap - 1;
        const char *d = b->sent + (size_t)slot * SENT_CAP;
        while (n > 0 && ((uint8_t)d[n] & 0xC0) == 0x80) n--;
    }
    memcpy(out, b->sent + (size_t)slot * SENT_CAP, n);
    out[n] = '\0';
    return n;
}

/* Append " " + src (len n) to out (length *len, cap bytes) when it fits whole; false otherwise. */
static bool append(char *out, size_t cap, size_t *len, const char *src, size_t n)
{
    const size_t sep = *len ? 1 : 0;
    if (*len + sep + n + 1 > cap) return false;
    if (sep) out[(*len)++] = ' ';
    memcpy(out + *len, src, n);
    *len += n;
    out[*len] = '\0';
    return true;
}

/* Card `card`'s line from [short.card] variant `t` (as {X}) into slot S_QUESTION (the scratch). */
static void short_card(orr_bundle_t *b, const orr_line_t *t, const int base[NWHO], int card)
{
    int w[NWHO];
    memcpy(w, base, sizeof w);
    w[W_X] = card;
    fill(b, S_QUESTION, t, w, NULL, false);
}

size_t orr_chars(const char *s, size_t n)
{
    size_t c = 0;
    for (size_t i = 0; i < n; i++) c += ((uint8_t)s[i] & 0xC0) != 0x80;
    return c;
}

/* The default page test: <= ORR_LEAN_PAGE_CHARS code points. */
static bool fits_default(const char *s, size_t n) { return orr_chars(s, n) <= ORR_LEAN_PAGE_CHARS; }

static bool fits_page(orr_fits_fn fits, void *ctx, const char *s, size_t n)
{
    return fits ? fits(ctx, s, n) : fits_default(s, n);
}

/* A finding slot the "together" / "and" screens may use: not the arc, gaze.front, follow or echo. */
static bool lean_finding(const orr_bundle_t *b, int slot)
{
    if (!b->slen[slot] || slot == S_ARC || slot == S_FOLLOW || slot == S_ECHO) return false;
    if (slot == S_CENTER && b->ssec[slot] == P_FRONT + 1) return false;
    return true;
}

int orr_compose_lean(orr_bundle_t *b, int A, int B, int C, char *const out[ORR_LEAN_SCREENS],
                     const size_t caps[ORR_LEAN_SCREENS], orr_fits_fn fits, void *ctx)
{
    if (!b || !out || !caps) return -1;
    for (int i = 0; i < ORR_LEAN_SCREENS; i++) {
        if (!out[i] || caps[i] < 2) return -1;
        out[i][0] = '\0';
    }
    hkey_t k;
    if (build(b, -1, A, B, C, &k) < 0) return -1;   /* every sentence (the findings, the closing) */
    int base[NWHO];
    who_base(base, -1, A, B, C);
    size_t len;
    /* 2: by the numbers: the arc sentence, numerals and all */
    if (b->slen[S_ARC]) copy_slot(b, S_ARC, out[2], caps[2]);
    /* 3: together: the strongest finding other than the arc, gaze.front, follow and echo; 4: and: the second one +
     * " " + B's closing if that fits a page, else the finding alone if it fits, else the closing alone (also when
     * there is no second finding) */
    int first = -1, second = -1;
    for (int slot = S_COUPLE; slot <= S_ECHO; slot++) {
        if (!lean_finding(b, slot)) continue;
        if (first < 0) first = slot;
        else if (second < 0) second = slot;
    }
    if (first >= 0) copy_slot(b, first, out[3], caps[3]);
    const char *cl = b->sent + (size_t)S_CLOSING * SENT_CAP;
    const size_t cln = b->slen[S_CLOSING];
    len = 0;
    if (second >= 0) {
        const char *f2 = b->sent + (size_t)second * SENT_CAP;
        const size_t f2n = b->slen[second];
        char *both = b->sent + (size_t)S_QSUM * SENT_CAP;   /* an unused slot as the scratch */
        const size_t bn = f2n + (cln ? 1 + cln : 0);
        const bool room = bn < SENT_CAP;   /* longer never fits a page anyway */
        if (room) {
            memcpy(both, f2, f2n);
            if (cln) {
                both[f2n] = ' ';
                memcpy(both + f2n + 1, cl, cln);
            }
        }
        if (room && fits_page(fits, ctx, both, bn)) {
            append(out[4], caps[4], &len, both, bn);
        } else if (fits_page(fits, ctx, f2, f2n)) {
            append(out[4], caps[4], &len, f2, f2n);
        }
    }
    if (!len) append(out[4], caps[4], &len, cl, cln);
    /* 1: by position */
    memset(b->slen, 0, sizeof b->slen);
    if (say(b, S_QUESTION, &k, P_SHORT_POSITIONS, base, NULL, false)) copy_slot(b, S_QUESTION, out[1], caps[1]);
    /* 0: by card, A B C: one [short.card] variant for the row ("-1,A,B,C,short.card"), applied to each card */
    const orr_line_t *t = pick(b, &k, P_SHORT_CARD);
    const int row[3] = { A, B, C };
    size_t l0 = 0;
    for (int i = 0; i < 3 && t; i++) {
        short_card(b, t, base, row[i]);
        append(out[0], caps[0], &l0, b->sent + (size_t)S_QUESTION * SENT_CAP, b->slen[S_QUESTION]);
    }
    memset(b->slen, 0, sizeof b->slen);   /* orr_sections / orr_dropped describe orr_compose only */
    memset(b->ssec, 0, sizeof b->ssec);
    b->dropped = 0;
    return ORR_LEAN_SCREENS;
}
