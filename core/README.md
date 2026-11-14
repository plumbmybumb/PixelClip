# core/ — portable Hair Clip library

Dependency-free C11 (only `<string.h>`, `<stdint.h>`, `<stddef.h>`, `<stdbool.h>`), no malloc, no I/O.
The same sources are compiled into the ESP32-S3 firmware (as the ESP-IDF component `core`) and into
the macOS test suite and tools. The contract is `docs/PROTOCOL.md` §1, §2, §5b, §5c, §5f, §5f.1, §5g, §6; the public
API is `include/hca.h`, `include/scene.h`, `include/rsvp.h`, `include/textlay.h`, `include/board.h`,
`include/oracle.h`, `include/oracle_reader.h` and `include/oracle_text.h`.

```
core/
  include/hca.h          .hca parsing, frame decode (raw / RLE16), clipped glyph blit, RLE16 encoder
  include/scene.h        live motion-reactive scenes (sand, water, snow, fire, lava, balls, words)
  include/rsvp.h         Reader mode: streaming UTF-8 tokeniser, §5c timing + ORP, font document, layout, painter
  include/textlay.h      text layout: word wrap with a reader font into centred lines behind a window
  include/oracle.h       Oracle (tarot): one three-card draw paged as the lean list (§5f.7), paste-op screens, picker
  include/oracle_reader.h Oracle sentence reader: phrase bundle index, the §5f.1 paragraph (findings, budget), the §5f.7 lean screens
  include/oracle_text.h  Oracle text screens drawn from glyph atlases (§5f.2): prompt, one-page full-width screens (lean, detail), the §5f.9 button hints; reading / face / question kept, unused since §5f.7
  src/hca.c              decoder / encoder
  src/hca_internal.h     private helpers of hca.c (clipped blit, fill), also used by the tests
  src/scene.c            scene registry, params, palettes, IMU conditioning, grid renderer, axis map
  src/scene_grid.c       sand / water / snow cellular automata
  src/scene_fire.c       fire (heat propagation) and lava (metaballs)
  src/scene_balls.c      anti-aliased bouncing balls
  src/scene_words.c      words from a sheet asset bouncing as upright rectangles (§5b.1)
  include/board.h        a board: timed row pictures that scroll (§5g)
  src/board.c            the row set by the clock, static / scrolling layout, the loop, the painter
  src/scene_internal.h   private helpers shared by the scene*.c files
  src/rsvp_tok.c         UTF-8 decoder, character classes, tokeniser, title, timing, ORP
  src/rsvp_font.c        font document parser (own small JSON reader), atlas binding, code point lookup
  src/rsvp_paint.c       layout around the ORP column, painter with dirty rects, end card, pause mark
  src/rsvp_internal.h    private helpers shared by the rsvp*.c files
  src/textlay.c          word wrap, French punctuation glue, the window, the 64-line cap with "…"
  src/oracle.c           oracle phases, shuffles, three distinct cards, card of the day (FNV-1a), dates, draw diffs
  src/oracle_reader.c    bundle parser (two passes, caller's arena), v3 findings, variants (FNV-1a), 900-byte budget
  src/oracle_text.c      text screens (textlay wrap, static glyph paint, page dots, the corner arrow, boxes)
  tests/                 host test suite, fuzz test, benchmark, run_asan.sh
tools/                   hcaenc, hcainfo, hcadec, mkfixtures, scene_preview, rsvp_preview, fixtures/,
                         previews-scenes/ (tilt scripts + make_previews.sh)
```

## Build and test on macOS

Requires Apple clang and CMake ≥ 3.16 (`brew install cmake ninja`).

```sh
cmake -S core -B build/core            # add -G Ninja if you like
cmake --build build/core
ctest --test-dir build/core            # test_hca, test_fuzz, test_scene, test_rsvp, test_textlay, test_oracle, test_oracle_reader, test_oracle_text, test_board, bench_decode, tools_fixtures
core/tests/run_asan.sh                 # same suite under -fsanitize=address,undefined (build/core-asan)
```

Longer fuzzing: `HCA_FUZZ_SCALE=50 HCA_FUZZ_SEED=0xBEEF build/core-asan/tests/test_fuzz`.
Longer scene soak: `SCENE_TEST_SCALE=10 build/core-asan/tests/test_scene`.
Longer reader fuzzing: `RSVP_FUZZ_SCALE=50 build/core-asan/tests/test_rsvp`.
Longer layout fuzzing: `TEXTLAY_FUZZ_SCALE=30 build/core-asan/tests/test_textlay`.
Throughput: `build/core/tests/bench_decode` (frames/s for several kinds of 536x240 content).

CMake options: `HCA_BUILD_TESTS` (ON), `HCA_BUILD_TOOLS` (ON), `HCA_SANITIZE` (OFF).

## Tools (built into `build/core/tools/`)

| Tool | Use |
|---|---|
| `hcaenc OUT.hca [--fps N \| --durations a,b,..] [--loop N] [--atlas] [--size WxH] [--crop X,Y] [--raw] [--no-dither \| --dither-all] IN.png...` | PNG(s) → `.hca`. Inputs must already be the right size (536x240 unless `--atlas`/`--size`); `--crop X,Y` takes that region out of a larger render. Alpha is composited over black. Default dithering is 4x4 Bayer *except in flat areas* (see below). Every output is decoded back and verified before it is written. |
| `hcainfo FILE.hca [-q]` | Header, frame table, per-frame and total compression ratio; decodes every frame and exits non-zero if anything is invalid. |
| `hcadec FILE.hca OUT.png [FRAME \| --strip \| --all] [--scale N]` | Decode a frame (or all frames side by side, handy for atlases) to PNG. |
| `scene_preview KIND [--param k=v ...] --script TILT.txt [--fps 20] [--seconds 6] --out DIR [--sheet F.png] [--size WxH] [--seed N] [--noise G] [--bench]` | Runs a live scene with the firmware code path under a scripted tilt (`t gx gy gz` keyframes, linearly interpolated, plus 0.015 g IMU noise by default) and writes `DIR/frame_NNNN.png`; `--sheet` writes a 12-frame contact sheet, `--bench` prints host step/render timings instead. |
| `rsvp_preview FONT.json ATLAS_DIR TEXT.txt --out DIR [--words N] [--from K] [--wpm W] [--scale S] [--sheet F.png] [--bench]` | Reader mode with the firmware code path: tokenises the text like the upload pass (title break), paints words K..K+N-1 with one painter (so partial repaints are exercised) into `DIR/word_NNNN.png`, plus `DIR/paused.png` and `DIR/end_card.png`; prints per word the timing at W wpm, flags, ORP, size (compact/shifted/clipped) and dirty rect. The atlases named in the font document are read from `ATLAS_DIR/<id>.hca`. `--bench` prints µs per word. |
| `tools/previews-scenes/make_previews.sh [--quick]` | Renders every scene × 1–3 palettes with `tilt-slow.txt` (plus `flip`, `shake`, `faceup` for the first palette) into `tools/previews-scenes/out/` as GIFs (python3 + Pillow) or PNG frames, always with contact sheets. |
| `tools/fixtures/make_fixtures.sh` | Regenerates the fixtures: gradient still, 12-frame animation, and the placeholder **reader font**: a dot-matrix rendering of the 5×7 font (+ French accents, œ, guillemets, typographic quotes, dashes, `…`, `·`, `€`, `⏸`; 136 glyphs) as `rsvp-dot-w/-a.hca` (72×114, baseline 92, white / accent `#C6A2FF`) and `rsvp-dotc-w/-a.hca` (compact 44×70, baseline 56), the font document `rsvp-font.json`, and `rsvp-preview/` (12 words of `rsvp-sample.txt`, `sheet.png`, `paused.png`, `end_card.png`). |

