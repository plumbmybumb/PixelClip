/* oracle_reader.h — the Oracle's sentence reader (docs/PROTOCOL.md §5f.1, v3).
 *
 * C11, no allocation, no I/O. What a practised reader would say about a three-card row, generated from the reading
 * rules over a phrase bundle (a UTF-8 text asset per language, ~35 KB): one paragraph of at most ORR_TEXT_MAX
 * bytes. Deterministic: the same bundle and row always give the same bytes, on the clip and on the phone
 * (PixelClipKit/Tarot/SentenceReader.swift must match byte for byte). This file is the contract; the shared cases are
 * core/fixtures/tarot/cases.json (format: core/README.md "Sentence reader").
 *
 * Bundle (orr_parse): lines split on LF (a trailing CR is dropped). Ignored: blank lines (spaces / tabs only), lines
 * before the first header, lines longer than ORR_LINE_MAX bytes, lines that are not valid UTF-8, lines with a control
 * byte other than TAB. "[name]" starts a section (a repeated header adds to it). Phrase sections, one variant per line
 * (6-8 in the real bundles): positions, echo, arc.rising|falling|peak|dip|plateau|still,
 * gaze.facing|back|follow|front|center.left|center.right, kin.sum21|kin.same, step.up|down|restart,
 * place.wheel.first|later, place.world.first|last, place.fool.before|after, hsum, hsum.drawn,
 * row.open.left|open.right|closed, short.card, short.positions (§5f.4), and the pair sections couple.<a>-<b>,
 * couple.<a>-<b>.any, meet.<a>-<b>, kin.sum21.<a>-<b>, kin.same.<a>-<b>, succ.<a>-<b> (a != b, card indices <
 * ORR_MAX_CARDS, 1-2 digits); a variant whose placeholders are not all
 * {q|A|B|C|X|Y|S}.{name|kw|num|role|from|to|closing|question|srole} or {tag} (or with a "{" never closed) is ignored
 * ({q.*} is always empty since §5f.6). One-line sections keep their first line: card.<i>.<field> (field name|kw|num|
 * role|from|to|closing|question|gaze|degree|row|symbols|printed|reading|srole|brief), tag.<name> (the 20 tags of §5f.1),
 * depth, prompt, question.lead (§5f.2). Anything else is ignored (also the old question / qsum.* sections).
 *
 * Paragraph (orr_compose, §5f.1 v3 as amended by §5f.6: no question card): the findings in this order (= descending
 * strength, ties in the §5f.1 order; each at most once), the positions, the closing (B's); joined with one space.
 * Pairs are scanned (A,B), (B,C), (A,C) ("the scan"); "adjacent" = (A,B) then (B,C). Numbers: number(i) = 0 (row 0,
 * Le Mat), 21 (row 3), degree (row 1), degree + 10 (row 2); n22(i) = number(i) with Le Mat 22; reduce(x): while x > 22,
 * x = the sum of its digits; deg(i) = the degree line, 21 counted as 11. {X} {Y} {S} are empty unless a finding sets
 * them.
 *   couple     5  the first pair of the scan with a section: couple.<x>-<y> in the row's order ({A}=x, {B}=y), else
 *                 couple.<lo>-<hi>.any ({A}=lo, {B}=hi). That pair is "the couple's pair".
 *   encounter  4  the first pair of the scan with meet.<x>-<y> ({A}=x, {B}=y), else meet.<y>-<x> ({A}=y, {B}=x)
 *   centre     4  B looks left: gaze.center.left, right: gaze.center.right, front: gaze.front
 *   facing/back 3 adjacent pairs: right/left = gaze.facing, left/right = gaze.back ({A}, {B} = the pair); a pair the
 *                 centre gaze covers (left: (A,B); right: (B,C); only when that sentence was written) is skipped
 *   kinship    3  outside the couple's pair, the first pair of the scan whose numbers sum to 21, if none the first of
 *                 one degree in rows 1 and 2: kin.sum21.<lo>-<hi> / kin.same.<lo>-<hi> ({A}=lo, {B}=hi), else the
 *                 generic kin.sum21 / kin.same ({A}=x, {B}=y)
 *   succession 3  the first adjacent pair with succ.<x>-<y> ({A}=x, {B}=y)
 *   step       2  the first adjacent pair, both in rows 1-2, neither the couple's nor the succession's pair, whose
 *                 degrees go 10 -> 1 (step.restart), d -> d+1 (step.up) or d -> d-1 (step.down) and whose section has a
 *                 variant ({A}=x, {B}=y)
 *   arc        2  still (all equal), plateau (two equal), rising, falling, peak (B highest), else dip; a second-row
 *                 card's {X.kw} gets " " + [depth]
 *   placement  2  the first of: card 10 in A: place.wheel.first, in B or C: place.wheel.later ({X}=10); card 21 in A:
 *                 place.world.first, in C: place.world.last ({X}=21); card 0 in A or B: place.fool.before ({X} = the
 *                 next card), in C: place.fool.after ({X}=B), unless (0, {X}) is the couple's pair
 *   hidden sum 2  S = reduce(n22(A) + n22(B) + n22(C)) mod 22 (22 = Le Mat): hsum.drawn when S is A, B or C, else hsum
 *                 ({S}=S)
 *   open/closed 1 A looks left: row.open.left; else C looks right: row.open.right; else A right and C left: row.closed
 *   follow     1  the first uncovered adjacent pair looking the same way: gaze.follow, {A} = the follower (the card
 *                 whose gaze points at the other)
 *   echo       1  the first tag (fixed order) carried by two or three of A, B, C that has a [tag.<name>] gloss
 * Variant: fnv1a32 over the bytes "-1,A,B,C,<section>" (decimal; e.g. "-1,2,11,19,arc.dip", "-1,4,3,9,couple.4-3") mod
 * the number of valid variants (bundle order); a section without a valid variant writes nothing. Each sentence is cut
 * to ORR_SENTENCE_MAX bytes (UTF-8 boundary). The closing is the card.<B>.closing line itself.
 * Budget, while the paragraph is over ORR_TEXT_MAX bytes: drop the strength-1 findings (echo, follow, open/closed:
 * equal strengths drop the one written later first); at strength 2 first remove the arc's numerals (every " (...)" /
 * "(...)" group, as the regex " ?\([^)]*\)"), then drop hidden sum, placement, arc, step; then strength 3
 * (succession, kinship, the second facing/back, the first), 4 (centre gaze, encounter), 5 (couple). The positions and
 * closing are never dropped; if they alone are too long: cut before the last space that keeps <= ORR_TEXT_MAX - 3
 * bytes (else at a UTF-8 boundary) and append "…" (never with the real bundles).
 */
