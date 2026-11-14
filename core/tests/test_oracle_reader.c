/* test_oracle_reader.c — the sentence reader (include/oracle_reader.h, PROTOCOL §5f.1 v3, §5f.4, §5f.6).
 *
 * Hand-checked paragraphs over the synthetic bundles core/fixtures/tarot/reader-synth.txt / reader-synth3.txt (a known
 * card table, every v2 / v3 / short-reading section) and small inline bundles: every finding, both encounter orders,
 * the kinship priority, every arc shape, variants, the short reading, the budget order on long bundles, the final cut,
 * malformed lines; then the shared fixtures core/fixtures/tarot/cases.json and cases-short.json (what the iOS mirror
 * must reproduce), an exhaustive sweep of the real bundles and a mutation fuzz (ASan / UBSan: core/tests/run_asan.sh).
 * §5f.6: no question card anywhere (q = -1), the closing is B's.
 *
 *   test_oracle_reader --write-fixtures    regenerates cases.json and cases-short.json from this composer
 */
#include "tharness.h"
#include "oracle_reader.h"
#include <time.h>

#ifndef ORR_FIXTURES
#define ORR_FIXTURES "core/fixtures/tarot"
#endif

/* ---- files ---------------------------------------------------------------------------------------------------- */

static char *slurp(const char *name, size_t *len)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", ORR_FIXTURES, name);
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END);
    const long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *p = malloc((size_t)n + 1);
    if (p && fread(p, 1, (size_t)n, f) != (size_t)n) { free(p); p = NULL; }
    fclose(f);
    if (p) { p[n] = '\0'; *len = (size_t)n; }
    return p;
}

/* ---- a minimal JSON reader (the fixture file only) ------------------------------------------------------------ */

typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } jtype_t;
typedef struct jv {
    jtype_t t;
    double num;
    char *str;               /* J_STR (UTF-8, NUL-terminated); J_OBJ member key */
    size_t slen;
    struct jv *kid, *next;   /* J_ARR / J_OBJ children */
    char *key;
} jv_t;

static const char *jp;
static void jws(void) { while (*jp == ' ' || *jp == '\n' || *jp == '\r' || *jp == '\t') jp++; }

static void put_utf8(char **o, unsigned cp)
{
    char *d = *o;
    if (cp < 0x80) *d++ = (char)cp;
    else if (cp < 0x800) { *d++ = (char)(0xC0 | (cp >> 6)); *d++ = (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { *d++ = (char)(0xE0 | (cp >> 12)); *d++ = (char)(0x80 | ((cp >> 6) & 0x3F)); *d++ = (char)(0x80 | (cp & 0x3F)); }
    else { *d++ = (char)(0xF0 | (cp >> 18)); *d++ = (char)(0x80 | ((cp >> 12) & 0x3F)); *d++ = (char)(0x80 | ((cp >> 6) & 0x3F)); *d++ = (char)(0x80 | (cp & 0x3F)); }
    *o = d;
}

static unsigned hex4(const char *s)
{
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        const char c = s[i];
        v = v * 16 + (unsigned)(c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10);
    }
    return v;
}

static char *jstring(size_t *len)
{
    jp++;   /* " */
    const char *s = jp;
    size_t n = 0;
    while (s[n] && s[n] != '"') n += s[n] == '\\' ? 2 : 1;
    char *o = malloc(n + 1), *d = o;
    while (*jp && *jp != '"') {
        if (*jp != '\\') { *d++ = *jp++; continue; }
        jp++;
        const char c = *jp++;
        switch (c) {
        case 'n': *d++ = '\n'; break;
        case 't': *d++ = '\t'; break;
        case 'r': *d++ = '\r'; break;
        case 'b': *d++ = '\b'; break;
        case 'f': *d++ = '\f'; break;
        case 'u': {
            unsigned cp = hex4(jp);
            jp += 4;
            if (cp >= 0xD800 && cp < 0xDC00 && jp[0] == '\\' && jp[1] == 'u') {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (hex4(jp + 2) - 0xDC00);
                jp += 6;
            }
            put_utf8(&d, cp);
            break;
        }
        default: *d++ = c; break;
        }
    }
    if (*jp == '"') jp++;
    *d = '\0';
    *len = (size_t)(d - o);
    return o;
}

static jv_t *jvalue(void)
{
    jws();
    jv_t *v = calloc(1, sizeof *v);
    if (*jp == '{' || *jp == '[') {
        const char close = *jp == '{' ? '}' : ']';
        v->t = *jp == '{' ? J_OBJ : J_ARR;
        jp++;
        jv_t **tail = &v->kid;
        jws();
        while (*jp && *jp != close) {
            char *key = NULL;
            if (v->t == J_OBJ) {
                size_t kl;
                key = jstring(&kl);
                jws();
                if (*jp == ':') jp++;
            }
            jv_t *c = jvalue();
            c->key = key;
            *tail = c;
            tail = &c->next;
            jws();
            if (*jp == ',') jp++;
            jws();
        }
        if (*jp) jp++;
    } else if (*jp == '"') {
        v->t = J_STR;
        v->str = jstring(&v->slen);
    } else if (*jp == 't' || *jp == 'f') {
        v->t = J_BOOL;
        v->num = *jp == 't';
        jp += *jp == 't' ? 4 : 5;
    } else if (*jp == 'n') {
        v->t = J_NULL;
        jp += 4;
    } else {
        v->t = J_NUM;
        char *e;
        v->num = strtod(jp, &e);
        jp = e;
    }
    return v;
}

static void jfree(jv_t *v)
{
    while (v) {
        jv_t *n = v->next;
        jfree(v->kid);
        free(v->str);
        free(v->key);
        free(v);
        v = n;
    }
}

static jv_t *jget(const jv_t *o, const char *key)
{
    for (jv_t *c = o ? o->kid : NULL; c; c = c->next) {
        if (c->key && strcmp(c->key, key) == 0) return c;
    }
    return NULL;
}

static int jint(const jv_t *o, const char *key) { const jv_t *v = jget(o, key); return v ? (int)v->num : -999; }
static const char *jstr(const jv_t *o, const char *key) { const jv_t *v = jget(o, key); return v && v->t == J_STR ? v->str : ""; }


/* ---- bundles -------------------------------------------------------------------------------------------------- */

#define NB 6
typedef struct {
    char name[16];
    char *text;
    size_t len;
    void *arena;
    orr_bundle_t *b;
} bundle_t;

static bundle_t s_b[NB];

/* core/fixtures/tarot/reader-<name>.txt, parsed once. */
static bundle_t *bundle_file(const char *name)
{
    for (int i = 0; i < NB; i++) {
        if (s_b[i].b && strcmp(s_b[i].name, name) == 0) return &s_b[i];
    }
    for (int i = 0; i < NB; i++) {
        if (s_b[i].b) continue;
        char file[64];
        snprintf(file, sizeof file, "reader-%s.txt", name);
        s_b[i].text = slurp(file, &s_b[i].len);
        if (!s_b[i].text) return NULL;
        const size_t need = orr_arena_bytes(s_b[i].text, s_b[i].len);
        s_b[i].arena = malloc(need);
        s_b[i].b = orr_parse(s_b[i].text, s_b[i].len, s_b[i].arena, need);
        snprintf(s_b[i].name, sizeof s_b[i].name, "%s", name);
        return s_b[i].b ? &s_b[i] : NULL;
    }
    return NULL;
}

static orr_bundle_t *bundle(const char *name)
{
    bundle_t *b = bundle_file(name);
    return b ? b->b : NULL;
}

/* An inline bundle (text kept alive by the caller's buffer until the next mk()). */
typedef struct {
    char *text;
    void *arena;
    orr_bundle_t *b;
} mk_t;

static void mk_free(mk_t *m)
{
    free(m->text);
    free(m->arena);
    memset(m, 0, sizeof *m);
}

static orr_bundle_t *mk_len(mk_t *m, const char *text, size_t len)
{
    mk_free(m);
    m->text = malloc(len + 1);
    memcpy(m->text, text, len);
    m->text[len] = '\0';
    const size_t need = orr_arena_bytes(m->text, len);
    m->arena = malloc(need);
    m->b = orr_parse(m->text, len, m->arena, need);
    return m->b;
}

/* `phrases` + the synthetic card table (everything of reader-synth.txt from its first card section on). */
static orr_bundle_t *mk_synth(mk_t *m, const char *phrases)
{
    const bundle_t *s = bundle_file("synth");
    if (!s) return NULL;
    const char *tab = strstr(s->text, "\n[card.");
    tab = tab ? tab + 1 : s->text + s->len;
    const size_t pl = strlen(phrases), tl = (size_t)(s->text + s->len - tab);
    char *t = malloc(pl + tl + 2);
    memcpy(t, phrases, pl);
    size_t n = pl;
    if (n && t[n - 1] != '\n') t[n++] = '\n';
    memcpy(t + n, tab, tl);
    orr_bundle_t *b = mk_len(m, t, n + tl);
    free(t);
    return b;
}

static char s_out[ORR_OUT_MIN];

static const char *rd(orr_bundle_t *b, int A, int B, int C)
{
    const int r = orr_compose(b, -1, A, B, C, s_out, sizeof s_out);
    if (r < 0) return "(error)";
    if ((size_t)r != strlen(s_out)) return "(length mismatch)";
    return s_out;
}

#define SAYS(got, want) do { const char *_g = (got), *_w = (want); th_checks++; \
    if (strcmp(_g, _w) != 0) { th_failures++; \
        fprintf(stderr, "%s:%d: paragraph differs\n  got  %s\n  want %s\n", __FILE__, __LINE__, _g, _w); } } while (0)

static bool utf8_valid(const char *s, size_t n)
{
    size_t i = 0;
    while (i < n) {
        const unsigned char c = (unsigned char)s[i];
        const size_t k = c < 0x80 ? 0 : (c & 0xE0) == 0xC0 ? 1 : (c & 0xF0) == 0xE0 ? 2 : (c & 0xF8) == 0xF0 ? 3 : 9;
        if (k == 9 || k > n - i - 1) return false;
        for (size_t j = 1; j <= k; j++) {
            if (((unsigned char)s[i + j] & 0xC0) != 0x80) return false;
        }
        i += k + 1;
    }
    return true;
}

/* An independent FNV-1a (so the variant rule is checked, not just reused). */
static uint32_t fnv(const char *s)
{
    uint32_t h = 2166136261u;
    for (; *s; s++) h = (h ^ (uint8_t)*s) * 16777619u;
    return h;
}

/* ---- budget names (fixtures) ---------------------------------------------------------------------------------- */

static const struct { unsigned bit; const char *name; } s_drops[] = {
    { ORR_DROP_COUPLE, "couple" }, { ORR_DROP_MEET, "meet" }, { ORR_DROP_CENTER, "center" },
    { ORR_DROP_FB1, "facing1" }, { ORR_DROP_FB2, "facing2" }, { ORR_DROP_KIN, "kin" }, { ORR_DROP_SUCC, "succ" },
    { ORR_DROP_STEP, "step" }, { ORR_DROP_ARC, "arc" }, { ORR_DROP_PLACE, "place" }, { ORR_DROP_HSUM, "hsum" },
    { ORR_DROP_ROW, "row" }, { ORR_DROP_FOLLOW, "follow" }, { ORR_DROP_ECHO, "echo" },
    { ORR_DROP_NUMERALS, "numerals" }, { ORR_DROP_CUT, "cut" },
};
#define NDROPS (sizeof s_drops / sizeof s_drops[0])

