/* scene_preview — run a live scene (core/scene.h) under a scripted tilt and write PNG frames.
 *
 *   scene_preview KIND [--param k=v ...] --script TILT.txt [--fps 20] [--seconds 6] --out DIR
 *                 [--seed N] [--size WxH] [--noise G] [--sheet FILE.png] [--every N] [--bench]
 *
 * TILT.txt: one keyframe per line, `t gx gy gz` (seconds, gravity in g in the display frame:
 * +x right, +y down, +z out of the glass). Values are interpolated linearly; '#' starts a comment.
 * Frames are DIR/frame_0000.png ... at 536x240 (or --size). The scene is stepped once per frame with
 * dt = 1/fps (what the firmware does), with optional Gaussian-ish IMU noise (--noise, default 0.015 g).
 * --sheet writes a contact sheet of 12 evenly spaced frames. --bench skips PNG output and prints
 * per-frame step/render timings (host). --every N writes only every N-th frame. */
#include "scene.h"
#include "common/toolutil.h"
#include <time.h>
#include <sys/stat.h>

#define MAXKEYS 512

typedef struct { float t, g[3]; } key_t_;
static key_t_ keys[MAXKEYS];
static int nkeys;

static void load_script(const char *path) {
    size_t n;
    char *txt = (char *)read_file(path, &n);
    char *p = txt;
    while (*p) {
        char *line = p;
        while (*p && *p != '\n') p++;
        if (*p) *p++ = 0;
        char *hash = strchr(line, '#');
        if (hash) *hash = 0;
        float t, x, y, z;
        if (sscanf(line, "%f %f %f %f", &t, &x, &y, &z) == 4) {
            if (nkeys >= MAXKEYS) die("%s: too many keyframes", path);
            if (nkeys && t < keys[nkeys - 1].t) die("%s: keyframes must be sorted by time", path);
            keys[nkeys].t = t;
            keys[nkeys].g[0] = x; keys[nkeys].g[1] = y; keys[nkeys].g[2] = z;
            nkeys++;
        }
    }
    free(txt);
    if (!nkeys) die("%s: no keyframes", path);
}

static void sample(float t, float g[3]) {
    if (t <= keys[0].t) { memcpy(g, keys[0].g, sizeof keys[0].g); return; }
    for (int i = 1; i < nkeys; i++)
        if (t <= keys[i].t) {
            float span = keys[i].t - keys[i - 1].t;
            float a = span > 0 ? (t - keys[i - 1].t) / span : 1.0f;
            for (int k = 0; k < 3; k++) g[k] = keys[i - 1].g[k] + (keys[i].g[k] - keys[i - 1].g[k]) * a;
            return;
        }
    memcpy(g, keys[nkeys - 1].g, sizeof keys[0].g);
}