Fixture file names are valid asset ids, so they can be uploaded as-is:
`curl -X PUT --data-binary @tools/fixtures/gradient.hca http://192.168.4.1/assets/gradient`.

**Dithering note for encoders (Swift side too):** ordered dithering of a flat colour that is not
exactly representable in RGB565 produces a fixed 4x4 pattern that RLE cannot compress. On an early
placeholder template that made frames 4–20x larger (48 KB dithered everywhere vs 11 KB flat-aware vs 2.7 KB
undithered; 12-frame animation 68 KB vs 17 KB vs 15 KB). `hcaenc` therefore only dithers pixels that
differ from one of their 4 neighbours; photos and gradients still get full dithering.

## How the firmware consumes it

`firmware/CMakeLists.txt` adds `../core` to `EXTRA_COMPONENT_DIRS`; components then
`PRIV_REQUIRES core`. Under ESP-IDF the component is compiled with `-O2` regardless of the project
optimisation level because the RLE decoder runs for every frame.

### Pixel buffers
All `uint16_t` pixel buffers hold RGB565 in **file byte order** (big-endian bytes in memory), which is
what the RM67162 consumes, so a decoded framebuffer can be DMA'd unchanged. Don't interpret these
values as native integers (on the little-endian ESP32 `0xF800` red appears as `0x00F8`).

### Assets
```c
hca_asset_t a;
if (hca_open(&a, file, file_size) != HCA_OK) reject();          // 422 on upload
if (file_size != a.hdr.data_size) reject();                       // uploads must be complete
hca_decode_frame(&a, i, framebuffer, 536);                        // dst stride in pixels
uint16_t ms = hca_frame_duration(&a, i, 100);
```
* `hca_open` validates the header and every frame-table entry against `data_size` (offset after the
  table, inside `data_size`, plausible length, even RLE length, raw length exactly w*h*2). If you
  only have the header + frame table in RAM (`size < data_size`), `hca_open` still succeeds and
  `hca_decode_frame` returns `HCA_ERR_TRUNCATED` for frames outside the buffer; read the frame bytes
  from flash yourself and call `hca_decode_frame_from(&a.hdr, bytes, len, dst, stride)`.
* An RLE16 frame must produce exactly `width*height` pixels **and** consume exactly `length` bytes;
  overruns, underruns and trailing bytes are `HCA_ERR_CORRUPT`. On error the destination may be
  partially written. Decoding never reads outside `[src, src+len)` nor writes outside the frame.
* `hca_blit_frame` decodes straight into a larger framebuffer with clipping (glyphs). For RLE frames
  it stops once the last visible row is done, so the tail of a stream is not validated there.

## Performance

`bench_decode` on an Apple M1 Max (one core, frames/s for a 536x240 frame into a contiguous buffer):
all black 16 B → ~200k; dark animation frame 3.9 KB → ~85k; sign-like (dark panel, bands, blocks) 11.7 KB → ~37k;
dithered gradient 257 KB (short runs) → ~35k; noise (all literal) → ~230k (memcpy speed).
Repeat runs are filled with aligned 32-bit stores (8x unrolled; on Xtensa this compiles to a
zero-overhead `loop` of `s32i`), literal runs are one `memcpy`, and there is no per-pixel call. On the
ESP32-S3 the decoder is bound by PSRAM write bandwidth rather than by run parsing.

## Reader (`include/rsvp.h`, PROTOCOL §5c)

RSVP speed reading: one word at a time, its optimal recognition point (ORP) glyph from the accent atlas
centred on a fixed column (x = 230), the rest from the white atlas, 2 px dim tick marks above and below
the ORP column. Everything the firmware draws or times for Reader mode is here, host-tested.

### API

```c
/* tokeniser: streaming (any chunk size, e.g. straight from the HTTP body), constant memory */
rsvp_tok_t t; rsvp_tok_init(&t, 0, RSVP_TOK_TITLE_BREAK);
rsvp_word_t w[32]; size_t used;
size_t n = rsvp_tok_feed(&t, chunk, len, &used, w, 32);   /* feed again from chunk+used if used < len */
n = rsvp_tok_finish(&t, w, 32);                            /* end of text */
const rsvp_stats_t *st = rsvp_tok_stats(&t);              /* words, sentences, paragraphs, invalid, nul, factor_x10 */
rsvp_tokenize(text, len, words, cap, &st);                 /* one-shot */
rsvp_word_at(buf, n, at_end, &w);                          /* re-read the word at an index offset */
rsvp_title(text, len, title, RSVP_TITLE_MAX);              /* first line, trimmed, code-point safe */

/* timing + ORP (exactly §5c) */
uint32_t ms = rsvp_word_ms(&w, wpm) ;                      /* + rsvp_blank_ms(&w) after a paragraph */
unsigned i = rsvp_orp_index(len_glyphs);                    /* Spritz: 1→0, 2–5→1, 6–9→2, 10–13→3, else 4 */
uint64_t total = rsvp_total_ms(st->factor_x10, st->paragraphs, wpm);

/* font + painter (no allocation: the caller owns the rsvp_font_t (~4.3 KB) and a scratch buffer) */
rsvp_font_t f; char err[64];
rsvp_font_parse(doc, doc_len, &f, err, sizeof err);        /* the §5c font document */
rsvp_font_bind(&f, &white, &accent, &compact_white, &compact_accent);   /* hca_open'ed atlases in memory */
rsvp_font_bind_large(&f, &large_white, &large_accent);   /* §5f.11, optional: the Oracle's screens only */
uint16_t scratch[rsvp_font_scratch_px(&f)];
rsvp_painter_t p; rsvp_painter_init(&p, &f, 536, 240, RSVP_ORP_X);
rsvp_rect_t d;
rsvp_paint(&p, &f, word, word_len, fb, scratch, n_scratch, &d, NULL);   /* flush d (first paint: whole fb) */
rsvp_paint(&p, &f, NULL, 0, fb, scratch, n_scratch, &d, NULL);          /* paragraph blank */
rsvp_paint_pause(&p, &f, true, fb, scratch, n_scratch, &d);             /* "⏸" in the top-right box */
rsvp_paint_end_card(&p, &f, words, rsvp_minutes(total), fb, scratch, n_scratch, &d);
```

* **Words** are byte ranges (`off`, `len`) with `glyphs`, `lead`/`core` (the letter span used for the
  length rules and the ORP) and flags `RSVP_F_COMMA` (`, ;` or a trailing dash), `RSVP_F_SENTENCE`
  (`. ! ? …`, skipping closing quotes/brackets/no-break spaces), `RSVP_F_PARA` (blank line, U+2029, or the
  end of the title line with `RSVP_TOK_TITLE_BREAK`). Segmentation rules are listed at the top of
  `rsvp.h`: whitespace separates, no-break spaces join (French "«&nbsp;Bonjour&nbsp;!&nbsp;»" is one word),
  U+2019 and hyphens stay inside words, en/em dashes end the word ("oui—", "non"), > 32 glyphs are split,
  never inside a UTF-8 sequence; invalid bytes are one glyph each and counted. `rsvp_tok_feed` emits at
  most 2 words per byte and stops when `out` has < 2 free slots (`used` tells how far it got).
