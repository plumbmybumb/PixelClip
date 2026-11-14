/* rsvp_preview — render Reader mode (PROTOCOL §5c) words exactly as the device paints them.
 *
 *   rsvp_preview FONT.json ATLAS_DIR TEXT.txt --out DIR [--words N] [--from K] [--wpm W] [--scale S]
 *                [--sheet SHEET.png] [--bench]
 *
 * The atlases named in the font document are read from ATLAS_DIR/<id>.hca. The text is tokenised like
 * the firmware does on upload (title line first, RSVP_TOK_TITLE_BREAK) and words K..K+N-1 are painted
 * with rsvp_paint into a 536x240 framebuffer (same painter state carried from word to word, so the
 * partial repaints are exercised) and written as DIR/word_NNNN.png. Also writes DIR/paused.png (the
 * first word with the pause mark) and DIR/end_card.png. --sheet writes a contact sheet of up to 12
 * words. Prints each word's timing, size choice and dirty rectangle. */
#include "rsvp.h"
#include "common/toolutil.h"
#include <time.h>

#define FB_W 536
#define FB_H 240

static uint8_t *open_atlas(const char *dir, const char *id, hca_asset_t *a) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s.hca", dir, id);
    size_t n;
    uint8_t *d = read_file(path, &n);
    hca_status_t st = hca_open(a, d, n);
    if (st != HCA_OK) die("%s: %s", path, hca_status_str(st));
    return d;
}