static uint32_t nrng = 0xC0FFEEu;
static float noise(float amp) {   /* sum of 4 uniforms ~ normal, sigma ~ amp */
    float s = 0;
    for (int i = 0; i < 4; i++) {
        nrng ^= nrng << 13; nrng ^= nrng >> 17; nrng ^= nrng << 5;
        s += (float)(nrng >> 8) / 16777216.0f - 0.5f;
    }
    return s * amp * 1.732f;
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: scene_preview KIND [--param k=v ...] --script TILT.txt [--fps 20] [--seconds 6]"
                        " --out DIR [--seed N] [--size WxH] [--noise G] [--sheet FILE.png] [--every N] [--bench]\n"
                        "kinds:");
        for (size_t i = 0; i < scene_count(); i++) fprintf(stderr, " %s", scene_info(i)->id);
        fprintf(stderr, "\n");
        return 2;
    }
    const scene_info_t *info = scene_find(argv[1]);
    if (!info) die("unknown scene '%s'", argv[1]);
    scene_params_t params;
    scene_params_clear(&params);
    const char *script = NULL, *out = NULL, *sheet = NULL;
    float fps = 20, seconds = 6, noise_g = 0.015f;
    uint32_t seed = 1;
    int W = 536, H = 240, every = 1, bench = 0;
    for (int i = 2; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--param") && i + 1 < argc) {
            char kv[64];
            snprintf(kv, sizeof kv, "%s", argv[++i]);
            char *eq = strchr(kv, '=');
            if (!eq) die("--param expects key=value");
            *eq = 0;
            if (!scene_params_set(&params, kv, eq + 1)) die("bad --param %s", argv[i]);
        } else if (!strcmp(a, "--script") && i + 1 < argc) script = argv[++i];
        else if (!strcmp(a, "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(a, "--sheet") && i + 1 < argc) sheet = argv[++i];
        else if (!strcmp(a, "--fps") && i + 1 < argc) fps = (float)atof(argv[++i]);
        else if (!strcmp(a, "--seconds") && i + 1 < argc) seconds = (float)atof(argv[++i]);
        else if (!strcmp(a, "--noise") && i + 1 < argc) noise_g = (float)atof(argv[++i]);
        else if (!strcmp(a, "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(a, "--every") && i + 1 < argc) every = atoi(argv[++i]);
        else if (!strcmp(a, "--size") && i + 1 < argc) {
            if (sscanf(argv[++i], "%dx%d", &W, &H) != 2) die("--size expects WxH");
        } else if (!strcmp(a, "--bench")) bench = 1;
        else die("unknown option %s", a);
    }
    if (!script) die("--script is required");
    if (!out && !bench && !sheet) die("--out (or --sheet / --bench) is required");
    if (fps <= 0 || fps > 240) die("bad --fps");
    if (W < SCENE_MIN_DIM || H < SCENE_MIN_DIM || W > SCENE_MAX_DIM || H > SCENE_MAX_DIM) die("bad --size");
    if (every < 1) every = 1;
    load_script(script);
    if (out && !bench) mkdir(out, 0755);

    size_t need = scene_arena_bytes_for((scene_kind_t)info->kind, &params, (uint16_t)W, (uint16_t)H);
    size_t worst = scene_arena_bytes((scene_kind_t)info->kind, (uint16_t)W, (uint16_t)H);
    uint32_t *arena = xmalloc(need + 4);
    scene_t s;
    scene_status_t st = scene_init(&s, (scene_kind_t)info->kind, &params, (uint16_t)W, (uint16_t)H, seed, arena, need);
    if (st != SCENE_OK) die("scene_init failed (%d)", (int)st);
    fprintf(stderr, "%s %dx%d: arena %zu bytes (worst case over params %zu), scene_t %zu bytes\n", info->id, W, H, need,
            worst, sizeof(scene_t));

    uint16_t *fb = xmalloc((size_t)W * H * 2);
    int frames = (int)(seconds * fps + 0.5f);
    float dt = 1.0f / fps;
    enum { SHEET_N = 12, SHEET_COLS = 3 };
    uint16_t *sheet_px = NULL;
    int sheet_w = W * SHEET_COLS, sheet_h = H * (SHEET_N / SHEET_COLS), sheet_next = 0;
    if (sheet) {
        sheet_px = xmalloc((size_t)sheet_w * sheet_h * 2);
        memset(sheet_px, 0, (size_t)sheet_w * sheet_h * 2);
    }
    double t_step = 0, t_render = 0, worst_frame = 0;
    long dirty_px = 0;
    for (int f = 0; f < frames; f++) {
        float g[3];
        sample((float)f * dt, g);
        for (int k = 0; k < 3; k++) g[k] += noise(noise_g);
        double t0 = now_s();
        scene_step(&s, g[0], g[1], g[2], dt);
        double t1 = now_s();
        scene_rect_t d;
        scene_render(&s, fb, (uint16_t)W, (uint16_t)H, &d);
        double t2 = now_s();
        t_step += t1 - t0;
        t_render += t2 - t1;
        if (t2 - t0 > worst_frame) worst_frame = t2 - t0;
        dirty_px += (long)d.w * d.h;
        if (out && !bench && f % every == 0) {
            char path[1024];
            snprintf(path, sizeof path, "%s/frame_%04d.png", out, f / every);
            write_png_565(path, fb, W, H, W, 1);
        }
        if (sheet_px && sheet_next < SHEET_N && f >= (sheet_next * (frames - 1)) / (SHEET_N - 1)) {
            int ox = (sheet_next % SHEET_COLS) * W, oy = (sheet_next / SHEET_COLS) * H;
            for (int y = 0; y < H; y++) memcpy(sheet_px + (size_t)(oy + y) * sheet_w + ox, fb + (size_t)y * W, (size_t)W * 2);
            /* 1 px grey separator */
            for (int y = 0; y < H; y++) sheet_px[(size_t)(oy + y) * sheet_w + ox] = be565_from_rgb565(0x4208);
            for (int x = 0; x < W; x++) sheet_px[(size_t)oy * sheet_w + ox + x] = be565_from_rgb565(0x4208);
            sheet_next++;
        }
    }
    if (sheet_px) write_png_565(sheet, sheet_px, sheet_w, sheet_h, sheet_w, 1);
    printf("%-6s %dx%d frames=%d step=%.1f us render=%.1f us total=%.1f us/frame (worst %.1f us) dirty=%.0f%%\n",
           info->id, W, H, frames, t_step / frames * 1e6, t_render / frames * 1e6, (t_step + t_render) / frames * 1e6,
           worst_frame * 1e6, 100.0 * dirty_px / ((double)frames * W * H));
    free(fb);
    free(arena);
    free(sheet_px);
    return 0;
}
