/* mkfixtures — render placeholder test images as PNGs (the real art comes from the iOS app).
 *   mkfixtures OUTDIR
 * Writes:
 *   gradient.png            536x240 hue/brightness gradient (exercises dithering)
 *   anim-00..11.png         536x240 moving shapes on black (12-frame animation)
 *   rsvp-{w,a}-NNN.png      reader font (PROTOCOL §5c), normal size: 72x114 cells, baseline 92, a
 *   rsvpc-{w,a}-NNN.png     dot-matrix rendering of the 5x7 font (+ French accents, guillemets, dashes,
 *                           "·", "⏸"), white and brand accent #C6A2FF on black; compact: 44x70, baseline 56
 *   rsvp-font.json          the font document for those atlases (ids rsvp-dot-w/-a, rsvp-dotc-w/-a)
 */
#include "common/toolutil.h"
#include "common/dotfont5x7.h"
#include <stdbool.h>
#include <math.h>

#define W 536
#define H 240

typedef struct { float r, g, b; } col_t;

static uint8_t *img_fill(int w, int h, col_t c) {
    uint8_t *p = xmalloc((size_t)w * h * 3);
    for (size_t i = 0; i < (size_t)w * h; i++) { p[i * 3] = (uint8_t)c.r; p[i * 3 + 1] = (uint8_t)c.g; p[i * 3 + 2] = (uint8_t)c.b; }
    return p;
}
static uint8_t *img_new(int w, int h) { return img_fill(w, h, (col_t){ 0, 0, 0 }); }

static void blend(uint8_t *img, int w, int h, int x, int y, col_t c, float a) {
    if (x < 0 || y < 0 || x >= w || y >= h || a <= 0) return;
    if (a > 1) a = 1;
    uint8_t *p = img + ((size_t)y * w + x) * 3;
    p[0] = (uint8_t)lrintf(p[0] * (1 - a) + c.r * a);
    p[1] = (uint8_t)lrintf(p[1] * (1 - a) + c.g * a);
    p[2] = (uint8_t)lrintf(p[2] * (1 - a) + c.b * a);
}

static void fill_circle(uint8_t *img, int w, int h, float cx, float cy, float r, col_t c) {
    for (int y = (int)(cy - r - 2); y <= (int)(cy + r + 2); y++)
        for (int x = (int)(cx - r - 2); x <= (int)(cx + r + 2); x++) {
            float d = hypotf(x + 0.5f - cx, y + 0.5f - cy);
            blend(img, w, h, x, y, c, r + 0.5f - d);
        }
}

static void round_rect(uint8_t *img, int w, int h, float x0, float y0, float x1, float y1, float r, col_t c) {
    for (int y = (int)y0 - 1; y <= (int)y1 + 1; y++)
        for (int x = (int)x0 - 1; x <= (int)x1 + 1; x++) {
            float px = x + 0.5f, py = y + 0.5f;
            float qx = fmaxf(fmaxf(x0 + r - px, px - (x1 - r)), 0), qy = fmaxf(fmaxf(y0 + r - py, py - (y1 - r)), 0);
            float d = hypotf(qx, qy) - r;
            blend(img, w, h, x, y, c, 0.5f - d);
        }
}

static void save(const char *dir, const char *name, const uint8_t *img, int w, int h) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    write_png_rgb(path, img, w, h);
}

static col_t hsv(float hdeg, float s, float v) {
    float c = v * s, hp = fmodf(hdeg / 60.0f, 6.0f), x = c * (1 - fabsf(fmodf(hp, 2) - 1)), m = v - c;
    float r = 0, g = 0, b = 0;
    if (hp < 1) { r = c; g = x; } else if (hp < 2) { r = x; g = c; } else if (hp < 3) { g = c; b = x; }
    else if (hp < 4) { g = x; b = c; } else if (hp < 5) { r = x; b = c; } else { r = c; b = x; }
    return (col_t){ (r + m) * 255, (g + m) * 255, (b + m) * 255 };
}