* **Timing**: factor (tenths) = 10 / 13 (≥ 8 core glyphs) / 16 (≥ 12) + 5 after a comma/semicolon or + 10 at
  a sentence end; `ms = round(60000 × factor / (10 × wpm))`, wpm clamped to 50..1500; a paragraph adds a
  300 ms blank after the word. `rsvp_total_ms` is exact at 300 wpm (and within rounding otherwise).
* **Font document** (`rsvp_font_parse`): own small JSON reader (any key order, unknown keys skipped, `\uXXXX`
  incl. surrogate pairs), ≤ 16 KB, ≤ 256 glyphs without duplicates, one advance (0..1024) per glyph,
  `cell_w` 1..536, `cell_h` 1..240, `baseline` ≤ `cell_h`, asset ids for the atlases, optional `compact`
  and `large` (§5f.11; same keys; or `null`; Reader mode never uses `large`). The code point → glyph map is a sorted array (binary search). `rsvp_font_bind` checks each
  atlas is a glyph atlas of exactly `cell_w × cell_h` with ≥ `count` frames.
* **Layout** (`rsvp_layout`): pen positions from the advances; the ORP glyph's centre (pen + advance/2)
  lands on `orp_x` (±0.5 px). Normal size if the pen extent fits `[margin, w − margin)`, else compact; if
  even compact overflows with the ORP pinned it is shifted to fit (`shifted`), or clipped when wider than
  the screen (`clipped`). Missing glyphs use `?` (nothing if `?` is missing too); spaces use the font's
  `" "` advance or `cell_w/4`.
* **Painting**: both sizes share one baseline; the band (union of both cells) is centred vertically. A glyph
  is decoded into `scratch` and its non-black pixels are copied (black = transparent, so overlapping cells
  compose). `rsvp_paint` clears only the columns of the previous word ∪ the new one, in band rows, and
  returns that rectangle; after init/`rsvp_painter_invalidate` it clears the whole framebuffer, draws the
  ticks (`RSVP_TICK_COLOR` = brand dim `#52416B`) and returns the full frame. The end card picks the largest
  size per line (normal, compact, then 1/2..1/4 subsampled) that fits; the pause mark uses the font's U+23F8
  in the largest size that fits its 40×≤40 box, else a 5×7 two-bar mark ×3 in the accent `#C6A2FF`.
* Memory: `rsvp_tok_t` ~100 B, `rsvp_painter_t` ~40 B, `rsvp_font_t` ~4.3 KB, stack < 2 KB in
  `rsvp_paint`, no allocation anywhere.

### Tests and timing

`test_rsvp` (20 tests, ~2900 checks, also under ASan/UBSan): UTF-8 edge cases; ASCII, French (accents,
typographic apostrophes, guillemets with ordinary and no-break spaces, em dash on its own and attached,
en dash ranges, "Peut-être…"), numbers and currency, whitespace runs (CRLF, blank lines with spaces, U+2029,
em space, NUL, BOM), long-word split (also for 2-byte letters), invalid bytes, the title break, chunked
streaming == one-shot and `rsvp_word_at` == the index for every word (random chunk sizes and output
capacities); the ORP table; a timing table at 300/250/450/600/1000 wpm and clamping; `rsvp_total_ms` ==
the sum of the word times; font document parsing (escapes, surrogates, 18 malformed documents, 257 glyphs);
atlas binding errors; layout centring within ±1 px for 16 words and the tokeniser's ORP; compact, shifted
and clipped fallbacks; painting (ORP glyph from the accent atlas on the ORP column, ticks, nothing outside
the band, each partial repaint == a fresh full render and every changed pixel inside the dirty rect,
paragraph blank, invalidate, scratch too small); the missing-glyph path with and without `?`; the end card
(text, accent "fin", centring, smaller size on a narrow screen, substitutions counted); the pause mark
(glyph and 5×7 fallback); fuzzing of the tokeniser (random and structured bytes, ordering/bounds
invariants) and of the font parser (mutated documents) and layout/paint (random words, off-screen ORP
columns). `RSVP_FUZZ_SCALE=n` multiplies the fuzz iterations.

Host timing (Apple M1 Max, one core): layout + paint ~17–20 µs per word with 72×114 cells (avg dirty rect
28 % of the frame), layout alone ~0.1 µs, tokenising 1 MiB ~7 ms (163 k words).

## Text layout (`include/textlay.h`)

UTF-8 text word-wrapped with a §5c reader font (`rsvp_font_t`, its normal face) into centred lines; the Oracle's text
screens (`oracle_text.h`) wrap every text with it. One style, **scroll**: the whole text in one column behind a window
of up to 3 lines.

```c
/* textlay_layout_t ~13 KB, caller-owned (PSRAM on the clip); no allocation, < 1 KB of stack */
static textlay_layout_t lay;
textlay_layout_style(&font, text, len, 352, 240, 0, TEXTLAY_STYLE_SCROLL, &lay);   /* TEXTLAY_OK / TEXTLAY_ERR_ARG */
/* lay.lines lines: lay.line[i] = { x0, x1, top, first, count }; their glyphs lay.g[first .. first + count)
 * = { x, glyph (atlas frame or RSVP_GLYPH_NONE), advance, line }; lay.pitch = cell_h, lay.truncated */
```

### Rules (normative; the header comment of `textlay.h` has them too)

* **Wrap**: whitespace runs collapse (leading/trailing dropped); LF = hard break; no-break spaces (U+00A0, U+202F,
  U+2007) join and are drawn as a space; a space before `! ? : ; » ” … ›` or after `« “ ‹` never breaks; a word wider
  than the line breaks after `- / ‐ – —`, else between glyphs; the space at a break is not drawn; missing glyphs draw
  `?` (nothing if the font has no `?`; `missing` counts them). At most `TEXTLAY_LAYOUT_TEXT_MAX` (900) bytes are used.
* **Geometry**: the line width is `screen_w − 2·margin`; every line is centred on its pen extent
  (x0 = floor((screen_w − width)/2)). The **normal** face only (the compact face is never used), at most **64 lines**;
  a longer text keeps 63 lines and packs the rest into line 64 ending with `…` (or `...`, or nothing when the font has
  neither) at a word boundary when that keeps ≥ 60 % of the line (`truncated`). The window is
  W = min(3, screen_h / cell_h) lines (at least 1) at **block_y = (screen_h − W·cell_h) / 2 for every text** (a 1-line
  text sits on the window's top line); line i's top is block_y + i·cell_h. `page[0]` describes the whole text and its
  block (the window); a blank text gives `pages` = `lines` = `n` = 0.

### Tests and memory

`test_textlay` (7 tests, ~2.1 M checks, also under ASan/UBSan): wrapping (one/two/three lines, whitespace, French
accents and apostrophes, a missing glyph, guillemets with ordinary and no-break spaces, `:`/`!` never starting a
line, hard breaks, CRLF, long words split between glyphs and after hyphens), bad arguments, centring maths and the
window (centred for 1–4 lines, a 2-line window on a short screen), a 599-byte French prose laid out whole with every
glyph placed, the 64-line cap with `…` (and `...` without `…`), a 2-line window for tall cells, the 900-byte limit,
and a fuzz (random 0–940-byte texts incl. invalid UTF-8 from exact-size buffers, random screens and margins, every
geometry invariant checked). `TEXTLAY_FUZZ_SCALE=n` multiplies the fuzz iterations.

Memory: `textlay_layout_t` ~13 KB (its work area included); no allocation anywhere.

## Oracle (`include/oracle.h`, PROTOCOL §5f, §5f.3, §5f.6, §5f.7, §5f.8, §5f.10 – §5f.12)

A pure state machine for one reading: three cards for the person's question, the lean draw (§5f.7: at most 11 one-page
screens). The caller owns the atlases (deck D 108×206 and keys K 160×34, §5f.12, keys optional: `cfg.keys`; the notes
are no longer used), the reader bundle and the display.