#ifndef ORACLE_READER_H
#define ORACLE_READER_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ORR_TEXT_MAX      900     /* bytes of the paragraph (PROTOCOL §5f.1, raised from 600; = TEXTLAY_LAYOUT_TEXT_MAX) */
#define ORR_OUT_MIN       (ORR_TEXT_MAX + 1)   /* orr_compose's out capacity, NUL included */
#define ORR_MAX_CARDS     78
#define ORR_LINE_MAX      512     /* longer bundle lines are ignored */
#define ORR_SENTENCE_MAX  960     /* a sentence is cut to this many bytes before joining */
#define ORR_TAGS          20


/* orr_dropped(): the budget steps the last orr_compose took (1 << the sentence slot of each dropped finding) */
enum {
    ORR_DROP_COUPLE   = 1u << 1,
    ORR_DROP_MEET     = 1u << 3,
    ORR_DROP_CENTER   = 1u << 4,
    ORR_DROP_FB1      = 1u << 5,   /* the first facing / back sentence */
    ORR_DROP_FB2      = 1u << 6,
    ORR_DROP_KIN      = 1u << 7,
    ORR_DROP_SUCC     = 1u << 8,
    ORR_DROP_STEP     = 1u << 9,
    ORR_DROP_ARC      = 1u << 10,
    ORR_DROP_PLACE    = 1u << 11,
    ORR_DROP_HSUM     = 1u << 12,
    ORR_DROP_ROW      = 1u << 13,
    ORR_DROP_FOLLOW   = 1u << 14,
    ORR_DROP_ECHO     = 1u << 15,
    ORR_DROP_NUMERALS = 1u << 20,  /* the arc's " (...)" groups removed */
    ORR_DROP_CUT      = 1u << 21,  /* the final cut + "…" */
};

typedef enum {
    ORR_F_NAME = 0, ORR_F_KW, ORR_F_NUM, ORR_F_ROLE, ORR_F_FROM, ORR_F_TO, ORR_F_CLOSING, ORR_F_QUESTION,
    ORR_F_GAZE, ORR_F_DEGREE, ORR_F_ROW, ORR_F_SYMBOLS,
    ORR_F_PRINTED, ORR_F_READING,   /* §5f.2: the name as printed ("" for XIII), the full reading (the clip pages it) */
    ORR_F_SROLE,                    /* §5f.4: the short role ({X.srole}; falls back to the role when absent) */
    ORR_F_BRIEF,                    /* §5f.7: the one-page detail of the card */
    ORR_FIELDS
} orr_field_t;

/* The parsed bundle: an index into the caller's text (which must stay alive and unchanged) plus a compose scratch,
 * all inside the caller's arena. */
typedef struct orr_bundle orr_bundle_t;

/* Bytes of arena orr_parse needs for this text (one counting pass; ~1 KB + 8 B per variant line + 17.3 KB compose scratch). */
size_t orr_arena_bytes(const char *text, size_t len);

