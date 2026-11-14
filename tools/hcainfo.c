/* hcainfo — print an .hca header, frame table and compression ratio; validates every frame.
 *   hcainfo FILE.hca [-q]      exit status 0 = valid, 1 = invalid */
#include "hca.h"
#include "common/toolutil.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: hcainfo FILE.hca [-q]\n");
        return 2;
    }
    int quiet = argc > 2 && !strcmp(argv[2], "-q");
    size_t size;
    uint8_t *data = read_file(argv[1], &size);
    hca_asset_t a;
    hca_status_t st = hca_open(&a, data, size);
    if (st != HCA_OK) {
        printf("%s: INVALID (%s)\n", argv[1], hca_status_str(st));
        return 1;
    }
    const hca_header_t *h = &a.hdr;
    printf("%s\n", argv[1]);
    printf("  size          %zu bytes (data_size %u%s)\n", size, h->data_size,
           size == h->data_size ? "" : size < h->data_size ? ", FILE TRUNCATED" : ", trailing bytes");
    printf("  geometry      %u x %u, %u frame%s\n", h->width, h->height, h->frame_count, h->frame_count == 1 ? "" : "s");
    printf("  pixel format  %u (%s)\n", h->pixel_format, h->pixel_format == 0 ? "RGB565BE" : "?");
    printf("  compression   %u (%s)\n", h->compression, h->compression == 0 ? "raw" : "RLE16");
    printf("  loop_count    %u%s\n", h->loop_count, h->loop_count == 0 ? " (forever)" : "");
    printf("  flags         0x%04x%s\n", h->flags, (h->flags & HCA_FLAG_GLYPH_ATLAS) ? " (glyph atlas)" : "");

    size_t npx = (size_t)h->width * h->height;
    uint16_t *buf = xmalloc(npx * 2);
    int bad = size < h->data_size;
    uint64_t total_ms = 0, comp_total = 0;
    if (!quiet) printf("  %5s %10s %10s %7s %8s  %s\n", "frame", "offset", "length", "ratio", "dur_ms", "status");
    for (uint16_t i = 0; i < h->frame_count; i++) {
        hca_frame_info_t fi;
        hca_frame_info(&a, i, &fi);
        st = hca_decode_frame(&a, i, buf, h->width);
        if (st != HCA_OK) bad = 1;
        comp_total += fi.length;
        total_ms += hca_frame_duration(&a, i, 100);
        if (!quiet)
            printf("  %5u %10u %10u %6.2f%% %8u  %s\n", i, fi.offset, fi.length, 100.0 * fi.length / (double)(npx * 2),
                   fi.duration_ms, st == HCA_OK ? "ok" : hca_status_str(st));
    }
    double raw_total = (double)npx * 2 * h->frame_count;
    printf("  frames total  %llu bytes compressed vs %.0f raw: %.2f%% (%.1fx), file %.2f%% of raw\n",
           (unsigned long long)comp_total, raw_total, 100.0 * (double)comp_total / raw_total,
           comp_total ? raw_total / (double)comp_total : 0.0, 100.0 * (double)h->data_size / raw_total);
    printf("  avg frame     %.0f bytes; animation length %.2f s (0 ms entries counted as 100 ms)\n",
           (double)comp_total / h->frame_count, (double)total_ms / 1000.0);
    printf("  status        %s\n", bad ? "INVALID" : "valid");
    free(buf);
    free(data);
    return bad;
}