```c
or_config_t c = { .cards = 22, .shake_g = 0.9f, .face_ms = 0, .page_ms = 0, .hold_ms = 300000 };
/* + card_detail[i]: card i has a brief (a detail screen); card_beside[i]: it fits beside the card (§5f.10) */
or_set_flipped(&o, flipped);                 /* §5f.12: the back / detail card at x 8 normally, 420 flipped (y 17) */
or_t o;
or_init(&o, &c, seed);
or_draw_t d;
if (or_step(&o, dt_ms, shake_g_metric, tapped, &d)) paint(&d);   /* changed: paint d (or_draw_diff for the delta) */
or_trigger(&o, NULL);                        /* POST /oracle/draw (or a forced row: int row[3]) */
or_turn(&o);                                 /* a tap / POST /oracle/turn: the next screen (waits -> armed -> deal) */
or_back(&o);                                 /* a double tap / POST /oracle/back: the previous screen */
or_lean_screens(&o, have5);                  /* which lean screens have text once composed (absent = skipped) */
wake_in = or_next_ms(&o);                    /* next shuffle frame, timer or idle timeout; UINT32_MAX = input only */
```

- **Screens** (one list, paged by hand): waits (TEXT 0 = the prompt + the back) → (tap) armed (§5f.8: TEXT `0xD000` =
  the armed prompt + the back; a shake or a tap deals, a back disarms) → shuffle (three slots, 1.2 s at 12 fps, never a
  slot's previous card nor its chosen one) → three (the cards at y 0, x 52 / 214 / 376, the shuffle's slots, + their
  keys at y 206, x 26 / 188 / 350 when `cfg.keys`, whole 160 × 34 tiles 2 px apart, each keyword inside its 140 × 28
  ink box at (10, 2); §5f.12) → lean 0 by card, 1 by position, 2 by the numbers, 3
  together, 4 and (TEXT `0xE000 + screen`) → detail A, B, C (TEXT `1 + card`, the card's brief, + `D[1+card]` at
  `or_back_x` when `card_beside`) → hold (the three again) → (tap) waits. The back of waits / armed sits at
  `or_back_x`, `OR_BACK_Y` 17 too (x 8 normally, 420 flipped: away from the BOOT corner). `or_back` walks the reverse (armed → waits); in waits a back does nothing, during the shuffle
  taps and backs do nothing. Lean screens without text and cards without a brief are skipped both ways; lean
  screens not told yet = screen 0 shown provisionally until the caller has composed them.
- **Draws**: `or_pick_three(cards, prev, &rng, out)`: three distinct cards, never the previous draw's set (a 3-card
  deck has only one). A forced row (`or_trigger(&o, row)`) must be three distinct indices < cards.
- **Timers**: `face_ms` (three) and `page_ms` (each lean / detail screen) advance only when non-zero (default 0);
  `hold_ms` is the idle timeout: no turn, back, draw or shake for that long returns any screen to WAITS (default
  300 000, 0 = never; armed included). **Shake** (§5f.8): edge-triggered (ready again once the metric is below
  `shake_g`/2); it deals only on armed, where it wins over a press in the same step; on waits and from the shuffle
  through hold it is ignored (the edge is used up; the idle timer is not reset). `or_trigger` (POST /oracle/draw)
  deals from any screen. `or_in_draw(&o)` (any screen but waits) is what the firmware defers its rotation, queue,
  notes and windows on.
- **Status**: `or_state_str` (waits / armed / shuffle / three / lean / detail / hold), `or_status_three` (cards_drawn
  from three on), `or_status_card` (the detail card), `or_status_page` (the lean screen 0–4 / the detail 0–2).
- `or_draw_diff(prev, next)` returns −1 (repaint everything) or the bit mask of ops to repaint over their own
  rectangles: a shuffle frame touches the three card slots.
- Tests (`tests/test_oracle.c`): frame math and `or_text_screen`, init / clamps / waits (back does nothing), the
  shuffle (14 random frames at 12 fps per slot, never the previous / chosen card, the diff masks, three with keys),
  the lean list forward and back (frames, status), sparse lean screens told while showing and cards without briefs
  (skipped both ways), no lean / no details (three → hold), timers (none by default, non-zero face / page timers
  through the whole list, the idle timeout and its reset, a huge step), arming (§5f.8: a shake on waits does nothing,
  tap → armed and its frame / status, shake or tap deals, back disarms, armed idles to waits or waits for ever with
  hold_ms 0, a shake held from waits needs a new edge, draws from waits and armed), the shake gate (shakes during the
  shuffle and on every screen of the reading change nothing, a tap with an ignored shake still counts, back to waits →
  tap → shake deals anew, ignored shakes do not reset the idle timer, POST draws still deal mid-reading), draws (20 000: distinct, never the previous set, uniform per slot; 4- and 3-card
  decks; forced rows good and bad; the picker alone), draw diffs, determinism, and the decode bench.

## Sentence reader (`include/oracle_reader.h`, PROTOCOL §5f.1)

What the clip says about a three-card row (and about the card of the day), from the reading rules over a phrase bundle.
The header is the normative description (parse rules, findings, variants, budget); the iOS mirror
(`PixelClipKit/Tarot/SentenceReader.swift`) must reproduce `fixtures/tarot/cases.json` byte for byte.

```c
size_t need = orr_arena_bytes(text, len);              /* 25 340 B for the 86 KB FR bundle */
orr_bundle_t *b = orr_parse(text, len, arena, need);   /* text must outlive b; no allocation */
char out[ORR_OUT_MIN];                                 /* 901 */
int n = orr_compose(b, -1, A, B, C, out, sizeof out);   /* §5f.6: q is always -1; 0..900 bytes, -1 = bad args */
orr_compose_lean(b, A, B, C, outs5, caps5, fits, ctx);  /* §5f.7: the five lean screens (fits NULL = <= 150 chars) */
orr_sections(b, buf, cap);   /* "couple.4-3,gaze.center.right,gaze.back,arc.dip,hsum,…,positions,closing" */
orr_dropped(b);              /* ORR_DROP_* budget steps of the last compose */
```

- **Bundle**: `[section]` headers, one variant per line; one-line sections `[card.<i>.<field>]` (also `printed` and
  `reading` for §5f.2), `[tag.<name>]`, `[depth]`, `[prompt]`, `[prompt.armed]` (§5f.8, `orr_prompt_armed`, falls back to `[prompt]`), `[hint.waits|armed|next|back|end]` (§5f.9, `orr_hint`; not drawn since §5f.11), `[question.lead]`; phrase sections `question`,
  `positions`, `echo`, `arc.*`, `gaze.facing|back|follow|front|center.left|center.right`, `kin.sum21|same`,
  `qsum.two|three`, `step.up|down|restart`, `place.wheel.first|later`, `place.world.first|last`,
  `place.fool.before|after`, `hsum`, `hsum.drawn`, `row.open.left|open.right|closed` and the pair sections
  `couple.<a>-<b>`, `couple.<a>-<b>.any`, `meet.<a>-<b>`, `kin.sum21.<a>-<b>`, `kin.same.<a>-<b>`, `succ.<a>-<b>`.
  Placeholders `{q|A|B|C|X|Y|S}.{name|kw|num|role|from|to|closing|question}` and `{tag}`. Absent sections say nothing;
  malformed lines (bad placeholders, unclosed braces, invalid UTF-8, control bytes, > 512 bytes, unknown sections, text
  before the first header) are ignored.