/* ---- reader font: dot-matrix glyphs ------------------------------------------------------------
 * A glyph is up to 8 columns of 11 rows (rows -2..8; the classic 5x7 table fills rows 0..6, accents of
 * capitals use rows -2..-1, of lowercase -1..0, cedillas 7..8). Bit (row + 2) of a column word. */
typedef struct { uint32_t cp; uint8_t n; uint16_t col[8]; } dglyph_t;

enum { AC_NONE, AC_ACUTE, AC_GRAVE, AC_CIRC, AC_DIAER, AC_CEDIL };

static dglyph_t dg_ascii(char ch) {
    dglyph_t g = { (uint32_t)(unsigned char)ch, 5, { 0 } };
    for (int c = 0; c < 5; c++) g.col[c] = (uint16_t)(dotfont5x7[ch - 0x20][c] << 2);
    return g;
}
static void dg_dot(dglyph_t *g, int c, int r) { g->col[c] |= (uint16_t)(1u << (r + 2)); }
static dglyph_t dg_accented(uint32_t cp, char base, int accent) {
    dglyph_t g = dg_ascii(base);
    g.cp = cp;
    bool upper = base >= 'A' && base <= 'Z';
    if (base == 'i') {   /* dotless */
        g.col[2] &= (uint16_t)~(1u << 2);
    }
    int r0 = upper ? -2 : -1;
    switch (accent) {
    case AC_ACUTE: dg_dot(&g, 3, r0); dg_dot(&g, 2, r0 + 1); break;
    case AC_GRAVE: dg_dot(&g, 1, r0); dg_dot(&g, 2, r0 + 1); break;
    case AC_CIRC:  dg_dot(&g, 2, r0); dg_dot(&g, 1, r0 + 1); dg_dot(&g, 3, r0 + 1); break;
    case AC_DIAER: dg_dot(&g, 1, r0 + 1); dg_dot(&g, 3, r0 + 1); break;
    case AC_CEDIL: dg_dot(&g, 2, 7); dg_dot(&g, 1, 8); break;
    default: break;
    }
    return g;
}
static dglyph_t dg_cols(uint32_t cp, int n, const uint8_t *cols) {
    dglyph_t g = { cp, (uint8_t)n, { 0 } };
    for (int c = 0; c < n; c++) g.col[c] = (uint16_t)(cols[c] << 2);
    return g;
}