static unsigned drop_mask(const jv_t *arr)
{
    unsigned m = 0;
    for (const jv_t *c = arr ? arr->kid : NULL; c; c = c->next) {
        bool known = false;
        for (size_t i = 0; i < NDROPS; i++) {
            if (c->str && strcmp(c->str, s_drops[i].name) == 0) { m |= s_drops[i].bit; known = true; }
        }
        if (!known) m |= 1u << 31;
    }
    return m;
}

/* ---- hand-checked paragraphs (synthetic bundles) -------------------------------------------------------------- */

/* Synthetic table (reader-synth.txt): card i = name (Zero..Twenty, World), kw "kw<i>", Marseille numeral, role "role<i>",
 * from "from<i>", to "to<i>", closing "Closing <i>.", question "Question <i>?"; degree / row as the Marseille trumps;
 * gaze r l f r l f r r l l f | r f l l f r l f f f | f (0..21); symbols 0 path,water 1 hand,staff 2 book 3 crown,flower
 * 4 crown 5 book 6 angel 7 wheel 8 sword 9 path 10 wheel 11 animal 12 hand 13 sword 14 cup,angel 15 animal 16 tower
 * 17 star,water 18 moon,water 19 sun,child 20 angel 21 crown; glosses for water crown path angel book wheel sword hand
 * (not animal). Couples couple.<lo>-<hi> (lo before hi) and couple.<lo>-<hi>.any for 0-21 1-11 2-5 3-4 7-17 8-9
 * 18-19; encounters meet.1-2 + meet.2-1 (both orders), meet.4-6. §5f.6: no question card; the closing is B's. */
static void test_findings(void)
{
    orr_bundle_t *s = bundle("synth");
    CHECK(s != NULL);
    if (!s) return;
    CHECK_EQ(orr_cards(s), 22);
    /* couple (A,B) in order, centre gaze left with {A.role}, kin sum21 on (B,C), rising arc with depth, follow (C behind
     * B), echo (crown on A and B), B's closing */
    SAYS(rd(s, 3, 4, 17),
         "Couple Three+Four. Four addresses Three, role3. Four+Seventeen=21. Rising (III, IIII, XVII): kw3, kw4, kw17 deep. "
         "Seventeen follows Four. Echo: crown. Centre Four, role4; from from3 to to17. Closing 4.");
    char sec[256];
    orr_sections(s, sec, sizeof sec);
    SAYS(sec, "couple.3-4,gaze.center.left,kin.sum21,arc.rising,gaze.follow,echo,positions,closing");
    CHECK_EQ(orr_dropped(s), 0);
    /* encounter in the order of appearance (meet.1-2), centre gaze front */
    SAYS(rd(s, 1, 2, 3),
         "Meet One>Two. Two looks at you. Rising (I, II, III): kw1, kw2, kw3. Centre Two, role2; from from1 to to3. Closing 2.");
    /* the other order exists too (meet.2-1); centre gaze left covers (A,B); (B,C) back to back; dip */
    SAYS(rd(s, 2, 1, 3),
         "Meet back Two>One. One addresses Two, role2. One turns from Three. Dip (II, I, III): kw2, kw1, kw3. "
         "Centre One, role1; from from2 to to3. Closing 1.");
    /* only meet.4-6 exists: Six then Four in the row falls back to it ({A} = 4) */
    SAYS(rd(s, 6, 4, 9),
         "Meet Four>Six. Four addresses Six, role6. Dip (VI, IIII, VIIII): kw6, kw4, kw9. Nine follows Four. "
         "Centre Four, role4; from from6 to to9. Closing 4.");
    /* centre gaze right with {C.role} covers (B,C); (A,B) back to back; couple on (B,C) */
    SAYS(rd(s, 1, 3, 4),
         "Couple Three+Four. Three addresses Four, role4. One turns from Three. Rising (I, III, IIII): kw1, kw3, kw4. "
         "Echo: crown. Centre Three, role3; from from1 to to4. Closing 3.");
    /* a couple out of order (5 before 2): the unordered section */
    SAYS(rd(s, 5, 2, 9),
         "Couple any Two+Five. Two looks at you. Dip (V, II, VIIII): kw5, kw2, kw9. Echo: book. "
         "Centre Two, role2; from from5 to to9. Closing 2.");
    /* at most one couple: (A,B) wins over (A,C) */
    SAYS(rd(s, 2, 5, 9),
         "Couple Two+Five. Five looks at you. Rising (II, V, VIIII): kw2, kw5, kw9. Echo: book. "
         "Centre Five, role5; from from2 to to9. Closing 5.");
    /* a shared tag without a gloss (animal) says nothing; three second-row keywords get the depth words */
    SAYS(rd(s, 11, 15, 16),
         "Fifteen looks at you. Rising (XI, XV, XVI): kw11 deep, kw15 deep, kw16 deep. "
         "Centre Fifteen, role15; from from11 to to16. Closing 15.");
    /* the first tag in the fixed order (water before path); a follow on (B,C) under a centre gaze on (A,B) */
    SAYS(rd(s, 0, 17, 9),
         "Seventeen addresses Zero, role0. Rising (0, XVII, VIIII): kw0, kw17 deep, kw9. "
         "Nine follows Seventeen. Echo: water. Centre Seventeen, role17; from from0 to to9. Closing 17.");
    /* kin.same (degree 3 in both rows), plateau */
    SAYS(rd(s, 3, 13, 2),
         "Thirteen addresses Three, role3. Three~Thirteen. Plateau (III, XIII, II): kw3, kw13 deep, kw2. "
         "Centre Thirteen, role13; from from3 to to2. Closing 13.");
    /* Le Mat and Le Monde in the row: their couple in order, and no kinship for the couple's pair */
    SAYS(rd(s, 0, 21, 6),
         "Couple Zero+World. World looks at you. Peak (0, XXI, VI): kw0, kw21, kw6. "
         "Centre World, role21; from from0 to to6. Closing 21.");
}

/* v3 findings over reader-synth3.txt (the synthetic table plus every v3 section: couple.4-3 besides couple.3-4,
 * kin.sum21.1-20, kin.same.3-13, succ.12-13 / 13-12 / 10-1, step.*, place.*, hsum*, row.*, short.*; srole lines on
 * even cards). n22 = the card index, Le Mat 22. */
static void test_v3_findings(void)
{
    orr_bundle_t *s = bundle("synth3");
    CHECK(s != NULL);
    if (!s) return;
    char sec[400];
    /* couple in the row's order (4 before 3), hidden sum 16, open to the left (Four looks left) */
    SAYS(rd(s, 4, 3, 9),
         "Couple back Four>Three. Three addresses Nine, role9. Four turns from Three. Dip (IIII, III, VIIII): kw4, kw3, kw9. "
         "Hidden Sixteen. Open left. Echo: crown. Centre Three, role3; from from4 to to9. Closing 3.");
    orr_sections(s, sec, sizeof sec);
    SAYS(sec, "couple.4-3,gaze.center.right,gaze.back,arc.dip,hsum,row.open.left,echo,positions,closing");
    /* one degree up (Five, Six); 1 + 5 + 6 = 12 */
    SAYS(rd(s, 1, 5, 6),
         "Five looks at you. Up Five>Six. Rising (I, V, VI): kw1, kw5, kw6. Hidden Twelve. Open left. "
         "Centre Five, role5; from from1 to to6. Closing 5.");
    /* the specific kinship of 1 and 20 ({A} = 1); 10 then 1: the restart; 20 + 1 + 6 = 27 -> 9; open to the right */
    SAYS(rd(s, 20, 1, 6),
         "One addresses Twenty, role20. One turns from Six. Kin21 One/Twenty. Restart Twenty>One. "
         "Dip (XX, I, VI): kw20 deep, kw1, kw6. Hidden Nine. Open right. Echo: angel. "
         "Centre One, role1; from from20 to to6. Closing 1.");
    /* the specific same-degree kinship (3, 13); 13 + 5 + 3 = 21: Le Monde hidden */
    SAYS(rd(s, 13, 5, 3),
         "Five looks at you. Same Three/Thirteen. Plateau (XIII, V, III): kw13 deep, kw5, kw3. Hidden World. Open left. "
         "Centre Five, role5; from from13 to to3. Closing 5.");
    /* successions in both orders (their pair takes no step); 12 + 13 + 6 = 31 -> 4 */
    SAYS(rd(s, 12, 13, 6),
         "Thirteen addresses Twelve, role12. Thirteen turns from Six. Succ Twelve>Thirteen. "
         "Rising (XII, XIII, VI): kw12 deep, kw13 deep, kw6. Hidden Four. Open right. "
         "Centre Thirteen, role13; from from12 to to6. Closing 13.");
    SAYS(rd(s, 13, 12, 6),
         "Twelve looks at you. Succ back Thirteen>Twelve. Dip (XIII, XII, VI): kw13 deep, kw12 deep, kw6. Hidden Four. "
         "Open left. Centre Twelve, role12; from from13 to to6. Closing 12.");
    /* a step down; the couple of Two and Five out of order (5 before 2): unordered */
    SAYS(rd(s, 6, 5, 2),
         "Couple any Two+Five. Five looks at you. Down Six>Five. Falling (VI, V, II): kw6, kw5, kw2. Hidden Thirteen. "
         "Echo: book. Centre Five, role5; from from6 to to2. Closing 5.");
    /* placements: the Wheel first / later, the World first / last (and the hidden sum drawn: 21 + 5 + 6 = 32 -> 5),
     * Le Mat before the card on his right (in A, in B) and after B (in C) */
    CHECK(strstr(rd(s, 10, 5, 6), " Wheel first Ten. Hidden World. ") != NULL);
    CHECK(strstr(rd(s, 5, 10, 6), " Wheel later Ten. Hidden World. ") != NULL);
    CHECK(strstr(rd(s, 21, 5, 6), " World first World. Hidden drawn Five. Open right. ") != NULL);
    CHECK(strstr(rd(s, 5, 6, 21), " World last World. Hidden drawn Five. Centre ") != NULL);
    CHECK(strstr(rd(s, 0, 5, 6), " Fool before Five. Hidden drawn Six. ") != NULL);
    CHECK(strstr(rd(s, 5, 0, 6), " Fool before Six. Hidden drawn Six. ") != NULL);
    CHECK(strstr(rd(s, 5, 6, 0), " Fool after Six. Hidden drawn Six. ") != NULL);
    /* Le Mat beside Le Monde: their couple (in order) and no placement; 22 + 21 + 6 = 49 -> 13 */
    SAYS(rd(s, 0, 21, 6),
         "Couple Zero+World. World looks at you. Peak (0, XXI, VI): kw0, kw21, kw6. Hidden Thirteen. Open right. "
         "Centre World, role21; from from0 to to6. Closing 21.");
    /* 2 + 8 + 12 = 22: Le Mat hidden */
    SAYS(rd(s, 2, 8, 12),
         "Eight addresses Two, role2. Two~Twelve. Plateau (II, VIII, XII): kw2, kw8, kw12 deep. Hidden Zero. "
         "Centre Eight, role8; from from2 to to12. Closing 8.");
    CHECK(strstr(rd(s, 3, 2, 4), " Closed. ") != NULL);   /* Three right, Four left */
    /* the old question and question-sum sections of a bundle are ignored (§5f.6) */
    mk_t m = { 0 };
    static const char txt[] = "[question]\nQ {q.name}\n[qsum.three]\nQsum\n[card.0.name]\nN0\n[card.1.name]\nN1\n"
                              "[card.1.closing]\nEnd.\n[card.2.name]\nN2\n";
    orr_bundle_t *b = mk_len(&m, txt, sizeof txt - 1);
    SAYS(rd(b, 0, 1, 2), "End.");
    mk_free(&m);
}