- **Paragraph (v3, §5f.6)**: findings in this order (strength, ties in PROTOCOL order): couple by order 5, encounter 4,
  centre gaze 4, facing/back 3 (two), kinship 3 (specific, else generic), succession 3, degree step 2, arc 2, placement
  2, hidden sum 2, open/closed 1, follow 1, echo 1 → positions → the closing (B's). Pairs are the row's only (no
  question card); Le Mat counts 22 in the hidden sum, digit-reduced above 22. The couple's pair is not named again by
  kinship, step or the Le Mat placement; the step skips the succession's pair. Over 900 bytes: strength 1 (echo,
  follow, row, the later first), then at strength 2 the arc's numerals, then hsum, place, arc, step; then 3, 4, 5;
  never the positions or closing. Variant = `fnv1a32("-1,A,B,C,<section>") mod n`. The old `question` and `qsum.*`
  sections are ignored.
- **Lean screens (§5f.7)**: `orr_compose_lean(b, A, B, C, out[5], caps, fits, ctx)` → 0 by card (one `[short.card]`
  variant for the row, hashed `"-1,A,B,C,short.card"`, filled for A, B, C with `{X}`; `{X.srole}` falls back to the
  role), 1 by position (a `[short.positions]` variant), 2 by the numbers (the arc sentence with its numerals), 3 together
  (the strongest finding other than the arc, `gaze.front`, `follow`, `echo`; "" when none), 4 and (the second such
  finding + " " + B's closing if `fits` says it is one page, else the finding alone if it fits, else the closing; the
  closing alone when there is no second finding). `fits` is the caller's page test (the firmware: `ot_paragraph_info`
  at full width with the body font = 1 page); NULL is the reference rule: ≤ `ORR_LEAN_PAGE_CHARS` (150) code points
  (`orr_chars`). The detail screens use `card.<i>.brief` directly.
- **Fixtures** (`fixtures/tarot/`, the shared contract with the iOS mirror):
  - `reader-fr.txt`, `reader-en.txt`: the real phrase bundles, maintained as checked-in text (v3, the §5f.2 lines,
    the short-reading sections, the briefs, `[prompt.armed]`, the `[hint.*]` lines); `reader-synth.txt`: the v2 sections, one variant each, a known 22-card table (documented in
    `test_oracle_reader.c`), plus malformed lines; `reader-synth3.txt`: the same with every v3 and short-reading section
    (two `[short.card]` variants, `srole` on even cards); `reader-long.txt`: synth3 with ~400-byte findings (the budget);
    `reader-nocentre.txt`: synth without the centre-gaze sections (facing pairs).
  - `cases.json` (`"format": 2`): `{"limit":900,"invalid":[…],"cases":[…]}`. A case: `bundle` (file
    `reader-<bundle>.txt`), `q` (always −1), `A`, `B`, `C`, `sections` (the sentences in paragraph order, as
    `orr_sections`), `dropped` (budget steps: `couple`, `meet`, `center`, `facing1`, `facing2`, `kin`, `succ`, `step`,
    `arc`, `place`, `hsum`, `row`, `follow`, `echo`, `numerals`, `cut`), `bytes` and `text`. `invalid`: rows the composer
    must refuse. 118 cases (71 on the real bundles: every finding family, arc shape and gaze case that occurs with them,
    a row for every budget step).
  - `cases-lean.json` (`"format": 1`, replaces cases-short.json): `{"page_chars":150,"cases":[{"bundle","A","B","C",
    "texts":[by card, by position, by the numbers, together, and]}]}` with the reference page rule (fits = NULL). 318
    cases (271 on the real bundles).
  - Regenerate after a composer or bundle change: `build/core/tests/test_oracle_reader --write-fixtures` (it writes
    `cases.json` and `cases-lean.json` from this composer; the hand-checked tests guard the composer itself).
- Tests (`tests/test_oracle_reader.c`, ASan via `run_asan.sh`): hand-checked v3 paragraphs over `reader-synth3.txt`
  (ordered and unordered couples, specific kinships, successions both ways, steps up / down / restart, every placement
  and the couple exclusion, hidden sum (drawn, Le Mat, Le Monde), open / closed rows, B's closing, the old question
  sections ignored), the lean screens (one variant per row with uniform punctuation, `srole` fallback, the arc as by the
  numbers, together / and skipping the arc, gaze.front, follow and echo, the page test choosing both / the finding / the
  closing, long findings, no finding, missing sections, bad arguments, small caps, the brief field), the budget invariant on padded synth3 rows; hand-checked paragraphs over the v2 synthetic
  bundle (couples in order / out of order, at most one, encounters in both orders and the fallback order, centre gaze
  left / right / front with the covered pair skipped, back to back, follow both ways, kin.sum21 before an earlier
  kin.same, 0 + 21, every arc shape with Le Mat and Le Monde, depth words, echo order and the gloss rule), variants
  against an independent FNV, the budget order over padded bundles (every step reached, numerals alone at some
  length), the final cut (space / UTF-8 boundary), malformed lines changing nothing on 400 rows, the arena contract at
  every alignment, bad arguments, both fixtures + coverage, a sweep of all 9 240 rows of each real bundle and of synth3
  (≤ 900 B, valid UTF-8, deterministic, B's closing last; the lean screens of every real row, none over 150 characters
  with the checked-in bundles) and a mutation fuzz of both composers.

## Oracle text screens (`include/oracle_text.h`, PROTOCOL §5f.2, §5f.10, §5f.11)

Every text screen is drawn on the clip from the reader bundle with reader fonts (§5c atlases), wrapped by the text
layout (`textlay.h`, its wrapping rules) and painted statically (the app-rendered text asset T is gone since §5f.2).

- **Boxes (§5f.10 / §5f.11)**: `ot_draw_box(fonts, font, text, len, x0, x1, y0, y1, fb, &info)` clears the whole
  screen, wraps the text at `x1 − x0` with `font`, centres the lines in `[x0, x1)` and the block in rows `[y0, y1)`,
  one page (lines past it are not drawn; `info.pages > 1` says so); `ot_box_info()` is the layout alone (a text over
  `TEXTLAY_LAYOUT_TEXT_MAX` bytes, or one the layout truncated, never counts as one page). The boxes: rows 16…239
  normally, 0…223 flipped (`ot_text_y0(flipped)`, `OT_BOX_H` 224); full width x 8…528 (`OT_FULL_X0/X1`: the lean
  screens, a detail without its card); beside a card x 124…528 normally, x 8…412 flipped (`OT_BESIDE_*`, §5f.12: the
  prompts, a detail with its card).
- **The composer's check** (§5f.7 / §5f.11): `ot_lean_fits(fonts, text, len)` — the `fits` callback for
  `orr_compose_lean`, ctx = the `ot_fonts_t` — is one page in the body font's **normal** face in the full-width box
  (520 × 224, both orientations), never the face the screen is drawn in; the phone applies the same rule.