static size_t dg_build(dglyph_t *out) {
    size_t n = 0;
    for (char ch = 0x20; ch <= 0x7E; ch++) out[n++] = dg_ascii(ch);
    static const struct { uint32_t cp; char base; int ac; } acc[] = {
        { 0xE9, 'e', AC_ACUTE }, { 0xE8, 'e', AC_GRAVE }, { 0xEA, 'e', AC_CIRC }, { 0xEB, 'e', AC_DIAER },
        { 0xE0, 'a', AC_GRAVE }, { 0xE2, 'a', AC_CIRC }, { 0xE4, 'a', AC_DIAER }, { 0xEE, 'i', AC_CIRC },
        { 0xEF, 'i', AC_DIAER }, { 0xF4, 'o', AC_CIRC }, { 0xF6, 'o', AC_DIAER }, { 0xF9, 'u', AC_GRAVE },
        { 0xFB, 'u', AC_CIRC }, { 0xFC, 'u', AC_DIAER }, { 0xE7, 'c', AC_CEDIL }, { 0xC9, 'E', AC_ACUTE },
        { 0xC8, 'E', AC_GRAVE }, { 0xCA, 'E', AC_CIRC }, { 0xC0, 'A', AC_GRAVE }, { 0xC2, 'A', AC_CIRC },
        { 0xC7, 'C', AC_CEDIL }, { 0xD4, 'O', AC_CIRC }, { 0xCE, 'I', AC_CIRC }, { 0xD9, 'U', AC_GRAVE },
        { 0xDB, 'U', AC_CIRC },
    };
    for (size_t i = 0; i < sizeof acc / sizeof acc[0]; i++) out[n++] = dg_accented(acc[i].cp, acc[i].base, acc[i].ac);
    static const uint8_t oe[] = { 0x38, 0x44, 0x44, 0x7C, 0x54, 0x54, 0x18 }, OE[] = { 0x3E, 0x41, 0x41, 0x7F, 0x49, 0x49, 0x41 },
        ae[] = { 0x20, 0x54, 0x54, 0x7C, 0x54, 0x54, 0x18 }, laq[] = { 0x08, 0x14, 0x2A, 0x14, 0x22 },
        raq[] = { 0x22, 0x14, 0x2A, 0x14, 0x08 }, rsq[] = { 0x05, 0x03 }, lsq[] = { 0x06, 0x05 },
        ldq[] = { 0x06, 0x05, 0x00, 0x06, 0x05 }, rdq[] = { 0x05, 0x03, 0x00, 0x05, 0x03 },
        ell[] = { 0x40, 0x00, 0x40, 0x00, 0x40 }, en[] = { 0x08, 0x08, 0x08, 0x08, 0x08 },
        em[] = { 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08 }, mid[] = { 0x08 }, pause[] = { 0x7F, 0x7F, 0x00, 0x7F, 0x7F },
        euro[] = { 0x14, 0x3E, 0x55, 0x55, 0x41 }, deg[] = { 0x02, 0x05, 0x02 };
    out[n++] = dg_cols(0x153, 7, oe);
    out[n++] = dg_cols(0x152, 7, OE);
    out[n++] = dg_cols(0xE6, 7, ae);
    out[n++] = dg_cols(0xAB, 5, laq);
    out[n++] = dg_cols(0xBB, 5, raq);
    out[n++] = dg_cols(0x2019, 2, rsq);
    out[n++] = dg_cols(0x2018, 2, lsq);
    out[n++] = dg_cols(0x201C, 5, ldq);
    out[n++] = dg_cols(0x201D, 5, rdq);
    out[n++] = dg_cols(0x2026, 5, ell);
    out[n++] = dg_cols(0x2013, 5, en);
    out[n++] = dg_cols(0x2014, 7, em);
    out[n++] = dg_cols(0xB7, 1, mid);
    out[n++] = dg_cols(0x23F8, 5, pause);
    out[n++] = dg_cols(0x20AC, 5, euro);
    out[n++] = dg_cols(0xB0, 3, deg);
    return n;
}

static void dg_ink(const dglyph_t *g, int *c0, int *c1) {
    *c0 = -1; *c1 = -1;
    for (int c = 0; c < g->n; c++) if (g->col[c]) { if (*c0 < 0) *c0 = c; *c1 = c; }
}

/* Render one size. Returns the advances in adv[]. */
static void dg_render(const char *dir, const char *prefix, const dglyph_t *gs, size_t n, int pitch, int cw, int ch,
                      int *adv) {
    const col_t white = { 255, 255, 255 }, accent = { 0xC6, 0xA2, 0xFF };
    const int top = 2;
    char name[64];
    for (size_t i = 0; i < n; i++) {
        int c0, c1;
        dg_ink(&gs[i], &c0, &c1);
        adv[i] = c0 < 0 ? 3 * pitch : (c1 - c0 + 2) * pitch;
        for (int pass = 0; pass < 2; pass++) {
            uint8_t *img = img_new(cw, ch);
            if (c0 >= 0) {
                for (int c = c0; c <= c1; c++)
                    for (int r = -2; r <= 8; r++) {
                        if (!(gs[i].col[c] & (1u << (r + 2)))) continue;
                        float x0 = (float)(c - c0) * pitch + pitch * 0.09f, y0 = top + (float)(r + 2) * pitch + pitch * 0.09f;
                        round_rect(img, cw, ch, x0, y0, x0 + pitch * 0.82f, y0 + pitch * 0.82f, pitch * 0.28f,
                                   pass ? accent : white);
                    }
            }
            snprintf(name, sizeof name, "%s-%c-%03u.png", prefix, pass ? 'a' : 'w', (unsigned)i);
            save(dir, name, img, cw, ch);
            free(img);
        }
    }
}