static double now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static void flags_str(const rsvp_word_t *w, char *out) {
    out[0] = '\0';
    if (w->flags & RSVP_F_COMMA) strcat(out, " comma");
    if (w->flags & RSVP_F_SENTENCE) strcat(out, " sentence");
    if (w->flags & RSVP_F_PARA) strcat(out, " para");
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: rsvp_preview FONT.json ATLAS_DIR TEXT.txt --out DIR [--words N] [--from K] [--wpm W]"
                        " [--scale S] [--sheet SHEET.png] [--bench]\n");
        return 2;
    }
    const char *out = NULL, *sheet = NULL;
    long nwords = 12, from = 0;
    int wpm = RSVP_WPM_DEFAULT, scale = 1;
    bool bench = false;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--words") && i + 1 < argc) nwords = atol(argv[++i]);
        else if (!strcmp(argv[i], "--from") && i + 1 < argc) from = atol(argv[++i]);
        else if (!strcmp(argv[i], "--wpm") && i + 1 < argc) wpm = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--scale") && i + 1 < argc) scale = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--sheet") && i + 1 < argc) sheet = argv[++i];
        else if (!strcmp(argv[i], "--bench")) bench = true;
        else die("unknown option %s", argv[i]);
    }
    if (!out && !bench) die("--out DIR is required");
    if (nwords < 0 || from < 0) die("bad --words / --from");

    size_t jl;
    uint8_t *json = read_file(argv[1], &jl);
    static rsvp_font_t font;
    char err[96];
    if (rsvp_font_parse((const char *)json, jl, &font, err, sizeof err) != RSVP_OK) die("%s: %s", argv[1], err);
    hca_asset_t a[4];
    uint8_t *ad[4] = { 0 };
    ad[0] = open_atlas(argv[2], font.normal.atlas_white, &a[0]);
    ad[1] = open_atlas(argv[2], font.normal.atlas_accent, &a[1]);
    if (font.has_compact) {
        ad[2] = open_atlas(argv[2], font.compact.atlas_white, &a[2]);
        ad[3] = open_atlas(argv[2], font.compact.atlas_accent, &a[3]);
    }
    rsvp_status_t bs = rsvp_font_bind(&font, &a[0], &a[1], font.has_compact ? &a[2] : NULL, font.has_compact ? &a[3] : NULL);
    if (bs != RSVP_OK) die("bind: %s", rsvp_status_str(bs));
    size_t sp = rsvp_font_scratch_px(&font);
    uint16_t *scratch = xmalloc(sp * 2);

    size_t tl;
    uint8_t *text = read_file(argv[3], &tl);
    char title[RSVP_TITLE_MAX];
    rsvp_title((const char *)text, tl, title, sizeof title);
    /* tokenise like the firmware's upload pass */
    size_t cap = 1024, n = 0;
    rsvp_word_t *words = xmalloc(cap * sizeof *words);
    rsvp_tok_t tk;
    rsvp_tok_init(&tk, 0, RSVP_TOK_TITLE_BREAK);
    size_t pos = 0;
    rsvp_word_t tmp[64];
    for (;;) {
        size_t used = 0, k;
        if (pos < tl) {
            k = rsvp_tok_feed(&tk, (const char *)text + pos, tl - pos, &used, tmp, 64);
            pos += used;
        } else {
            k = rsvp_tok_finish(&tk, tmp, 64);
        }
        for (size_t i = 0; i < k; i++) {
            if (n == cap) {
                cap *= 2;
                words = realloc(words, cap * sizeof *words);
                if (!words) die("out of memory");
            }
            words[n++] = tmp[i];
        }
        if (pos >= tl && k == 0) break;
    }
    const rsvp_stats_t *st = rsvp_tok_stats(&tk);
    uint64_t total = rsvp_total_ms(st->factor_x10, st->paragraphs, (uint16_t)wpm);
    printf("text: \"%s\", %zu bytes, %u words, %u sentences, %u paragraphs, %u invalid UTF-8; %llu ms at %d wpm"
           " (end card: %u min)\n", title, tl, (unsigned)st->words, (unsigned)st->sentences, (unsigned)st->paragraphs,
           (unsigned)st->invalid, (unsigned long long)total, wpm, (unsigned)rsvp_minutes(total));
    printf("font: normal %ux%u (%u glyphs)%s, scratch %zu px\n", font.normal.cell_w, font.normal.cell_h, font.normal.count,
           font.compact_bound ? ", compact bound" : "", sp);

    static uint16_t fb[FB_W * FB_H];
    rsvp_painter_t p;
    rsvp_painter_init(&p, &font, FB_W, FB_H, RSVP_ORP_X);
    printf("band y=%d h=%d, baseline %d, ORP column %d\n", p.band_y, p.band_h, p.baseline_y, p.orp_x);

    if (bench) {
        const int N = 5000;
        rsvp_rect_t d;
        double t0 = now_us();
        for (int i = 0; i < N; i++) {
            const rsvp_word_t *w = &words[(size_t)i % (n ? n : 1)];
            if (n) rsvp_paint(&p, &font, (const char *)text + w->off, w->len, fb, scratch, sp, &d, NULL);
        }
        printf("bench: %.2f us per word (layout + paint)\n", (now_us() - t0) / N);
    }
    if (!out) return 0;

    long end = from + nwords;
    if (end > (long)n) end = (long)n;
    int shots = 0;
    uint16_t *sheet_px = NULL;
    const int cols = 3, rows = 4;
    if (sheet) sheet_px = calloc((size_t)FB_W * cols * FB_H * rows, 2);
    char path[4096];
    for (long i = from; i < end; i++) {
        const rsvp_word_t *w = &words[i];
        rsvp_rect_t d;
        rsvp_layout_t lay;
        int fails = rsvp_paint(&p, &font, (const char *)text + w->off, w->len, fb, scratch, sp, &d, &lay);
        char fl[40];
        flags_str(w, fl);
        printf("word %4ld  %-20.*s %3u ms%s%s  orp %u%s%s%s  dirty %d,%d %dx%d%s\n", i, (int)w->len,
               (const char *)text + w->off, (unsigned)rsvp_word_ms(w, (uint16_t)wpm),
               rsvp_blank_ms(w) ? " +300 ms blank" : "", fl, lay.orp, lay.compact ? " compact" : "",
               lay.shifted ? " shifted" : "", lay.clipped ? " clipped" : "", d.x, d.y, d.w, d.h,
               fails ? " (glyph decode failures)" : "");
        snprintf(path, sizeof path, "%s/word_%04ld.png", out, i);
        write_png_565(path, fb, FB_W, FB_H, FB_W, scale);
        if (sheet_px && shots < cols * rows) {
            int cx = shots % cols, cy = shots / cols;
            for (int y = 0; y < FB_H; y++)
                memcpy(sheet_px + ((size_t)(cy * FB_H + y) * FB_W * cols) + (size_t)cx * FB_W, fb + (size_t)y * FB_W, FB_W * 2);
        }
        shots++;
    }
    /* paused: first painted word + the mark */
    if (from < (long)n) {
        rsvp_painter_t q;
        rsvp_painter_init(&q, &font, FB_W, FB_H, RSVP_ORP_X);
        rsvp_rect_t d;
        rsvp_paint(&q, &font, (const char *)text + words[from].off, words[from].len, fb, scratch, sp, &d, NULL);
        rsvp_paint_pause(&q, &font, true, fb, scratch, sp, &d);
        snprintf(path, sizeof path, "%s/paused.png", out);
        write_png_565(path, fb, FB_W, FB_H, FB_W, scale);
    }
    rsvp_rect_t d;
    int missing = rsvp_paint_end_card(&p, &font, st->words, rsvp_minutes(total), fb, scratch, sp, &d);
    snprintf(path, sizeof path, "%s/end_card.png", out);
    write_png_565(path, fb, FB_W, FB_H, FB_W, scale);
    printf("end card: %u words, %u min%s\n", (unsigned)st->words, (unsigned)rsvp_minutes(total),
           missing ? " (some glyphs substituted with '?')" : "");
    if (sheet_px) {
        write_png_565(sheet, sheet_px, FB_W * cols, FB_H * rows, FB_W * cols, 1);
        printf("wrote %s\n", sheet);
        free(sheet_px);
    }
    printf("wrote %d word frames + paused.png + end_card.png to %s\n", shots, out);
    for (int i = 0; i < 4; i++) free(ad[i]);
    free(scratch); free(words); free(text); free(json);
    return 0;
}