/* Slot of a written section (sentence mode), for the budget invariant. */
static int slot_of(const char *sec)
{
    static const struct { const char *pre; int slot; } m[] = {
        { "couple.", 1 }, { "meet.", 3 }, { "gaze.center.", 4 }, { "gaze.front", 4 },
        { "gaze.facing", 5 }, { "gaze.back", 5 }, { "kin.", 7 }, { "succ.", 8 }, { "step.", 9 }, { "arc.", 10 },
        { "place.", 11 }, { "hsum", 12 }, { "row.", 13 }, { "gaze.follow", 14 }, { "echo", 15 }, { "positions", 16 },
        { "closing", 17 },
    };
    for (size_t i = 0; i < sizeof m / sizeof m[0]; i++) {
        if (!strncmp(sec, m[i].pre, strlen(m[i].pre))) return m[i].slot;
    }
    return -1;
}

/* §5f.7 the lean screens over reader-synth3.txt: [short.card] has two variants ("{X.num} {X.name}: {X.srole}." and
 * "{X.name} ({X.num}), {X.srole}."), one chosen per row with "-1,A,B,C,short.card" for all three cards; even cards have
 * an srole line, odd ones fall back to the role. */
static void short_line(char *dst, size_t cap, const char *key, int card, const char *name, const char *num)
{
    char h[96], srole[24];
    snprintf(h, sizeof h, "%sshort.card", key);
    if (card % 2 == 0) snprintf(srole, sizeof srole, "srole%d", card);
    else snprintf(srole, sizeof srole, "role%d", card);
    if (fnv(h) % 2 == 0) snprintf(dst, cap, "%s %s: %s.", num, name, srole);
    else snprintf(dst, cap, "%s (%s), %s.", name, num, srole);
}

static size_t s_fit_max;
static bool fit_upto(void *ctx, const char *t, size_t n)
{
    (void)ctx;
    return orr_chars(t, n) <= s_fit_max;
}

static void test_lean(void)
{
    orr_bundle_t *s3 = bundle("synth3");
    CHECK(s3 != NULL);
    if (!s3) return;
    static char o[ORR_LEAN_SCREENS][ORR_OUT_MIN];
    char *const out[ORR_LEAN_SCREENS] = { o[0], o[1], o[2], o[3], o[4] };
    const size_t caps[ORR_LEAN_SCREENS] = { ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN };
    /* by card, by position, by the numbers (the arc), together (the couple), and (the centre gaze + B's closing) */
    CHECK_EQ(orr_compose_lean(s3, 4, 3, 9, out, caps, NULL, NULL), ORR_LEAN_SCREENS);
    char a[64], b2[64], c[64], want[256];
    short_line(a, sizeof a, "-1,4,3,9,", 4, "Four", "IIII");
    short_line(b2, sizeof b2, "-1,4,3,9,", 3, "Three", "III");
    short_line(c, sizeof c, "-1,4,3,9,", 9, "Nine", "VIIII");
    snprintf(want, sizeof want, "%s %s %s", a, b2, c);
    SAYS(o[0], want);
    SAYS(o[1], "From from4, at the centre Three, role3, towards to9.");
    SAYS(o[2], "Dip (IIII, III, VIIII): kw4, kw3, kw9.");
    SAYS(o[3], "Couple back Four>Three.");
    SAYS(o[4], "Three addresses Nine, role9. Closing 3.");
    /* one variant per row (uniform punctuation), both variants over a few rows */
    int v0 = 0, v1 = 0;
    for (int A = 0; A < 22; A += 2) {
        if (A == 5 || A == 6) continue;
        CHECK_EQ(orr_compose_lean(s3, A, 5, 6, out, caps, NULL, NULL), ORR_LEAN_SCREENS);
        int p0 = 0, p1 = 0;
        for (const char *p = o[0]; *p; p++) {
            p1 += *p == '(';
            p0 += *p == ':';
        }
        CHECK((p0 == 3 && p1 == 0) || (p0 == 0 && p1 == 3));
        v0 += p0 > 0;
        v1 += p1 > 0;
    }
    CHECK(v0 > 0 && v1 > 0);
    /* together and and skip gaze.front, the arc, follow and echo: Five looks out, so the step, then the hidden sum */
    CHECK_EQ(orr_compose_lean(s3, 1, 5, 6, out, caps, NULL, NULL), ORR_LEAN_SCREENS);
    SAYS(o[2], "Rising (I, V, VI): kw1, kw5, kw6.");
    SAYS(o[3], "Up Five>Six.");
    SAYS(o[4], "Hidden Twelve. Closing 5.");
    /* one finding only: and = the closing alone */
    CHECK_EQ(orr_compose_lean(s3, 11, 15, 19, out, caps, NULL, NULL), ORR_LEAN_SCREENS);
    SAYS(o[3], "Hidden Nine.");
    SAYS(o[4], "Closing 15.");
    /* the page test decides and: both, the finding alone, the closing alone */
    s_fit_max = 100;
    orr_compose_lean(s3, 4, 3, 9, out, caps, fit_upto, NULL);
    SAYS(o[4], "Three addresses Nine, role9. Closing 3.");
    s_fit_max = 30;
    orr_compose_lean(s3, 4, 3, 9, out, caps, fit_upto, NULL);
    SAYS(o[4], "Three addresses Nine, role9.");
    s_fit_max = 20;
    orr_compose_lean(s3, 4, 3, 9, out, caps, fit_upto, NULL);
    SAYS(o[4], "Closing 3.");
    SAYS(o[3], "Couple back Four>Three.");   /* together is not page-tested */
    /* long findings (long bundle, ~430 B): together keeps it, and falls back to the closing */
    orr_bundle_t *lg = bundle("long");
    CHECK_EQ(orr_compose_lean(lg, 4, 3, 9, out, caps, NULL, NULL), ORR_LEAN_SCREENS);
    CHECK(strncmp(o[3], "Couple back Four>Three and so on", 32) == 0);
    SAYS(o[4], "Closing 3.");
    /* no finding at all: together empty, and the closing; no [short.positions]: by position empty */
    static const char txt[] =
        "[short.card]\n{X.name}.\n"
        "[card.0.name]\nN0\n[card.1.name]\nN1\n[card.2.name]\nN2\n[card.2.closing]\nEnd 2.\n[card.3.name]\nN3\n";
    mk_t m = { 0 };
    orr_bundle_t *mb = mk_len(&m, txt, sizeof txt - 1);
    CHECK_EQ(orr_compose_lean(mb, 1, 2, 3, out, caps, NULL, NULL), ORR_LEAN_SCREENS);
    SAYS(o[0], "N1. N2. N3.");
    SAYS(o[1], "");
    SAYS(o[2], "");
    SAYS(o[3], "");
    SAYS(o[4], "End 2.");
    mk_free(&m);
    /* a bundle without the short sections: by card and by position empty, the rest as ever */
    orr_bundle_t *sy = bundle("synth");
    CHECK_EQ(orr_compose_lean(sy, 4, 3, 9, out, caps, NULL, NULL), ORR_LEAN_SCREENS);
    CHECK(!o[0][0] && !o[1][0] && o[2][0] && o[4][0]);
    /* bad arguments; the full paragraph is unaffected by a lean compose in between */
    CHECK_EQ(orr_compose_lean(s3, 4, 3, 77, out, caps, NULL, NULL), -1);
    CHECK_EQ(orr_compose_lean(NULL, 4, 3, 9, out, caps, NULL, NULL), -1);
    const size_t small[ORR_LEAN_SCREENS] = { 1, 10, 10, 10, 10 };
    CHECK_EQ(orr_compose_lean(s3, 4, 3, 9, out, small, NULL, NULL), -1);
    char full1[ORR_OUT_MIN], full2[ORR_OUT_MIN];
    orr_compose(s3, -1, 4, 3, 9, full1, sizeof full1);
    orr_compose_lean(s3, 4, 3, 9, out, caps, NULL, NULL);
    orr_compose(s3, -1, 4, 3, 9, full2, sizeof full2);
    SAYS(full2, full1);
    /* small caps: cut at a UTF-8 boundary, never more than cap - 1 bytes */
    const size_t tiny[ORR_LEAN_SCREENS] = { 12, 12, 12, 12, 12 };
    char t[ORR_LEAN_SCREENS][12];
    char *const to[ORR_LEAN_SCREENS] = { t[0], t[1], t[2], t[3], t[4] };
    CHECK_EQ(orr_compose_lean(s3, 4, 3, 9, to, tiny, NULL, NULL), ORR_LEAN_SCREENS);
    for (int k = 0; k < ORR_LEAN_SCREENS; k++) CHECK(strlen(t[k]) <= 11);
    /* the brief lines are a card field */
    static const char tb[] = "[card.0.name]\nN0\n[card.0.brief]\n0 N0: nothing yet.\n";
    mb = mk_len(&m, tb, sizeof tb - 1);
    size_t bl;
    const char *br = orr_card_field(mb, 0, ORR_F_BRIEF, &bl);
    CHECK(bl == 18 && !memcmp(br, "0 N0: nothing yet.", 18));
    mk_free(&m);
    CHECK_EQ(orr_chars("\xC3\xA9t\xC3\xA9", 5), 3);
}

/* Without centre-gaze sections (the first real bundles) both pairs read: facing, back, follow in both directions. */
static void test_pairs_without_centre(void)
{
    mk_t m = { 0 };
    orr_bundle_t *b = mk_synth(&m, "[gaze.facing]\n{A.name} faces {B.name}.\n[gaze.back]\n{A.name} turns from {B.name}.\n"
                                   "[gaze.follow]\n{A.name} follows {B.name}.\n[gaze.front]\n{B.name} looks at you.\n");
    CHECK(b != NULL);
    if (!b) return;
    SAYS(rd(b, 3, 4, 6), "Three faces Four. Four turns from Six. Closing 4.");   /* r l r */
    SAYS(rd(b, 1, 3, 4), "One turns from Three. Three faces Four. Closing 3.");  /* l r l */
    SAYS(rd(b, 6, 7, 3), "Six follows Seven. Closing 7.");      /* r r r: one follow, A behind */
    SAYS(rd(b, 8, 9, 1), "Nine follows Eight. Closing 9.");     /* l l l: B behind A */
    SAYS(rd(b, 6, 3, 4), "Three faces Four. Six follows Three. Closing 3.");  /* r r l */
    SAYS(rd(b, 3, 2, 4), "Two looks at you. Closing 2.");       /* a front card pairs with nobody */
    mk_free(&m);
}