static size_t utf8_put(char *o, uint32_t cp) {
    if (cp < 0x80) { o[0] = (char)cp; return 1; }
    if (cp < 0x800) { o[0] = (char)(0xC0 | (cp >> 6)); o[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
    o[0] = (char)(0xE0 | (cp >> 12)); o[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); o[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
}

static void json_face(FILE *f, const dglyph_t *gs, size_t n, const int *adv, int cw, int ch, int base,
                      const char *white, const char *accent) {
    fputs("{\"glyphs\":\"", f);
    for (size_t i = 0; i < n; i++) {
        char u[4];
        size_t k = utf8_put(u, gs[i].cp);
        if (gs[i].cp == '"' || gs[i].cp == '\\') fputc('\\', f);
        fwrite(u, 1, k, f);
    }
    fputs("\",\n \"advance\":[", f);
    for (size_t i = 0; i < n; i++) fprintf(f, "%s%d", i ? "," : "", adv[i]);
    fprintf(f, "],\n \"cell_w\":%d,\"cell_h\":%d,\"baseline\":%d,\"atlas_white\":\"%s\",\"atlas_accent\":\"%s\"", cw, ch,
            base, white, accent);
}

static void make_reader_font(const char *dir) {
    static dglyph_t gs[160];
    static int adv_n[160], adv_c[160];
    size_t n = dg_build(gs);
    /* normal: 10 px dot pitch -> 7 columns 70 px (cell 72), rows -2..8 = 110 px + 2+2 margins, baseline
     * at the bottom of row 6 = 2 + 9*10 = 92; compact: 6 px pitch -> cell 44x70, baseline 56 */
    dg_render(dir, "rsvp", gs, n, 10, 72, 114, adv_n);
    dg_render(dir, "rsvpc", gs, n, 6, 44, 70, adv_c);
    char path[4096];
    snprintf(path, sizeof path, "%s/rsvp-font.json", dir);
    FILE *f = fopen(path, "wb");
    if (!f) die("cannot create %s", path);
    json_face(f, gs, n, adv_n, 72, 114, 92, "rsvp-dot-w", "rsvp-dot-a");
    fputs(",\n \"compact\":", f);
    json_face(f, gs, n, adv_c, 44, 70, 56, "rsvp-dotc-w", "rsvp-dotc-a");
    fputs("}}\n", f);
    if (fclose(f) != 0) die("cannot write %s", path);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: mkfixtures OUTDIR\n");
        return 2;
    }
    const char *dir = argv[1];
    char name[64];

    /* gradient still */
    uint8_t *g = img_new(W, H);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            col_t c = hsv(360.0f * x / W, 1.0f, 1.0f - (float)y / (H - 1));
            uint8_t *p = g + ((size_t)y * W + x) * 3;
            p[0] = (uint8_t)lrintf(c.r); p[1] = (uint8_t)lrintf(c.g); p[2] = (uint8_t)lrintf(c.b);
        }
    save(dir, "gradient.png", g, W, H);
    free(g);

    /* 12-frame animation: orange ball bouncing across, white bar sliding the other way */
    for (int f = 0; f < 12; f++) {
        uint8_t *a = img_new(W, H);
        float t = f / 12.0f;
        fill_circle(a, W, H, 60 + t * 416, 120 - 60 * fabsf(sinf(t * 2 * 3.14159265f)), 28, (col_t){ 255, 126, 46 });
        round_rect(a, W, H, 476 - t * 416 - 30, 200, 476 - t * 416 + 30, 212, 6, (col_t){ 255, 255, 255 });
        snprintf(name, sizeof name, "anim-%02d.png", f);
        save(dir, name, a, W, H);
        free(a);
    }

    make_reader_font(dir);
    return 0;
}