- **As big as fits (§5f.11)**: `ot_box_pick(fonts, faces[], n, text, len, box)` returns the first of the faces
  (largest first) in which the text fits the box on one page, or −1. The faces are views of the body font —
  `ot_font_large_view()` / `ot_font_compact_view()` make a copy whose normal face is the large / compact one —
  so the order is large (when the §5c document has `"large"`, `rsvp_font_bind_large`), the font itself, compact.
- **The corner arrow (§5f.11)**: `ot_draw_arrow(fb, flipped)` draws one ▶ (`OT_ARROW_W` 8 × `OT_ARROW_H` 9, the accent
  colour) in the BOOT corner: normally its right edge 8 px from the right edge and its top row at y 4, pointing right;
  flipped its left edge 8 px from the left edge and its bottom row at y 235, pointing left (`ot_arrow_xy`). Only the
  triangle's 40 pixels are written; the 24×16 corner reserve (`ot_reserve_xy`: x 512…535 y 0…15, or x 0…23 y
  224…239) holds nothing else. (The §5f.9 word hints and the §5f.10 stacked column are gone; the bundles' `[hint.*]`
  lines are still parsed, `orr_hint`, and no longer drawn.)
- Older screens kept (unused by the firmware since §5f.7): `ot_draw_prompt / face / question / reading` in the right
  column x 168…520, `ot_draw_paragraph` / `ot_paragraph_info` at full width in rows 20…219 with page dots.
- Tests (`tests/test_oracle_text.c`, a test font whose pixels name glyph and atlas): `test_arrow` (the exact 40 pixels
  in both corners, inside the triangle's box and the reserve, the accent colour only, the flat side away from the
  button and the tip towards it), `test_boxes` (all four boxes × the three faces: ink only inside the box, centred,
  the screen cleared, rows per page; the pick goes large → normal → compact → none as the text grows; a missing face
  skipped; bad boxes), `test_layout` (in both orientations the boxes, the centred three, the keyword row
  and the back / detail card stay on screen and out of the corner reserve; the cards are whole; the text beside a
  card is 8 px from it), `test_lean_fits` (the normal face's page, not the large one's; with the real FR bundle at
  22 pt the "and" screen comes out as the 150-character reference rule on 1058 of 1680 rows — the reference rule is a
  character count, the check a font measure, so clip and phone agree with each other, not with the reference rule),
  `test_real_faces` (every lean screen of 4 600 real rows at full width, every brief beside its card and both prompts
  beside the back, at 18 / 22 / 26 pt with a large face at 1.3× and compact at 12 pt — host test-font metrics:

  | | lean (large / normal / compact) | briefs beside the card (large / normal / compact; no card) | prompts |
  |---|---|---|---|
  | FR 18 pt | 4600 / 0 / 0 | 22 / 0 / 0; 0 | large |
  | FR 22 pt | 4599 / 1 / 0 | 8 / 14 / 0; 0 | large |
  | FR 26 pt | 1199 / 3401 / 0 | 0 / 22 / 0; 0 | large |
  | EN 18 pt | 4600 / 0 / 0 | 22 / 0 / 0; 0 | large |
  | EN 22 pt | 4600 / 0 / 0 | 13 / 9 / 0; 0 | large |
  | EN 26 pt | 1203 / 3397 / 0 | 0 / 22 / 0; 0 | large |

  — nothing needs the compact face and no card is dropped), plus the earlier column / paragraph tests and the real
  readings' page counts. `test_rsvp`: the `"large"` face parsed (null, broken), bound on its own, widening the scratch.
  `test_oracle`: the §5f.12 geometry (54 px gaps, equal margins, the keys centred under the cards, not overlapping
  and ending at the bottom edge, the ink box inside the tile, the back centred vertically and mirrored, all clear of
  both corners), the three with and without keys (none during the shuffle), the back
  and the detail card moving with `or_set_flipped`, a detail with and without its card.

## Board (`include/board.h`, PROTOCOL §5g)

A generic list of timed row pictures (for example a timetable): the phone draws the rows into a sheet, the clip stacks
them, drops each by its own clock once its time has passed, and scrolls when the list is taller than the screen.

```c
board_row_t rows[] = { { .frame = 2, .has_until = true, .until = 1761062400 }, { .frame = 3 } };
board_t b;
board_init(&b, frames, n, fw, fh, rows, nrows, header /*-1*/, empty /*-1*/, scroll_px_s, 536, 240);
board_set_clock(&b, now_unix, clock_ok);        /* at start and once a second: the row set */
if (board_step(&b, dt_ms)) board_render(&b, fb, 536, 240, &dirty);   /* flush dirty */
wake_in = board_next_ms(&b);                    /* 33 while scrolling, UINT32_MAX when static */
```

- **Rows**: a row shows while the clock is before its `until` (exclusive), always without one, every row while the
  clock is not synced (and until the first `board_set_clock`). **Layout**: the `header` frame fixed at y 0 (if any);
  the shown rows stacked with no gap under it, centred (x = (536 − w) / 2); no row left → the `empty` frame alone
  under the header (or black). **Scrolling**: when the stack is taller than the space under the header it scrolls
  up at `scroll_px_s` px/s (4…60, default 16; the offset in 1/1000 px, integer arithmetic), looping with
  `BOARD_GAP` (48) px of black; else static from the top. A change of the row set applies at once on a static board
  (or one that becomes static), at the next loop boundary while it scrolls (keeping its phase when it still
  scrolls, from the top when it starts scrolling). **Rendering**: the first render (and after `board_invalidate`)
  clears the screen and draws the header; then only the rows' column below the header is redrawn when the integer
  offset moved (frames are opaque: row copies, no blending); the dirty rect says what to flush.
- Limits: 1…48 frames of w ≤ 536 × 16 ≤ h ≤ 240, N·w·h ≤ 1 048 576, 1…47 rows, every frame index < N.
- Tests (`tests/test_board.c`, pixels naming frame and row): validation (sizes, counts, frame ranges, the pixel
  limit, NULL frames; an invalid board draws nothing), the until filter (exclusive, rows without until, the clock
  going back), the unsynced clock (every row), a static layout (header, rows stacked, centred, nothing to repaint
  when nothing moves, expiry at once), header and empty (the empty frame alone, black without one, no header →
  rows from y 0), scrolling (16 px after 1 s, sub-pixel steps, the 48 px gap, one loop per period / speed, the
  dirty column, clipping into a smaller framebuffer), expiry at the loop boundary (pending until then; a list that
  then fits turns static and repaints in full; one that still scrolls keeps its phase), determinism.

## Live scenes (`include/scene.h`)

Seven motion-reactive scenes for the playlist item `{"type":"scene","scene":"sand","params":{...}}`
(PROTOCOL §4, §5b): `sand`, `water`, `snow`, `fire`, `lava` simulate on a coarse grid (default 4 px per
cell, 134×60 on the 536×240 panel) and are drawn as crisp 4×4 blocks or with `smooth=1` as a cheap
bilinear 2×2-sub-block blend; `balls` runs at full resolution with anti-aliasing; `words` (§5b.1) moves the words
of a sheet asset the app renders, at full resolution.

### API