/* Kinship: a sum to 21 anywhere in the scan beats an earlier pair of the same degree. */
static void test_kinship(void)
{
    mk_t m = { 0 };
    orr_bundle_t *b = mk_synth(&m, "[kin.sum21]\nS {A.name} {B.name}.\n[kin.same]\nM {A.name} {B.name}.\n");
    CHECK(b != NULL);
    if (!b) return;
    SAYS(rd(b, 3, 13, 18), "S Three Eighteen. Closing 13.");   /* (3,13) same, (3,18) = 21 */
    SAYS(rd(b, 3, 5, 13), "M Three Thirteen. Closing 5.");
    SAYS(rd(b, 1, 2, 20), "S One Twenty. Closing 2.");         /* (A,C) */
    SAYS(rd(b, 0, 5, 21), "S Zero World. Closing 5.");        /* 0 + 21 */
    SAYS(rd(b, 1, 2, 3), "Closing 2.");                        /* nothing */
    mk_free(&m);
}

/* Every arc shape on its own small table: Le Mat degree 0, Le Monde counted as 11, depth after second-row keywords. */
static void test_arc_shapes(void)
{
    static const char txt[] =
        "[arc.rising]\nrising {A.kw}/{B.kw}/{C.kw} ({A.num} {B.num} {C.num})\n[arc.falling]\nfalling {A.kw}/{B.kw}/{C.kw}\n"
        "[arc.peak]\npeak {B.kw}\n[arc.dip]\ndip {B.kw}\n[arc.plateau]\nplateau\n[arc.still]\nstill {A.kw}/{B.kw}/{C.kw}\n"
        "[depth]\nin depth\n"
        "[card.0.name]\nMat\n[card.0.kw]\nk0\n[card.0.num]\n0\n[card.0.degree]\n0\n[card.0.row]\n0\n"
        "[card.1.name]\nA\n[card.1.kw]\nk1\n[card.1.num]\nI\n[card.1.degree]\n1\n[card.1.row]\n1\n"
        "[card.2.name]\nB\n[card.2.kw]\nk2\n[card.2.num]\nII\n[card.2.degree]\n2\n[card.2.row]\n1\n"
        "[card.3.name]\nC\n[card.3.kw]\nk3\n[card.3.num]\nXIII\n[card.3.degree]\n3\n[card.3.row]\n2\n"
        "[card.4.name]\nD\n[card.4.kw]\nk4\n[card.4.num]\nXI\n[card.4.degree]\n1\n[card.4.row]\n2\n"
        "[card.5.name]\nE\n[card.5.kw]\nk5\n[card.5.num]\nI\n[card.5.degree]\n1\n[card.5.row]\n1\n"
        "[card.6.name]\nW\n[card.6.kw]\nk6\n[card.6.num]\nXXI\n[card.6.degree]\n21\n[card.6.row]\n3\n"
        "[card.7.name]\nQ\n[card.7.kw]\nk7\n[card.7.num]\nX\n[card.7.degree]\n10\n[card.7.row]\n1\n";
    mk_t m = { 0 };
    orr_bundle_t *b = mk_len(&m, txt, sizeof txt - 1);
    CHECK(b != NULL);
    if (!b) return;
    SAYS(rd(b, 1, 2, 3), "rising k1/k2/k3 in depth (I II XIII)");
    SAYS(rd(b, 3, 2, 0), "falling k3 in depth/k2/k0");
    SAYS(rd(b, 0, 2, 1), "peak k2");
    SAYS(rd(b, 2, 0, 3), "dip k0");
    SAYS(rd(b, 1, 2, 5), "plateau");                    /* degrees 1 2 1 */
    SAYS(rd(b, 1, 4, 5), "still k1/k4 in depth/k5");   /* degree 1 three times */
    SAYS(rd(b, 7, 6, 2), "peak k6");                    /* Le Monde (11) above X */
    SAYS(rd(b, 0, 2, 6), "rising k0/k2/k6 (0 II XXI)");
    mk_free(&m);
}

/* Variants: fnv1a("-1,A,B,C,<section>") mod the number of valid lines, in bundle order (invalid lines do not count). */
static void test_variants(void)
{
    static const char txt[] =
        "[positions]\nv0 {B.name}\nv1 {B.name}\n{B.bad} not counted\nv2 {B.name}\n[positions]\nv3 {B.name}\n"
        "[couple.0-2.any]\nc0\nc1\nc2\nc3\nc4\nc5\nc6\n"
        "[card.0.name]\nN0\n[card.1.name]\nN1\n[card.2.name]\nN2\n[card.3.name]\nN3\n";
    mk_t m = { 0 };
    orr_bundle_t *b = mk_len(&m, txt, sizeof txt - 1);
    CHECK(b != NULL);
    if (!b) return;
    int seen[4] = { 0 }, cseen[7] = { 0 };
    for (int A = 0; A < 4; A++)
        for (int B = 0; B < 4; B++)
            for (int C = 0; C < 4; C++) {
                char key[64], want[32];
                snprintf(key, sizeof key, "-1,%d,%d,%d,positions", A, B, C);
                const unsigned v = fnv(key) % 4;
                seen[v]++;
                snprintf(want, sizeof want, "v%u N%d", v, B);
                const char *got = rd(b, A, B, C);
                const bool couple = (A == 0 && B == 2) || (A == 2 && B == 0) || (B == 0 && C == 2) || (B == 2 && C == 0) ||
                                    (A == 0 && C == 2) || (A == 2 && C == 0);
                if (couple) {
                    snprintf(key, sizeof key, "-1,%d,%d,%d,couple.0-2.any", A, B, C);
                    const unsigned cv = fnv(key) % 7;
                    char cw[64];
                    snprintf(cw, sizeof cw, "c%u %s", cv, want);
                    CHECK(strcmp(got, cw) == 0);
                    cseen[cv]++;
                } else {
                    CHECK(strcmp(got, want) == 0);
                }
            }
    for (int i = 0; i < 4; i++) CHECK(seen[i] > 0);
    int cs = 0;
    for (int i = 0; i < 7; i++) cs += cseen[i] > 0;
    CHECK(cs >= 4);
    /* the documented example keys */
    CHECK_EQ(orr_fnv1a(orr_fnv1a(2166136261u, "-1,2,11,19,", 11), "arc.dip", 7), fnv("-1,2,11,19,arc.dip"));
    mk_free(&m);
}

/* The synthetic phrases with `pad` bytes inserted before the last character of every finding variant (and qpad bytes
 * into the [positions] variant). */
static char *padded_synth(size_t pad, size_t qpad, size_t *len)
{
    const bundle_t *s = bundle_file("synth");
    char *o = malloc(s->len * 2 + 200 * (pad + 2) + qpad), *d = o;
    const char *p = s->text, *e = s->text + s->len;
    bool finding = false, question = false;
    while (p < e) {
        const char *nl = memchr(p, '\n', (size_t)(e - p));
        const size_t n = nl ? (size_t)(nl - p) : (size_t)(e - p);
        if (n && p[0] == '[') {
            finding = !strncmp(p, "[couple.", 8) || !strncmp(p, "[meet.", 6) || !strncmp(p, "[gaze.", 6) ||
                      !strncmp(p, "[kin.", 5) || !strncmp(p, "[arc.", 5) || !strncmp(p, "[echo]", 6);
            question = !strncmp(p, "[positions]", 11);
            memcpy(d, p, n);
            d += n;
        } else if ((finding || (question && qpad)) && n > 1 && memchr(p, '{', n)) {
            const size_t k = finding ? pad : qpad;
            const bool brace = p[n - 1] == '}';   /* a template ending on a placeholder: pad after it */
            memcpy(d, p, brace ? n : n - 1);
            d += brace ? n : n - 1;
            *d++ = ' ';
            memset(d, 'x', k);
            d += k;
            if (!brace) *d++ = p[n - 1];
        } else {
            memcpy(d, p, n);
            d += n;
        }
        *d++ = '\n';
        p = nl ? nl + 1 : e;
    }
    *len = (size_t)(d - o);
    return o;
}

/* The budget, padding every finding more and more: the dropped set always grows along the documented order. */
static void test_budget_order(void)
{
    static const unsigned order[] = { ORR_DROP_ECHO, ORR_DROP_FOLLOW, ORR_DROP_NUMERALS, ORR_DROP_ARC, ORR_DROP_KIN,
                                      ORR_DROP_CENTER, ORR_DROP_COUPLE };
    const size_t norder = sizeof order / sizeof order[0];
    mk_t m = { 0 };
    size_t reached = 0;
    int numerals_only = 0;
    for (int sweep = 0; sweep < 2; sweep++) {
        const size_t qpad = sweep ? 450 : 0;
        for (size_t pad = 0; pad <= 440; pad += 4) {   /* (longer arc lines would pass ORR_LINE_MAX) */
            size_t len;
            char *t = padded_synth(pad, qpad, &len);
            orr_bundle_t *b = mk_len(&m, t, len);
            free(t);
            CHECK(b != NULL);
            if (!b) break;
            const char *got = rd(b, 3, 4, 17);
            const size_t n = strlen(got);
            CHECK(n <= ORR_TEXT_MAX && utf8_valid(got, n));
            const unsigned d = orr_dropped(b);
            size_t k = 0;
            unsigned prefix = 0;
            while (k < norder && (d & order[k])) prefix |= order[k++];
            CHECK_EQ(d, prefix);   /* a prefix of the order, nothing else (never the cut) */
            if (k > reached) reached = k;
            /* what is not dropped is there */
            CHECK(!(d & ORR_DROP_ECHO) == (strstr(got, "Echo: crown") != NULL));
            CHECK(!(d & ORR_DROP_FOLLOW) == (strstr(got, "Seventeen follows Four") != NULL));
            CHECK(!(d & ORR_DROP_ARC) == (strstr(got, "Rising") != NULL));
            CHECK(!(d & (ORR_DROP_NUMERALS | ORR_DROP_ARC)) == (strstr(got, "(III, IIII, XVII)") != NULL));
            CHECK(!(d & ORR_DROP_KIN) == (strstr(got, "Four+Seventeen=21") != NULL));
            CHECK(!(d & ORR_DROP_CENTER) == (strstr(got, "Four addresses Three") != NULL));
            CHECK(!(d & ORR_DROP_COUPLE) == (strstr(got, "Couple Three+Four") != NULL));
            CHECK(strstr(got, "Centre Four, role4; from from3 to to17") != NULL);
            CHECK(strstr(got, "Closing 4.") != NULL);
            if ((d & ORR_DROP_NUMERALS) && !(d & ORR_DROP_ARC)) {
                CHECK(strstr(got, "Rising: kw3, kw4, kw17 deep") != NULL);
                numerals_only++;
            }
        }
    }
    CHECK_EQ(reached, norder);   /* the sweeps went through every step */
    CHECK(numerals_only > 0);    /* and the numerals alone were enough at some length */
    /* encounter and facing / back drop in their turn too: 3 before 4, and of the two 4s the centre (written later) */
    size_t len;
    char *t = padded_synth(440, 0, &len);
    orr_bundle_t *b = mk_len(&m, t, len);
    free(t);
    rd(b, 2, 1, 3);   /* meet (4), centre (4), back (3), dip (2) */
    CHECK_EQ(orr_dropped(b), ORR_DROP_NUMERALS | ORR_DROP_ARC | ORR_DROP_FB1 | ORR_DROP_CENTER);
    CHECK(strstr(s_out, "Meet back Two>One") != NULL);
    CHECK(strstr(s_out, "One addresses") == NULL);
    mk_free(&m);
    /* v3 (reader-synth3.txt padded): whatever is dropped, every present finding that is weaker, or as strong and written
     * later, is dropped too; numerals go only after the strength-1 findings */
    static const uint8_t strength[18] = { 0, 5, 5, 4, 4, 3, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 0, 0 };
    static const int rows[3][3] = { { 4, 3, 9 }, { 20, 1, 6 }, { 12, 13, 6 } };
    int steps_seen = 0;
    for (int r = 0; r < 3; r++) {
        const bundle_t *s3 = bundle_file("synth3");
        mk_t m3 = { 0 };
        orr_bundle_t *b3 = mk_len(&m3, s3->text, s3->len);
        rd(b3, rows[r][0], rows[r][1], rows[r][2]);
        char present[400];
        orr_sections(b3, present, sizeof present);
        unsigned pmask = 0;
        bool fb_seen = false;
        for (char *p = present; *p;) {
            char *c = strchr(p, ',');
            if (c) *c = '\0';
            int sl = slot_of(p);
            if (sl == 5 && fb_seen) sl = 6;
            if (sl == 5) fb_seen = true;
            if (sl > 0 && sl < 16) pmask |= 1u << sl;
            p = c ? c + 1 : p + strlen(p);
        }
        for (size_t pad = 0; pad <= 440; pad += 8) {
            size_t len;
            const bundle_t *keep = bundle_file("synth");
            (void)keep;
            /* pad synth3's findings */
            char *o = malloc(s3->len * 2 + 400 * (pad + 2)), *d = o;
            const char *p = s3->text, *e = s3->text + s3->len;
            bool finding = false;
            while (p < e) {
                const char *nl = memchr(p, '\n', (size_t)(e - p));
                const size_t n = nl ? (size_t)(nl - p) : (size_t)(e - p);
                if (n && p[0] == '[') {
                    finding = strncmp(p, "[positions]", 11) && strncmp(p, "[card.", 6) &&
                              strncmp(p, "[tag.", 5) && strncmp(p, "[depth]", 7);
                    memcpy(d, p, n);
                    d += n;
                } else if (finding && n > 1 && p[n - 1] == '.') {
                    memcpy(d, p, n - 1);
                    d += n - 1;
                    *d++ = ' ';
                    memset(d, 'x', pad);
                    d += pad;
                    *d++ = '.';
                } else {
                    memcpy(d, p, n);
                    d += n;
                }
                *d++ = '\n';
                p = nl ? nl + 1 : e;
            }
            len = (size_t)(d - o);
            orr_bundle_t *b = mk_len(&m3, o, len);
            free(o);
            const char *got = rd(b, rows[r][0], rows[r][1], rows[r][2]);
            CHECK(strlen(got) <= ORR_TEXT_MAX);
            const unsigned dm = orr_dropped(b);
            CHECK(!(dm & ORR_DROP_CUT));
            CHECK((dm & ~(pmask | ORR_DROP_NUMERALS)) == 0);
            for (int sl = 1; sl < 16; sl++) {
                if (!(dm & (1u << sl))) continue;
                for (int t = 1; t < 16; t++) {
                    if (!(pmask & (1u << t))) continue;
                    if (strength[t] < strength[sl] || (strength[t] == strength[sl] && t > sl)) CHECK(dm & (1u << t));
                }
            }
            if (dm & ORR_DROP_NUMERALS) {
                for (int t = 13; t < 16; t++) if (pmask & (1u << t)) CHECK(dm & (1u << t));
            }
            int k = 0;
            for (unsigned x = dm; x; x &= x - 1) k++;
            if (k > steps_seen) steps_seen = k;
        }
        mk_free(&m3);
    }
    CHECK(steps_seen >= 6);
}

