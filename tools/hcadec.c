/* hcadec — decode .hca frames to PNG for eyeballing.
 *   hcadec FILE.hca OUT.png [FRAME]       decode one frame (default 0)
 *   hcadec FILE.hca OUT.png --strip       all frames side by side (handy for glyph atlases)
 *   hcadec FILE.hca OUT.png --all         OUT-000.png, OUT-001.png, ...
 *   --scale N                              nearest-neighbour upscale */
#include "hca.h"
#include "common/toolutil.h"

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: hcadec FILE.hca OUT.png [FRAME | --strip | --all] [--scale N]\n");
        return 2;
    }
    int frame = 0, strip = 0, all = 0, scale = 1;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--strip")) strip = 1;
        else if (!strcmp(argv[i], "--all")) all = 1;
        else if (!strcmp(argv[i], "--scale") && i + 1 < argc) scale = atoi(argv[++i]);
        else frame = atoi(argv[i]);
    }
    if (scale < 1 || scale > 16) die("bad --scale");
    size_t size;
    uint8_t *data = read_file(argv[1], &size);
    hca_asset_t a;
    hca_status_t st = hca_open(&a, data, size);
    if (st != HCA_OK) die("%s: %s", argv[1], hca_status_str(st));
    int w = a.hdr.width, h = a.hdr.height, n = a.hdr.frame_count;

    if (strip) {
        int sw = w * n;
        if (sw > 65535) die("strip too wide");
        uint16_t *fb = xmalloc((size_t)sw * h * 2);
        for (int i = 0; i < n; i++) {
            st = hca_decode_frame(&a, (uint16_t)i, fb + (size_t)i * w, (uint16_t)sw);
            if (st != HCA_OK) die("frame %d: %s", i, hca_status_str(st));
        }
        write_png_565(argv[2], fb, sw, h, sw, scale);
        printf("wrote %s (%d frames, %dx%d each)\n", argv[2], n, w, h);
        free(fb);
    } else if (all) {
        uint16_t *fb = xmalloc((size_t)w * h * 2);
        char path[4096];
        const char *dot = strrchr(argv[2], '.');
        int stem = dot ? (int)(dot - argv[2]) : (int)strlen(argv[2]);
        for (int i = 0; i < n; i++) {
            st = hca_decode_frame(&a, (uint16_t)i, fb, (uint16_t)w);
            if (st != HCA_OK) die("frame %d: %s", i, hca_status_str(st));
            snprintf(path, sizeof path, "%.*s-%03d.png", stem, argv[2], i);
            write_png_565(path, fb, w, h, w, scale);
        }
        printf("wrote %d frames as %.*s-NNN.png\n", n, stem, argv[2]);
        free(fb);
    } else {
        if (frame < 0 || frame >= n) die("frame %d out of range (0..%d)", frame, n - 1);
        uint16_t *fb = xmalloc((size_t)w * h * 2);
        st = hca_decode_frame(&a, (uint16_t)frame, fb, (uint16_t)w);
        if (st != HCA_OK) die("frame %d: %s", frame, hca_status_str(st));
        write_png_565(argv[2], fb, w, h, w, scale);
        printf("wrote %s (frame %d of %d, %dx%d)\n", argv[2], frame, n, w, h);
        free(fb);
    }
    free(data);
    return 0;
}