```c
/* registry: single source of truth for GET /scenes and the app's pickers */
size_t n = scene_count();                       /* 7, index == scene_kind_t */
const scene_info_t *si = scene_info(i);         /* id, name, description, params[] */
const scene_info_t *si = scene_find("water");
char body[2048]; scene_describe_json(body, sizeof body);   /* the GET /scenes response, ~1.3 KB */

/* params: flat key/values from the playlist item ("params" object) */
scene_params_t p; scene_params_clear(&p);
scene_params_set(&p, "palette", "amber");      /* JSON strings */
scene_params_set_int(&p, "density", 60);       /* JSON numbers (truncate fractions first or pass the text) */

/* instance */
size_t need = scene_arena_bytes_for(SCENE_SAND, &p, 536, 240);
scene_t s;                                       /* ~1.2 KB, plain data */
scene_init(&s, SCENE_SAND, &p, 536, 240, seed, arena, need);   /* arena 4-byte aligned */
scene_step(&s, gx, gy, gz, dt_s);                /* gravity in g, display frame */
scene_rect_t dirty; scene_render(&s, fb, 536, 240, &dirty);
scene_invalidate(&s);                            /* fb was changed by someone else */

/* §5b.1 words: after scene_init, the sheet's frames (decoded RGB565BE, kept alive by the caller) */
int words = scene_words_set_sprites(&s, frames, n, w, h);   /* n 1..12, w <= 536, h <= 240, n*w*h <= 514 560 */
if (flipped && scene_follows_orientation(SCENE_WORDS)) scene_gravity_flipped(g);   /* words flip with the panel */
```

Parameters (unknown keys ignored; bad enum strings fall back to the default; ints are clamped; ints also
accept `true/false/on/off/yes/no`; enum values are case-insensitive):

| scene | params (default first / in brackets) |
|---|---|
| sand  | `palette` amber,ocean,forest,candy,mono,ember [amber] · `density` 10–100 [50] · `smooth` 0–1 [0] · `scale` 2–8 [4] |
| water | `palette` (same six) [ocean] · `density` 10–100 [50] · `smooth` [0] · `scale` [4] |
| snow  | `palette` (same six) [mono] · `density` 10–100 [50] (snowfall + drift size) · `smooth` [0] · `scale` [4] |
| fire  | `palette` classic,blue,emerald [classic] · `intensity` 10–100 [70] (flame height) · `smooth` [0] · `scale` [4] |
| lava  | `palette` (same six) [ember] · `density` 10–100 [50] (number of blobs 5–16) · `smooth` [1] · `scale` [4] |
| balls | `palette` (same six) [candy] · `count` 6–24 [12] · `size` 6–40 px radius [16] (shrunk to fit) · `bounce` 60–90 % [75] · `trail` 0–1 [0] |
| words | `bounce` 0–100 % [60] (colours and size are baked into the sheet) |

Palettes are defined once (`k_pal` in `src/scene.c`) as ramps from black to the brightest tone; the amber
ramp passes through the brand `#FFBE00`. Each scene maps its own "shade" scale through the ramp into a
256-entry RGB565BE table at init, so rendering is one table lookup per cell.

### Memory

Everything lives in the caller's `scene_t` plus one arena; nothing is allocated after init.
`scene_arena_bytes(kind, w, h)` is the worst case over all parameter values (scale 2, max counts);
`scene_arena_bytes_for(kind, params, w, h)` the exact need. For 536×240:

| | sand | water | snow | fire | lava | balls | words |
|---|---|---|---|---|---|---|---|
| defaults | 17.0 KB | 22.5 KB | 20.9 KB | 21.8 KB | 33.2 KB | 1.3 KB | 0.6 KB |
| worst case | 64.4 KB | 69.9 KB | 76.4 KB | 69.9 KB | 127.7 KB | 2.5 KB | 0.6 KB |