/* The last resort: positions + closing alone over 900 bytes -> cut at a space (or a UTF-8 boundary) + "…". */
static void test_final_cut(void)
{
    char txt[4096];
    char words[500], accents[501];
    memset(words, 0, sizeof words);
    for (int i = 0; i < 49; i++) memcpy(words + i * 10, "aaaa bbbb ", 10);
    words[489] = '\0';   /* no trailing space */
    for (int i = 0; i < 250; i++) memcpy(accents + i * 2, "\xC3\xA9", 2);
    accents[500] = '\0';
    snprintf(txt, sizeof txt, "[positions]\n%s\n[card.0.name]\nZ\n[card.1.name]\nO\n[card.1.closing]\n%s\n"
             "[card.2.name]\nT\n", words, words);
    mk_t m = { 0 };
    orr_bundle_t *b = mk_len(&m, txt, strlen(txt));
    const char *got = rd(b, 0, 1, 2);
    size_t n = strlen(got);
    CHECK(n <= ORR_TEXT_MAX && n >= ORR_TEXT_MAX - 12);
    CHECK(n >= 3 && memcmp(got + n - 3, "\xE2\x80\xA6", 3) == 0);
    CHECK(got[n - 4] != ' ');
    CHECK_EQ(orr_dropped(b), ORR_DROP_CUT);
    /* no space at all near the end: a UTF-8 boundary */
    snprintf(txt, sizeof txt, "[positions]\n%s\n[card.0.name]\nZ\n[card.1.name]\nO\n[card.1.closing]\n%s\n"
             "[card.2.name]\nT\n", accents, accents);
    b = mk_len(&m, txt, strlen(txt));
    got = rd(b, 0, 1, 2);
    n = strlen(got);
    CHECK(n <= ORR_TEXT_MAX && utf8_valid(got, n));
    CHECK(n >= 3 && memcmp(got + n - 3, "\xE2\x80\xA6", 3) == 0);
    /* the cut point is the last space before byte 897 (positions and closing are joined by a space at byte 500) */
    CHECK_EQ(n, 500 + 3);
    /* one 1000-byte sentence without a space: cut to 960 bytes, then to 896 (a UTF-8 boundary) + "…" */
    snprintf(txt, sizeof txt, "[positions]\n{B.role}{B.role}\n[card.0.name]\nZ\n[card.1.name]\nO\n[card.1.role]\n%s\n"
             "[card.2.name]\nT\n", accents);
    b = mk_len(&m, txt, strlen(txt));
    got = rd(b, 0, 1, 2);
    n = strlen(got);
    CHECK_EQ(n, 896 + 3);
    CHECK(utf8_valid(got, n));
    mk_free(&m);
}

static char *app(char *d, const char *s)
{
    const size_t n = strlen(s);
    memcpy(d, s, n);
    return d + n;
}

/* Malformed lines change nothing: the FR bundle with junk everywhere (blank lines, CRLF endings, bad placeholders, an
 * unclosed brace, a > 512-byte line, invalid UTF-8, a control byte, unknown sections, text before the first header,
 * repeated one-line sections, a card past the deck) reads a few hundred rows exactly like the clean one. */
static void test_malformed_ignored(void)
{
    const bundle_t *fr = bundle_file("fr");
    CHECK(fr != NULL);
    if (!fr) return;
    char *junk = malloc(fr->len * 4 + 4096), *d = junk;
    d = app(d, "texte avant le premier en-tête\n[inconnu]\nune ligne d'une section inconnue\n");
    int line = 0;
    const char *p = fr->text, *e = fr->text + fr->len;
    while (p < e) {
        const char *nl = memchr(p, '\n', (size_t)(e - p));
        const size_t n = nl ? (size_t)(nl - p) : (size_t)(e - p);
        const bool header = n >= 2 && p[0] == '[';
        memcpy(d, p, n);
        d += n;
        if (line % 3 == 0) *d++ = '\r';   /* CRLF on some lines */
        *d++ = '\n';
        /* junk lines after phrase / tag / depth headers; one-line sections (tags, depth) take any first line as text,
         * so they only get the kinds that are ignored everywhere (blank, too long, bad UTF-8, control byte) */
        const bool one_line = header && (!strncmp(p, "[tag.", 5) || !strncmp(p, "[depth]", 7));
        const int kind = line % 7;
        if (header && strncmp(p, "[card.", 6) != 0 && (!one_line || kind == 0 || kind == 3 || kind == 4 || kind == 5)) {
            switch (kind) {
            case 0: d = app(d, "\n   \t \n"); break;
            case 1: d = app(d, "{A.bogus} n'est pas une variante\n"); break;
            case 2: d = app(d, "{q.name sans fin\n"); break;
            case 3: memset(d, 'x', 600); d += 600; *d++ = '\n'; break;
            case 4: d = app(d, "\xC3\x28 pas de l'UTF-8 {A.name}\n"); break;
            case 5: d = app(d, "un octet de contr\x01le {A.name}\n"); break;
            default: d = app(d, "{tag} {Z.kw}\n"); break;
            }
        }
        line++;
        p = nl ? nl + 1 : e;
    }
    d = app(d, "[card.3.name]\nUn autre nom\n[card.99.name]\nhors du jeu\n[tag.licorne]\nune corne\n"
                    "[depth]\nautre profondeur\n[tag.water]\nune autre eau\n[couple.40-1]\nhors d'ordre\n");
    const size_t jlen = (size_t)(d - junk);
    const size_t need = orr_arena_bytes(junk, jlen);
    void *ar = malloc(need);
    orr_bundle_t *b = orr_parse(junk, jlen, ar, need);
    CHECK(b != NULL);
    CHECK_EQ(orr_cards(b), 22);
    char out[ORR_OUT_MIN], want[ORR_OUT_MIN];
    int checked = 0;
    th_rng = 0xC0FFEEu;
    for (int i = 0; i < 400 && b; i++) {
        int c[3];
        do {
            for (int k = 0; k < 3; k++) c[k] = (int)(th_rand() % 22);
        } while (c[0] == c[1] || c[0] == c[2] || c[1] == c[2]);
        const int r1 = orr_compose(fr->b, -1, c[0], c[1], c[2], want, sizeof want);
        const int r2 = orr_compose(b, -1, c[0], c[1], c[2], out, sizeof out);
        CHECK(r1 > 0 && r1 == r2 && strcmp(out, want) == 0);
        if (!(r1 > 0 && r1 == r2 && strcmp(out, want) == 0) && th_failures < 3) fprintf(stderr, "  got  %s\n  want %s\n", out, want);
        checked++;
    }
    CHECK_EQ(checked, 400);
    free(ar);
    free(junk);
}

/* A phrase section without any valid line contributes nothing (and the others still read). */
static void test_empty_sections(void)
{
    static const char txt[] =
        "[gaze.facing]\n{q.nope}\n"
        "[arc.rising]\nUp ({A.num}) {A.kw}.\n"
        "[closing]\nnot a section\n"
        "[card.0.name]\nA\n[card.0.kw]\nfirst\n[card.0.num]\nI\n[card.0.degree]\n1\n[card.0.row]\n1\n[card.0.gaze]\nright\n"
        "[card.1.name]\nB\n[card.1.degree]\n2\n[card.1.row]\n1\n[card.1.gaze]\nleft\n[card.1.closing]\nB's end.\n"
        "[card.2.name]\nC\n[card.2.degree]\n3\n[card.2.row]\n1\n";
    char ar[32768], out[ORR_OUT_MIN];
    orr_bundle_t *b = orr_parse(txt, sizeof txt - 1, ar, sizeof ar);
    CHECK(b != NULL);
    if (!b) return;
    CHECK_EQ(orr_cards(b), 3);
    int r = orr_compose(b, -1, 0, 1, 2, out, sizeof out);
    CHECK(r > 0 && strcmp(out, "Up (I) first. B's end.") == 0);   /* facing (0 r, 1 l) has no valid line */
    r = orr_compose(b, -1, 1, 2, 0, out, sizeof out);               /* B = 2: no closing, no sentence: "" */
    CHECK_EQ(r, 0);
    CHECK_EQ(out[0], '\0');
}

