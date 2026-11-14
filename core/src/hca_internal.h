/* hca_internal.h — private helpers of hca.c (also exercised by the host tests). Not part of the contract. */
#ifndef HCA_INTERNAL_H
#define HCA_INTERNAL_H
#include "hca.h"

/* Decode frame `index` of `a` and blit it with its top-left at (x,y) into `fb` (row stride
 * `fb_stride` pixels), writing only pixels inside the clip rectangle [cx0,cx1) x [cy0,cy1).
 * The caller guarantees the clip rectangle lies inside the framebuffer. Pixels outside the clip
 * are never written. For RLE frames decoding stops as soon as the clip's last row is passed. */
hca_status_t hca__blit_clip(const hca_asset_t *a, uint16_t index, uint16_t *fb, uint16_t fb_stride,
                            int x, int y, int cx0, int cy0, int cx1, int cy1);

/* Fill `n` pixels with value `px` (already in memory byte order). */
void hca__fill16(uint16_t *d, uint16_t px, size_t n);

#endif /* HCA_INTERNAL_H */