/* Index `text` into `arena` (any alignment; >= orr_arena_bytes(text, len) bytes). NULL if the arena is too small or
 * an argument is NULL. A bundle with no usable line parses (every compose then fails or says little). */
orr_bundle_t *orr_parse(const char *text, size_t len, void *arena, size_t arena_bytes);

/* The paragraph for the row A B C (§5f.6: no question card, q must be -1) into out (NUL-terminated,
 * cap >= ORR_OUT_MIN). Returns its length in bytes (0..ORR_TEXT_MAX), or -1: bad arguments, q != -1, a card < 0 or
 * >= orr_cards() or without a name line. Uses the bundle's scratch (not reentrant per bundle). */
int orr_compose(orr_bundle_t *b, int q, int A, int B, int C, char *out, size_t cap);

/* §5f.7 the lean draw's five screens, in order:
 *   out[0] by card: one [short.card] variant for the row (hashed as "-1,A,B,C,short.card"), filled for A, B and C in
 *          turn ({X} = the card), the three lines joined with one space;
 *   out[1] by position: a [short.positions] variant ({A.from} {B.name} {B.role} {C.to} ...);
 *   out[2] by the numbers: the arc sentence (§5f.1 rule "arc", numerals included, [depth] words);
 *   out[3] together: the strongest finding of orr_compose's ranking (before any budget) other than the arc, gaze.front,
 *          gaze.follow and echo ("" when there is none);
 *   out[4] and: the second such finding + " " + B's closing when that fits one page, else the finding alone when it
 *          fits, else B's closing alone; B's closing alone when there is no second finding.
 * "Fits one page" is fits(ctx, text, len) (the firmware / app: the body font's page at the item's size); fits = NULL
 * is the reference rule used by the fixtures: <= ORR_LEAN_PAGE_CHARS code points. {X.srole} is the card's short role
 * (card.<i>.srole), else its role. A screen whose section has no variant is "". Returns ORR_LEAN_SCREENS, -1 for bad
 * arguments (as orr_compose; caps[i] >= 2, ORR_OUT_MIN recommended). Leaves orr_sections / orr_dropped empty. */
#define ORR_LEAN_SCREENS    5
#define ORR_LEAN_PAGE_CHARS 150
typedef bool (*orr_fits_fn)(void *ctx, const char *text, size_t len);
int orr_compose_lean(orr_bundle_t *b, int A, int B, int C, char *const out[ORR_LEAN_SCREENS],
                     const size_t caps[ORR_LEAN_SCREENS], orr_fits_fn fits, void *ctx);
/* UTF-8 code points in s[0..n). */
size_t orr_chars(const char *s, size_t n);

/* ORR_DROP_* bits of the last orr_compose. */
unsigned orr_dropped(const orr_bundle_t *b);

/* The sections of the sentences the last orr_compose wrote, in paragraph order, comma-separated, NUL-terminated
 * ("couple.4-3,gaze.center.right,gaze.back,arc.dip,hsum,positions,closing"); returns the length (truncated to whole
 * names that fit in cap). Diagnosis and fixtures. */
size_t orr_sections(const orr_bundle_t *b, char *out, size_t cap);

/* 1 + the highest card index with a line (0 for none). */
int orr_cards(const orr_bundle_t *b);

/* A card's field line (not NUL-terminated; *len 0 and "" when absent). */
const char *orr_card_field(const orr_bundle_t *b, int card, orr_field_t f, size_t *len);

/* §5f.2 one-line sections: [prompt] (the waits prompt) and [question.lead] ("Le Tarot te demande :"); "" when absent. */
const char *orr_prompt(const orr_bundle_t *b, size_t *len);
/* §5f.9 button hints: [hint.waits] "appuie", [hint.armed] "secoue", [hint.next] "suite", [hint.back] "retour",
 * [hint.end] "fin" (first usable line); "" when absent. */
typedef enum { ORR_HINT_WAITS = 0, ORR_HINT_ARMED, ORR_HINT_NEXT, ORR_HINT_BACK, ORR_HINT_END, ORR_HINTS } orr_hint_t;
const char *orr_hint(const orr_bundle_t *b, orr_hint_t h, size_t *len);

/* §5f.8 [prompt.armed] (the armed screen: "Shake the deck."); falls back to [prompt] when the bundle has none. */
const char *orr_prompt_armed(const orr_bundle_t *b, size_t *len);
const char *orr_question_lead(const orr_bundle_t *b, size_t *len);

/* FNV-1a 32 (offset 2166136261, prime 16777619), continued from h. */
uint32_t orr_fnv1a(uint32_t h, const void *p, size_t n);

#ifdef __cplusplus
}
#endif
#endif /* ORACLE_READER_H */