/* Bad arguments. */
static void test_invalid(void)
{
    char out[ORR_OUT_MIN];
    orr_bundle_t *fr = bundle("fr"), *sy = bundle("synth");
    CHECK(fr && sy);
    if (!fr || !sy) return;
    CHECK_EQ(orr_compose(fr, -1, 2, 3, 4, out, ORR_OUT_MIN - 1), -1);   /* cap too small */
    CHECK_EQ(orr_compose(NULL, -1, 2, 3, 4, out, sizeof out), -1);
    CHECK_EQ(orr_compose(fr, -1, 2, 3, 4, NULL, sizeof out), -1);
    CHECK_EQ(orr_compose(fr, 1, 2, 3, 4, out, sizeof out), -1);           /* §5f.6: no question card */
    CHECK_EQ(orr_compose(fr, -1, 22, 3, 4, out, sizeof out), -1);         /* past the deck */
    CHECK_EQ(orr_compose(fr, -1, 2, 3, -1, out, sizeof out), -1);         /* A, B and C are needed */
    CHECK_EQ(out[0], '\0');
    CHECK_EQ(orr_compose(sy, -1, 2, 3, 77, out, sizeof out), -1);
    CHECK(orr_compose(fr, -1, 2, 3, 4, out, ORR_OUT_MIN) > 0);
    char sec[8];
    CHECK_EQ(orr_sections(NULL, sec, sizeof sec), 0);
    CHECK(orr_sections(fr, sec, sizeof sec) <= 7 && strlen(sec) < sizeof sec);
    CHECK_EQ(orr_dropped(NULL), 0);
    CHECK_EQ(orr_cards(NULL), 0);
    /* §5f.8 [prompt.armed]: its own first usable line; falls back to [prompt] when the bundle has none */
    size_t n1, n2;
    const char *pf = orr_prompt_armed(fr, &n2);
    CHECK(n2 == 14 && !memcmp(pf, "Secoue le jeu.", 14));
    CHECK(orr_prompt_armed(NULL, &n2)[0] == '\0' && n2 == 0);
    CHECK(orr_prompt_armed(sy, &n2)[0] == '\0' && n2 == 0);   /* neither line */
    /* §5f.9 [hint.*]: first usable line; "" when absent, unknown hint names ignored */
    CHECK(orr_hint(sy, ORR_HINT_NEXT, &n2)[0] == '\0' && n2 == 0);
    CHECK(orr_hint(NULL, ORR_HINT_NEXT, &n2)[0] == '\0' && n2 == 0);
    CHECK(orr_hint(fr, ORR_HINTS, &n2)[0] == '\0' && n2 == 0);
    {
        static const char hb[] = "[hint.next]\n\nsuite\nautre\n[hint.nope]\nx\n[hint.end]\nfin\n";
        const size_t need = orr_arena_bytes(hb, sizeof hb - 1);
        void *ar = malloc(need);
        orr_bundle_t *m = orr_parse(hb, sizeof hb - 1, ar, need);
        CHECK(m != NULL);
        if (m) {
            const char *x = orr_hint(m, ORR_HINT_NEXT, &n2);
            CHECK(n2 == 5 && !memcmp(x, "suite", 5));
            x = orr_hint(m, ORR_HINT_END, &n2);
            CHECK(n2 == 3 && !memcmp(x, "fin", 3));
            CHECK(orr_hint(m, ORR_HINT_BACK, &n2)[0] == '\0' && n2 == 0);
        }
        free(ar);
    }
    static const char mini[] = "[prompt.armed]\n\n  \nShake.\nSecond line ignored.\n[prompt]\nPress.\n";
    static const char only[] = "[prompt]\nPress.\n";
    const char *const texts[2] = { mini, only };
    const size_t lens[2] = { sizeof mini - 1, sizeof only - 1 };
    for (int k = 0; k < 2; k++) {
        const size_t need = orr_arena_bytes(texts[k], lens[k]);
        void *ar = malloc(need);
        orr_bundle_t *m = orr_parse(texts[k], lens[k], ar, need);
        CHECK(m != NULL);
        if (m) {
            const char *x = orr_prompt_armed(m, &n2), *y = orr_prompt(m, &n1);
            CHECK(n1 == 6 && !memcmp(y, "Press.", 6));
            CHECK(k == 0 ? (n2 == 6 && !memcmp(x, "Shake.", 6)) : (x == y && n2 == n1));
        }
        free(ar);
    }
}

/* Arena contract: exact size works at any alignment, one byte less does not; the bundles are indexed fully. */
static void test_arena(void)
{
    const bundle_t *src = bundle_file("fr");
    CHECK(src != NULL);
    if (!src) return;
    orr_bundle_t *fr = src->b;
    CHECK_EQ(orr_cards(fr), 22);
    size_t l;
    const char *name = orr_card_field(fr, 21, ORR_F_NAME, &l);
    CHECK(l == 8 && memcmp(name, "Le Monde", 8) == 0);
    const char *gz = orr_card_field(fr, 21, ORR_F_GAZE, &l);
    CHECK(l == 4 && memcmp(gz, "left", 4) == 0);
    orr_card_field(fr, 40, ORR_F_NAME, &l);
    CHECK_EQ(l, 0);
    const size_t need = orr_arena_bytes(src->text, src->len);
    CHECK(need >= 12160 && need < 32 * 1024);   /* PROTOCOL §5f.1: ~24.6 KB of working memory for the v3 bundles */
    printf("     arena for the %s bundle (%zu B): %zu B\n", src->name, src->len, need);
    char *raw = malloc(need + 16);
    char out1[ORR_OUT_MIN], out2[ORR_OUT_MIN];
    for (int a = 0; a < 8; a++) {
        CHECK(orr_parse(src->text, src->len, raw + a, need - 1) == NULL);
        orr_bundle_t *b = orr_parse(src->text, src->len, raw + a, need);
        CHECK(b != NULL);
        if (!b) continue;
        const int r1 = orr_compose(b, -1, 2, 11, 19, out1, sizeof out1);
        const int r2 = orr_compose(fr, -1, 2, 11, 19, out2, sizeof out2);
        CHECK(r1 > 0 && r1 == r2 && memcmp(out1, out2, (size_t)r1) == 0);
    }
    free(raw);
    CHECK(orr_parse(NULL, 0, out1, sizeof out1) == NULL);
    CHECK(orr_parse("x", 1, NULL, 100) == NULL);
    char ar[32768];
    orr_bundle_t *e = orr_parse("", 0, ar, sizeof ar);   /* an empty text parses (nothing to say about anything) */
    CHECK(e != NULL && orr_cards(e) == 0);
    CHECK_EQ(orr_compose(e, -1, 0, 1, 2, out1, sizeof out1), -1);
}

/* ---- shared fixtures: core/fixtures/tarot/cases.json and cases-short.json ------------------------------------- */

typedef struct { const char *bundle; int A, B, C; } row_t;

/* Fixed rows: the hand-checked synthetic ones, the long bundle's budget steps, a few real ones. */
static const row_t s_fixed[] = {
    { "synth", 3, 4, 17 },   { "synth", 1, 2, 3 },     { "synth", 2, 1, 3 },    { "synth", 6, 4, 9 },
    { "synth", 1, 3, 4 },    { "synth", 5, 2, 9 },     { "synth", 2, 5, 9 },    { "synth", 11, 15, 16 },
    { "synth", 0, 17, 9 },   { "synth", 3, 13, 2 },    { "synth", 0, 21, 6 },
    { "synth3", 4, 3, 9 },   { "synth3", 1, 5, 6 },    { "synth3", 20, 1, 6 },  { "synth3", 13, 5, 3 },
    { "synth3", 12, 13, 6 }, { "synth3", 13, 12, 6 },  { "synth3", 6, 5, 2 },   { "synth3", 10, 5, 6 },
    { "synth3", 5, 10, 6 },  { "synth3", 21, 5, 6 },   { "synth3", 5, 6, 21 },  { "synth3", 0, 5, 6 },
    { "synth3", 5, 6, 0 },   { "synth3", 0, 21, 6 },   { "synth3", 2, 8, 12 },  { "synth3", 3, 2, 4 },
    { "nocentre", 3, 4, 6 }, { "nocentre", 1, 3, 4 },  { "nocentre", 6, 3, 4 }, { "nocentre", 8, 9, 1 },
    { "long", 3, 4, 17 },    { "long", 2, 1, 3 },      { "long", 1, 2, 3 },     { "long", 0, 2, 6 },
    { "fr", 2, 11, 19 },     { "en", 2, 11, 19 },      { "fr", 1, 2, 3 },       { "en", 0, 11, 1 },
    { "fr", 0, 21, 10 },     { "en", 7, 17, 13 },      { "fr", 12, 13, 1 },
};

/* What the fixture must cover: sections (per bundle family) and budget steps. */
static const char *const s_need_real[] = {   /* a trailing "." = any section of that family */
    "arc.rising", "arc.falling", "arc.peak", "arc.dip", "arc.plateau", "gaze.back", "gaze.follow",
    "gaze.front", "gaze.center.left", "gaze.center.right", "couple.", "meet.", "kin.sum21.",
    "kin.same.", "succ.", "step.up", "step.down", "step.restart", "place.wheel.first", "place.wheel.later",
    "place.world.first", "place.world.last", "place.fool.before", "place.fool.after", "hsum", "hsum.drawn",
    "row.open.left", "row.open.right", "row.closed", "echo", "positions", "closing",
};
static const char *const s_need_synth[] = {
    "couple.3-4", "couple.4-3", "couple.0-21", "couple.2-5.any", "meet.1-2", "meet.2-1", "meet.4-6",
    "gaze.center.left", "gaze.center.right", "kin.sum21.1-20", "kin.same.3-13",
    "succ.12-13", "succ.13-12", "step.up", "step.down", "step.restart", "place.wheel.first", "place.wheel.later",
    "place.world.first", "place.world.last", "place.fool.before", "place.fool.after", "hsum", "hsum.drawn",
    "row.open.left", "row.open.right", "row.closed",
    "gaze.front", "gaze.follow", "gaze.back", "gaze.facing", "kin.sum21", "kin.same", "arc.rising", "arc.dip",
    "arc.plateau", "echo",
};
static const char *const s_need_drops[] = { "echo", "follow", "row", "numerals", "hsum", "place", "arc", "step", "succ",
                                            "kin", "facing1", "center" };

static bool has_section(const char *list, const char *name)
{
    const size_t n = strlen(name);
    const bool family = n && name[n - 1] == '.';
    for (const char *p = list; (p = strstr(p, name)) != NULL; p += n) {
        if ((p == list || p[-1] == ',') && (family || p[n] == ',' || p[n] == '\0')) return true;
    }
    return false;
}