(`words` also reads the caller's decoded sheet, up to 514 560 px = 1 MB, which the firmware keeps in PSRAM.)

Recommendation: one static 128 KB arena (`scene_arena_bytes(SCENE_LAVA, 536, 240)`) in **internal**
SRAM if it can be spared, otherwise PSRAM; at the default scale every scene needs ≤ 34 KB, so an
internal 40 KB arena plus a PSRAM fallback for `scale=2`/`scale=3` requests also works. Keep `scene_t`
(it holds the colour table) in internal RAM.

### Driving it from the firmware

```c
/* IMU task, 50 Hz */
float g[3];
scene_gravity_from_imu(&SCENE_IMU_AXIS_MAP, ax_g, ay_g, az_g, g);   /* raw QMI8658 reading, in g */
latest_g = g;                                                        /* keep the latest sample */

/* render task, at the frame rate (target >= 25 fps) */
float dt = (now_us - last_us) * 1e-6f;  if (dt > 0.05f) dt = 0.05f;  /* also clamped inside */
scene_step(&s, latest_g[0], latest_g[1], latest_g[2], dt);
scene_rect_t d; scene_render(&s, fb, 536, 240, &d);
if (d.w && d.h) flush_rect(fb, d);       /* grid scenes: whole frame; balls: union of moved areas */
```

* Step at the render rate, not the IMU rate: the scenes sub-step internally (CA steps from a rate
  accumulator, balls at <= 1/240 s), so dt between 10 and 50 ms is fine and frame-rate independent.
  A 50 Hz IMU is plenty: the low-pass that defines "down" has a 100 ms time constant; the shake
  detector uses the residual (`|g - lowpass| > 0.35 g` after a 0.06 g noise dead zone) and fires at most
  every 150 ms. Feed the newest sample each frame; no extra filtering is needed (and would dull the knocks).
* Face up (|gz| ≈ 1, in-plane gravity < 0.4 g): a slowly wandering 0.3 g drift is blended in so scenes
  keep moving gently (balls get 0.12 g); fire and lava drift around "up".
* `scene_render` writes only the top-left `min(w,fb_w) × min(h,fb_h)` pixels. The dirty rect is relative
  to the previous render **into the same buffer**: after a transition/fade, an overlay, or when
  alternating between two framebuffers, call `scene_invalidate()` before rendering (or render full
  frames always and ignore the rect). The first render after init is always full.
* Seeds: use anything (e.g. `esp_random()` for variety, a constant for reproducible screenshots).
  Same seed + same input sequence ⇒ identical frames on the same build (tests rely on it).

### Axis mapping

`scene_step` wants the direction things fall in the display frame: +x right, +y down (toward the bottom
edge of the landscape image), +z out of the glass; upright clip ⇒ (0, 1, 0), lying face up ⇒ (0, 0, -1).
An accelerometer reports specific force (+1 g on the axis pointing **up** at rest), so the mapping
includes a sign flip. It is a signed permutation matrix, `SCENE_IMU_AXIS_MAP` in `src/scene.c`:
`g_display[i] = Σ_j m[i][j] · reading[j]`.

The QMI8658 mounting orientation relative to the landscape panel is not documented (docs/HARDWARE.md),
so `SCENE_IMU_AXIS_MAP` is currently a **placeholder** (`g = -reading`). Bring-up:

1. Log one averaged reading with the clip upright (landscape, image readable, vertical) and one lying
   face up (glass to the sky).
2. `scene_axis_map_calibrate(upright, face_up, &m)` derives the matrix (display frame is left-handed,
   chip frame right-handed: `row_x = row_y × row_z`); print `m` and paste it into `SCENE_IMU_AXIS_MAP`.
3. Check: tilting the right edge down must give `g[0] ≈ +1`.

### How the scenes work

* **Gravity in any direction (sand, water, snow).** The effective in-plane gravity angle is quantised to
  the 8 compass directions with per-cell dithering between the two bracketing directions, so 30° really
  flows at 30° on average. Loops run downstream-first along the dominant axis with a parity bit per
  cell (each cell moves once per step). Moves within ~50° of gravity are always allowed; moves 50°–88°
  off gravity ("rolling over a neighbour") only if the grain keeps falling from there — this gives a ~45°
  angle of repose at any tilt, and a slab avalanches once tilted past it. Falling grains move up to 2
  (sand) / 3 (water) cells per step.
* **Water** adds lateral spreading along the level directions (never uphill) with a remembered flow
  direction, plus "communicating vessels" leveling: up to 2600 cells/s (scaled by gravity) are moved
  from the highest surface points straight to the lowest resting holes while the level difference
  exceeds 3 cells (so the surface calms down instead of shimmering). Inside, water is shaded by depth
  below the surface (computed along gravity) with a few twinkling sparkle cells near the surface.
  Mass is exactly conserved (also for sand); shakes fling surface cells along the knock.
* **Snow**: float flakes (wobble perpendicular to gravity, parallax speed/brightness) settle into a
  sticky granular layer that slides reluctantly; snowfall continues while the drifts are below a cap
  and the surface slowly melts above it; shakes puff surface snow back into flakes.
* **Fire**: every cell pulls heat from its downstream neighbour (2:1:1 blend across the flow) minus a
  decay from a smooth noise "cooling map" that scrolls with the flames (tongues); cells whose source
  is outside the grid read a flickering source line around the perimeter, so the edges facing down
  burn: the bottom upright, bottom + side at 45°, the side when the clip lies on its edge (a slight
  tilt does not light the walls). Shakes flare it up and throw sparks. Three ramps: classic, blue, emerald.
* **Lava**: metaball blobs (field `K·(1-d²/R²)²`, iso level 256) plus a pool along the bottom edge
  relative to gravity; blobs heat in the pool, rise with buoyancy ∝ temperature, cool near the top and
  sink. Inside the iso level the colour runs from a darker crust at the edge to a hot core; outside a faint glow.
* **Balls**: px/s physics (1 g ≈ 5.8 × height px/s², ~1400 px/s² on the panel), restitution from
  `bounce`, slow impacts absorbed (no micro-bouncing), impulse + positional ball-ball collisions, a
  velocity kick along the knock, highlight lit from "up", optional 4-sample trail; a hard wall impact
  flattens the ball for exactly one rendered frame. Rendering clears and redraws only the union of
  changed regions (resting balls produce an empty dirty rect).
* **Words** (§5b.1, `src/scene_words.c`): `scene_words_set_sprites()` finds each frame's tight box of non-black
  pixels (frames without ink are skipped) and places the words over the upper part of the screen from the seed,
  apart when there is room; they fall in. Each word is an axis-aligned rectangle that never rotates. Physics as the
  balls (px/s, ≤ 1/240 s sub-steps, 1 g ≈ 1392 px/s², shake kicks, impacts under 45 px/s absorbed): wall bounces
  with restitution `bounce`/100; word–word contacts separate along the axis of least penetration (by mass = area)
  with an impulse along it and Coulomb friction (μ 0.6) along the other axis, 8 passes per sub-step so stacks
  converge; static friction on a support the pull presses into (a word on a gentle slope does not creep); a slow word
  held by its supports is stopped. So the words come to rest side by side or stacked, readable, when the clip is
  still. Rendering: black ground, each sprite copied at an integer position (black pixels pass through); a drawn
  position moves only when the word is more than 0.6 px from it (resting words never shimmer); the dirty rect is the
  union of the moved words' old and new rectangles (empty at rest). `scene_follows_orientation(SCENE_WORDS)` is true:
  unlike the other scenes it flips with the panel, and gets `scene_gravity_flipped()` gravity when flipped.
  Tests (`test_scene.c`): the ink boxes and skipped empty frames, the sprite pixels at the drawn position with a hole
  passing through, an all-black sheet, the limits (13 frames, 537 wide, 241 tall, 12×536×81 px refused,
  12×536×80 accepted, NULL frames, another kind), no sprites = black; one word at rest on the floor under 1 g after
  1.33 s and still 5 s later with an empty dirty rect, held by friction on a 0.3 g tilt, sliding into the corner on a
  steep one; first rebounds 0.00 / 0.60 / 1.00 of the impact speed for bounce 0 / 60 / 100; the four edges; 2, 7 and
  12 words settled with at most 0.013 px overlap and no motion, again after a shake, and at the framebuffer's top
  with flipped gravity; plus every generic test (hostile input on seven geometries, determinism, incremental =
  full rendering).

### Performance

Host (Apple M1 Max, one core, `scene_preview --bench`, 536×240, tilt-slow script, 25 fps):

| scene | step | render | total / frame |
|---|---|---|---|
| sand (crisp / smooth) | 47 / 56 µs | 13 / 32 µs | 61 / 88 µs |
| water | 49 µs | 21 µs | 70 µs |
| snow | 19 µs | 12 µs | 31 µs |
| fire (crisp / smooth) | 44 / 47 µs | 8 / 23 µs | 52 / 69 µs |
| lava (smooth default / crisp) | 0.2 µs | 31 / 18 µs | 31 / 18 µs |
| balls 12 / 16 / 24+trail | 2 / 4 / 8 µs | 27 / 37 / 80 µs (20–33 % dirty) | 29 / 41 / 88 µs |

ESP32-S3 @ 240 MHz estimates (instruction-count model from the `xtensa-esp32s3-elf-gcc -O2` output of
the inner loops: ~8 cycles per empty cell visit, ~70–90 per moving grain, ~45 per fire cell; not yet
measured on hardware — time `scene_step`/`scene_render` with `esp_cpu_get_cycle_count()`):

| scene, 25 fps | step | render, fb in internal RAM / PSRAM | total |
|---|---|---|---|
| sand | ~0.5 M cycles (2.0 ms) | 0.3 / 3.4 ms | 2.5 – 5.6 ms |
| water | ~0.7 M (3.0 ms) | 0.4 / 3.5 ms | 3.4 – 6.5 ms |
| snow | ~0.25 M (1.0 ms) | 0.3 / 3.4 ms | 1.3 – 4.4 ms |
| fire | ~0.58 M (2.4 ms) | 0.3 / 3.4 ms | 2.7 – 5.8 ms |
| lava (smooth) | ~0.2 M (0.8 ms) | 1.0 / 4.2 ms | 1.8 – 5.0 ms |
| balls ×16 | ~25 k (0.1 ms) | 1.0 / 1.7 ms | 1.1 – 1.8 ms |

The grid renderer builds one pixel row of blocks in the arena's line buffer (two 32-bit stores per cell
at scale 4) and `memcpy`s it to the `scale` framebuffer rows, so a PSRAM framebuffer sees only
sequential writes and the cost is dominated by PSRAM write bandwidth (257 KB per frame). Inner loops are
integer-only with table lookups, pointer iteration and a register-local xorshift; float math is used
per frame, per particle/blob/ball and per anti-aliased edge pixel, never per cell; there is no division in
any per-cell loop. Code size ~33 KB (xtensa -O2), no libm.

### Previews

`tools/previews-scenes/make_previews.sh` writes `tools/previews-scenes/out/<scene>-<palette>-<script>.gif`
(+ `-sheet.png`) for review; the scripts are `tilt-slow.txt` (rock ±65°), `flip.txt` (right edge,
upside down, left edge, back), `shake.txt` (sharp jolts) and `faceup.txt` (lying flat, then picked up).