static void json_str(FILE *f, const char *s)
{
    fputc('"', f);
    for (; *s; s++) {
        const unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') fprintf(f, "\\%c", c);
        else if (c == '\n') fputs("\\n", f);
        else if (c < 0x20) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}

static void write_case(FILE *f, const row_t *r, bool first)
{
    orr_bundle_t *b = bundle(r->bundle);
    char out[ORR_OUT_MIN], sec[512];
    const int n = orr_compose(b, -1, r->A, r->B, r->C, out, sizeof out);
    orr_sections(b, sec, sizeof sec);
    const unsigned d = orr_dropped(b);
    fprintf(f, "%s\n  {\"bundle\": \"%s\", \"q\": -1, \"A\": %d, \"B\": %d, \"C\": %d,\n   \"sections\": [", first ? "" : ",",
            r->bundle, r->A, r->B, r->C);
    bool f1 = true;
    for (char *p = sec; *p;) {
        char *c = strchr(p, ',');
        const size_t m = c ? (size_t)(c - p) : strlen(p);
        fprintf(f, "%s\"%.*s\"", f1 ? "" : ", ", (int)m, p);
        f1 = false;
        p += m + (c ? 1 : 0);
    }
    fprintf(f, "], \"dropped\": [");
    f1 = true;
    for (size_t i = 0; i < NDROPS; i++) {
        if (d & s_drops[i].bit) { fprintf(f, "%s\"%s\"", f1 ? "" : ", ", s_drops[i].name); f1 = false; }
    }
    fprintf(f, "], \"bytes\": %d,\n   \"text\": ", n);
    json_str(f, n >= 0 ? out : "");
    fputc('}', f);
}

/* A deterministic pseudo-random row (three distinct cards of 22). */
static void rand_row(uint32_t *x, int *A, int *B, int *C)
{
    do {
        *x ^= *x << 13;
        *x ^= *x >> 17;
        *x ^= *x << 5;
        *A = (int)(*x % 22);
        *B = (int)((*x >> 5) % 22);
        *C = (int)((*x >> 10) % 22);
    } while (*A == *B || *A == *C || *B == *C);
}

/* Rows found by search: for each real bundle and each wanted section, the first row (in a fixed pseudo-random order)
 * whose paragraph has it; the same for each budget step (long, then fr, then en). */
static int search_rows(row_t *rows, int cap)
{
    int n = 0;
    const char *real[2] = { "fr", "en" };
    char out[ORR_OUT_MIN], sec[512];
    for (int l = 0; l < 2; l++) {
        orr_bundle_t *b = bundle(real[l]);
        for (size_t w = 0; w < sizeof s_need_real / sizeof s_need_real[0] && n < cap; w++) {
            uint32_t x = 0x9E3779B9u ^ (uint32_t)(w * 7919 + (size_t)l * 104729);
            for (int tries = 0; tries < 20000; tries++) {
                int A, B, C;
                rand_row(&x, &A, &B, &C);
                if (orr_compose(b, -1, A, B, C, out, sizeof out) <= 0) continue;
                orr_sections(b, sec, sizeof sec);
                if (!has_section(sec, s_need_real[w])) continue;
                rows[n++] = (row_t){ real[l], A, B, C };
                break;
            }
        }
    }
    for (size_t k = 0; k < NDROPS && n < cap; k++) {
        bool found = false;
        for (int src = 0; src < 3 && !found; src++) {
            const char *bn = src == 2 ? "en" : src ? "fr" : "long";
            orr_bundle_t *lb = bundle(bn);
            for (int A = 0; A < 22 && !found; A++)
                for (int B = 0; B < 22 && !found; B++)
                    for (int C = 0; C < 22 && !found; C++) {
                        if (A == B || A == C || B == C) continue;
                        if (orr_compose(lb, -1, A, B, C, out, sizeof out) > 0 && (orr_dropped(lb) & s_drops[k].bit)) {
                            rows[n++] = (row_t){ bn, A, B, C };
                            found = true;
                        }
                    }
        }
    }
    return n;
}

/* cases-lean.json: the five lean screens (fits = NULL: <= ORR_LEAN_PAGE_CHARS code points) of every row of `rows`,
 * plus 100 pseudo-random rows of each real bundle. */
static int write_lean(const row_t *rows, int nrows)
{
    char path[512];
    snprintf(path, sizeof path, "%s/cases-lean.json", ORR_FIXTURES);
    FILE *f = fopen(path, "wb");
    CHECK(f != NULL);
    if (!f) return 0;
    fprintf(f, "{\"about\": \"PROTOCOL 5f.7 lean draw cases (5f.6: no question card), written by core/tests/test_oracle_reader "
               "--write-fixtures from core/src/oracle_reader.c orr_compose_lean with the reference page test (fits = NULL: "
               "a text fits one page when it has <= %d code points). Each case: bundle (reader-<bundle>.txt here), A B C, "
               "and the five screens' texts (UTF-8): by card, by position, by the numbers, together, and. Format: "
               "core/README.md 'Sentence reader'.\",\n \"format\": 1,\n \"page_chars\": %d,\n \"cases\": [",
            ORR_LEAN_PAGE_CHARS, ORR_LEAN_PAGE_CHARS);
    static char o[ORR_LEAN_SCREENS][ORR_OUT_MIN];
    char *const out[ORR_LEAN_SCREENS] = { o[0], o[1], o[2], o[3], o[4] };
    const size_t caps[ORR_LEAN_SCREENS] = { ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN };
    int n = 0;
    static row_t extra[200];
    int ne = 0;
    const char *real[2] = { "fr", "en" };
    for (int l = 0; l < 2; l++) {
        uint32_t x = 0x5F7u + (uint32_t)l;
        for (int i = 0; i < 100; i++) {
            int A, B, C;
            rand_row(&x, &A, &B, &C);
            extra[ne++] = (row_t){ real[l], A, B, C };
        }
    }
    for (int pass = 0; pass < 2; pass++) {
        const row_t *rs = pass ? extra : rows;
        const int nr = pass ? ne : nrows;
        for (int i = 0; i < nr; i++) {
            orr_bundle_t *b = bundle(rs[i].bundle);
            if (orr_compose_lean(b, rs[i].A, rs[i].B, rs[i].C, out, caps, NULL, NULL) != ORR_LEAN_SCREENS) continue;
            fprintf(f, "%s\n  {\"bundle\": \"%s\", \"A\": %d, \"B\": %d, \"C\": %d,\n   \"texts\": [", n ? "," : "", rs[i].bundle,
                    rs[i].A, rs[i].B, rs[i].C);
            for (int k = 0; k < ORR_LEAN_SCREENS; k++) {
                if (k) fputs(",\n             ", f);
                json_str(f, out[k]);
            }
            fputs("]}", f);
            n++;
        }
    }
    fprintf(f, "\n ]\n}\n");
    fclose(f);
    return n;
}

static void write_fixtures(void)
{
    char path[512];
    snprintf(path, sizeof path, "%s/cases.json", ORR_FIXTURES);
    FILE *f = fopen(path, "wb");
    CHECK(f != NULL);
    if (!f) return;
    static row_t rows[256];
    int n = 0;
    for (size_t i = 0; i < sizeof s_fixed / sizeof s_fixed[0]; i++) rows[n++] = s_fixed[i];
    n += search_rows(rows + n, 256 - n);
    fprintf(f, "{\"about\": \"PROTOCOL 5f.1 sentence reader cases (v3 findings and priority; 5f.6: no question card, q = "
               "-1, the closing is B's), written by core/tests/test_oracle_reader --write-fixtures from "
               "core/src/oracle_reader.c. Bundles: reader-<bundle>.txt in this directory (fr/en = the real bundles, "
               "maintained as checked-in text, synth = the v2 sections with a known table, synth3 = synth with every v3 and "
               "short-reading section, long = synth3 with padded findings for the 900-byte budget, nocentre = synth "
               "without the centre-gaze sections: with them a facing pair is always covered by the centre gaze). Each "
               "case: cards A B C (q is always -1), the expected paragraph text (UTF-8, bytes long, <= 900), the sections "
               "of its sentences in order and the budget steps taken. invalid: rows the composer must refuse. Format: "
               "core/README.md 'Sentence reader'.\",\n \"format\": 2,\n \"limit\": %d,\n", ORR_TEXT_MAX);
    fprintf(f, " \"invalid\": [\n  {\"bundle\": \"synth\", \"q\": -1, \"A\": 2, \"B\": 3, \"C\": 77, \"why\": \"card 77 is past "
               "the deck\"},\n  {\"bundle\": \"fr\", \"q\": -1, \"A\": 2, \"B\": 3, \"C\": -1, \"why\": \"A, B and C are "
               "needed\"},\n  {\"bundle\": \"fr\", \"q\": 1, \"A\": 2, \"B\": 3, \"C\": 4, \"why\": \"no question card "
               "(5f.6)\"},\n  {\"bundle\": \"en\", \"q\": -1, \"A\": 22, \"B\": 1, \"C\": 2, \"why\": \"card 22 is past "
               "the deck\"}\n ],\n \"cases\": [");
    for (int i = 0; i < n; i++) write_case(f, &rows[i], i == 0);
    fprintf(f, "\n ]\n}\n");
    fclose(f);
    const int ns = write_lean(rows, n);
    printf("     wrote %s: %d cases; cases-lean.json: %d cases\n", path, n, ns);
}

static jv_t *s_doc, *s_lean;
static char *s_doc_text, *s_lean_text;

static void load_doc(void)
{
    size_t n;
    s_doc_text = slurp("cases.json", &n);
    if (s_doc_text) {
        jp = s_doc_text;
        s_doc = jvalue();
    }
    s_lean_text = slurp("cases-lean.json", &n);
    if (s_lean_text) {
        jp = s_lean_text;
        s_lean = jvalue();
    }
}

/* Every fixture case, byte for byte, with the same sections and budget steps. */
static void test_fixture_cases(void)
{
    CHECK(s_doc != NULL);
    const jv_t *cases = jget(s_doc, "cases");
    CHECK(cases && cases->t == J_ARR);
    int n = 0, real = 0;
    char out[ORR_OUT_MIN], sec[512];
    for (const jv_t *c = cases ? cases->kid : NULL; c; c = c->next, n++) {
        orr_bundle_t *b = bundle(jstr(c, "bundle"));
        CHECK(b != NULL);
        if (!b) continue;
        CHECK_EQ(jint(c, "q"), -1);
        real += !strcmp(jstr(c, "bundle"), "fr") || !strcmp(jstr(c, "bundle"), "en");
        const int r = orr_compose(b, -1, jint(c, "A"), jint(c, "B"), jint(c, "C"), out, sizeof out);
        const char *want = jstr(c, "text");
        const bool same = r >= 0 && (size_t)r == strlen(want) && memcmp(out, want, (size_t)r) == 0;
        CHECK(same);
        if (!same) {
            fprintf(stderr, "case %d (%s %d %d %d):\n  got  %s\n  want %s\n", n, jstr(c, "bundle"), jint(c, "A"),
                    jint(c, "B"), jint(c, "C"), r >= 0 ? out : "(error)", want);
        }
        CHECK_EQ(r, jint(c, "bytes"));
        CHECK(r <= ORR_TEXT_MAX);
        CHECK_EQ(orr_dropped(b), drop_mask(jget(c, "dropped")));
        orr_sections(b, sec, sizeof sec);
        char joined[512] = "";
        for (const jv_t *s = jget(c, "sections") ? jget(c, "sections")->kid : NULL; s; s = s->next) {
            if (joined[0]) strcat(joined, ",");
            strncat(joined, s->str ? s->str : "", sizeof joined - strlen(joined) - 2);
        }
        SAYS(sec, joined);
    }
    CHECK(real >= 12);
    printf("     %d fixture cases (%d on the real bundles)\n", n, real);
    const jv_t *inv = jget(s_doc, "invalid");
    int ni = 0;
    for (const jv_t *c = inv ? inv->kid : NULL; c; c = c->next, ni++) {
        CHECK_EQ(orr_compose(bundle(jstr(c, "bundle")), jint(c, "q"), jint(c, "A"), jint(c, "B"), jint(c, "C"), out,
                             sizeof out), -1);
        CHECK_EQ(out[0], '\0');
    }
    CHECK(ni >= 4);
}

/* Every lean case, the five screens byte for byte (the reference page test). */
static void test_fixture_lean(void)
{
    CHECK(s_lean != NULL);
    const jv_t *cases = jget(s_lean, "cases");
    CHECK(cases && cases->t == J_ARR);
    CHECK_EQ(jint(s_lean, "page_chars"), ORR_LEAN_PAGE_CHARS);
    static char o[ORR_LEAN_SCREENS][ORR_OUT_MIN];
    char *const out[ORR_LEAN_SCREENS] = { o[0], o[1], o[2], o[3], o[4] };
    const size_t caps[ORR_LEAN_SCREENS] = { ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN };
    int n = 0, real = 0;
    for (const jv_t *c = cases ? cases->kid : NULL; c; c = c->next, n++) {
        orr_bundle_t *b = bundle(jstr(c, "bundle"));
        CHECK(b != NULL);
        if (!b) continue;
        real += !strcmp(jstr(c, "bundle"), "fr") || !strcmp(jstr(c, "bundle"), "en");
        CHECK_EQ(orr_compose_lean(b, jint(c, "A"), jint(c, "B"), jint(c, "C"), out, caps, NULL, NULL), ORR_LEAN_SCREENS);
        const jv_t *t = jget(c, "texts");
        int k = 0;
        for (const jv_t *x = t ? t->kid : NULL; x && k < ORR_LEAN_SCREENS; x = x->next, k++) SAYS(out[k], x->str ? x->str : "");
        CHECK_EQ(k, ORR_LEAN_SCREENS);
    }
    CHECK(real >= 150);
    printf("     %d lean cases (%d on the real bundles)\n", n, real);
}

/* The fixture covers every section and budget step (so a regenerated file cannot silently lose one). */
static void test_fixture_coverage(void)
{
    const jv_t *cases = jget(s_doc, "cases");
    static char real[16384], synth[16384], drops[8192];
    real[0] = synth[0] = drops[0] = 0;
    for (const jv_t *c = cases ? cases->kid : NULL; c; c = c->next) {
        const bool r = !strcmp(jstr(c, "bundle"), "fr") || !strcmp(jstr(c, "bundle"), "en");
        char *dst = r ? real : synth;
        for (const jv_t *s = jget(c, "sections") ? jget(c, "sections")->kid : NULL; s; s = s->next) {
            if (strlen(dst) + strlen(s->str) + 2 < sizeof real) { strcat(dst, ","); strcat(dst, s->str); }
        }
        for (const jv_t *d = jget(c, "dropped") ? jget(c, "dropped")->kid : NULL; d; d = d->next) {
            if (strlen(drops) + strlen(d->str) + 2 < sizeof drops) { strcat(drops, ","); strcat(drops, d->str); }
        }
    }
    for (size_t i = 0; i < sizeof s_need_real / sizeof s_need_real[0]; i++) {
        const bool ok = has_section(real + 1, s_need_real[i]);
        if (!ok) fprintf(stderr, "fixture: no real-bundle case with %s\n", s_need_real[i]);
        CHECK(ok);
    }
    for (size_t i = 0; i < sizeof s_need_synth / sizeof s_need_synth[0]; i++) {
        const bool ok = has_section(synth + 1, s_need_synth[i]);
        if (!ok) fprintf(stderr, "fixture: no synthetic case with %s\n", s_need_synth[i]);
        CHECK(ok);
    }
    for (size_t i = 0; i < sizeof s_need_drops / sizeof s_need_drops[0]; i++) {
        const bool ok = has_section(drops + 1, s_need_drops[i]);
        if (!ok) fprintf(stderr, "fixture: no case drops %s\n", s_need_drops[i]);
        CHECK(ok);
    }
}

/* Every row of both real bundles (and the synthetic one): no failure, <= 900 bytes of valid UTF-8, deterministic,
 * B's closing last; the short reading of every row of the real bundles within its caps. */
static void test_sweep(void)
{
    const char *names[3] = { "fr", "en", "synth3" };
    char out[ORR_OUT_MIN], again[ORR_OUT_MIN];
    static char lo[ORR_LEAN_SCREENS][ORR_OUT_MIN];
    char *const so[ORR_LEAN_SCREENS] = { lo[0], lo[1], lo[2], lo[3], lo[4] };
    const size_t caps[ORR_LEAN_SCREENS] = { ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN };
    long rows = 0, drops[NDROPS] = { 0 }, shorts = 0, over = 0;
    size_t maxlen = 0, max3 = 0;
    const clock_t t0 = clock();
    for (int l = 0; l < 3; l++) {
        orr_bundle_t *b = bundle(names[l]);
        for (int A = 0; A < 22; A++)
            for (int B = 0; B < 22; B++)
                for (int C = 0; C < 22; C++) {
                    if (A == B || A == C || B == C) continue;
                    const int r = orr_compose(b, -1, A, B, C, out, sizeof out);
                    rows++;
                    if (r <= 0 || r > ORR_TEXT_MAX || !utf8_valid(out, (size_t)r)) {
                        CHECK(r > 0 && r <= ORR_TEXT_MAX && utf8_valid(out, (size_t)r));
                        return;
                    }
                    size_t cl;
                    const char *closing = orr_card_field(b, B, ORR_F_CLOSING, &cl);
                    if (!(orr_dropped(b) & ORR_DROP_CUT)) CHECK((size_t)r >= cl && !memcmp(out + r - cl, closing, cl));
                    if ((size_t)r > maxlen && l < 2) maxlen = (size_t)r;
                    const unsigned m = orr_dropped(b);
                    if (l < 2) for (size_t k = 0; k < NDROPS; k++) drops[k] += (m & s_drops[k].bit) != 0;
                    if ((rows & 1023) == 0) {
                        CHECK_EQ(orr_compose(b, -1, A, B, C, again, sizeof again), r);
                        CHECK(memcmp(out, again, (size_t)r) == 0);
                    }
                    if (l < 2 && orr_compose_lean(b, A, B, C, so, caps, NULL, NULL) == ORR_LEAN_SCREENS) {
                        shorts++;
                        for (int k = 0; k < ORR_LEAN_SCREENS; k++) {
                            const size_t nk = strlen(lo[k]);
                            CHECK(utf8_valid(lo[k], nk));
                            if (orr_chars(lo[k], nk) > ORR_LEAN_PAGE_CHARS) over++;
                            if (nk > max3) max3 = nk;
                        }
                        CHECK(lo[2][0] && lo[4][0]);   /* the arc and "and" are never empty */
                        const size_t n4 = strlen(lo[4]);
                        if (strcmp(lo[4], closing) != 0) CHECK(orr_chars(lo[4], n4) <= ORR_LEAN_PAGE_CHARS);
                    }
                }
    }
    const double s = (double)(clock() - t0) / CLOCKS_PER_SEC;
    CHECK_EQ(drops[NDROPS - 1], 0);   /* the real bundles never need the final cut */
    printf("     %ld rows, longest %zu B (fr/en); budget steps (fr/en):", rows, maxlen);
    for (size_t k = 0; k < NDROPS; k++) if (drops[k]) printf(" %s %ld", s_drops[k].name, drops[k]);
    printf("; %.2f us/row; %ld lean draws, screens up to %zu B, %ld screens over %d chars\n", s * 1e6 / (double)rows,
           shorts, max3, over, ORR_LEAN_PAGE_CHARS);
}

/* Random byte mutations of the FR and synthetic bundles: parse + compose never misbehave (ASan / UBSan watch). */
static void test_fuzz(void)
{
    const char *names[2] = { "fr", "synth3" };
    char out[ORR_OUT_MIN];
    static char lo[ORR_LEAN_SCREENS][ORR_OUT_MIN];
    char *const so[ORR_LEAN_SCREENS] = { lo[0], lo[1], lo[2], lo[3], lo[4] };
    const size_t caps[ORR_LEAN_SCREENS] = { ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN, ORR_OUT_MIN };
    th_rng = 0x5EEDu;
    for (int l = 0; l < 2; l++) {
        const bundle_t *src = bundle_file(names[l]);
        char *m = malloc(src->len);
        for (int it = 0; it < 300; it++) {
            memcpy(m, src->text, src->len);
            const int edits = 1 + (int)(th_rand() % 40);
            for (int k = 0; k < edits; k++) {
                const size_t at = th_rand() % src->len;
                static const char pool[] = "{}[]\n\r.,()- 0123456789\x80\xC3\xE2\x01" "ABCq";
                m[at] = (th_rand() & 1) ? pool[th_rand() % (sizeof pool - 1)] : (char)th_rand();
            }
            const size_t len = src->len - (th_rand() % 64);
            const size_t need = orr_arena_bytes(m, len);
            void *ar = malloc(need);
            orr_bundle_t *b = orr_parse(m, len, ar, need);
            CHECK(b != NULL);
            for (int r = 0; r < 20 && b; r++) {
                const int q = (th_rand() % 8) ? -1 : (int)(th_rand() % 24) - 1;
                const int A = (int)(th_rand() % 24) - 1, B = (int)(th_rand() % 24) - 1, C = (int)(th_rand() % 24) - 1;
                const int n = orr_compose(b, q, A, B, C, out, sizeof out);
                CHECK(n <= ORR_TEXT_MAX);
                if (n >= 0) CHECK(strlen(out) == (size_t)n && utf8_valid(out, (size_t)n));
                if (orr_compose_lean(b, A, B, C, so, caps, NULL, NULL) > 0) {
                    for (int k = 0; k < ORR_LEAN_SCREENS; k++) CHECK(utf8_valid(so[k], strlen(so[k])));
                }
                char sec[64];
                orr_sections(b, sec, sizeof sec);
            }
            free(ar);
        }
        free(m);
    }
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "--write-fixtures") == 0) {
        write_fixtures();
        for (int i = 0; i < NB; i++) { free(s_b[i].text); free(s_b[i].arena); }
        return TH_DONE("test_oracle_reader --write-fixtures");
    }
    load_doc();
    RUN(test_findings);
    RUN(test_v3_findings);
    RUN(test_lean);
    RUN(test_pairs_without_centre);
    RUN(test_kinship);
    RUN(test_arc_shapes);
    RUN(test_variants);
    RUN(test_budget_order);
    RUN(test_final_cut);
    RUN(test_malformed_ignored);
    RUN(test_empty_sections);
    RUN(test_invalid);
    RUN(test_arena);
    RUN(test_fixture_cases);
    RUN(test_fixture_lean);
    RUN(test_fixture_coverage);
    RUN(test_sweep);
    RUN(test_fuzz);
    jfree(s_doc);
    jfree(s_lean);
    free(s_doc_text);
    free(s_lean_text);
    for (int i = 0; i < NB; i++) { free(s_b[i].text); free(s_b[i].arena); }
    return TH_DONE("test_oracle_reader");
}
