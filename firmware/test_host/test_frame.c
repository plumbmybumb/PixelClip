/* test_frame.c — host unit test for the BLE fast-lane framer / reassembler / request parser
 * (components/ble/pixelclip_frame.c, PROTOCOL §3b). Same golden vectors as scripts/ble_api.py --selftest. */
#include "pixelclip_frame.h"
#include "pixelclip_ble_uuids.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int s_fail, s_checks;
#define CHECK(c) do { s_checks++; if (!(c)) { s_fail++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

#define CAP (PIXELCLIP_BLE_API_MAX_BYTES + ZF_METHOD_MAX + ZF_PATH_MAX + 3)   /* as pixelclip_ble.c API_REQ_CAP */
static uint8_t s_buf[CAP + 1];

/* Frame msg at max_frame and push every frame; returns the last result. */
static zf_rx_result_t push_all(zf_rx_t *rx, const uint8_t *msg, size_t len, size_t max_frame, bool busy, size_t *nframes)
{
    zf_tx_t tx;
    zf_tx_init(&tx, msg, len);
    uint8_t f[ZF_FRAME_MAX];
    size_t n, count = 0;
    zf_rx_result_t r = ZF_MORE;
    while ((n = zf_tx_next(&tx, f, max_frame)) > 0) {
        CHECK(n <= max_frame);
        r = zf_rx_push(rx, f, n, busy);
        count++;
        if (r != ZF_MORE && n && !(f[0] & ZF_HDR_LAST)) break;   /* early error */
    }
    if (nframes) *nframes = count;
    return r;
}

static void test_golden(void)
{
    const char *req = "POST /brightness\n{\"value\":200}";
    static const char *golden[] = { "80504f5354202f627269", "016768746e6573730a7b", "022276616c7565223a32", "4330307d" };
    zf_tx_t tx;
    zf_tx_init(&tx, (const uint8_t *)req, strlen(req));
    uint8_t f[16];
    char hex[40];
    for (int i = 0; i < 4; i++) {
        size_t n = zf_tx_next(&tx, f, 10);
        for (size_t k = 0; k < n; k++) snprintf(hex + 2 * k, 3, "%02x", f[k]);
        hex[2 * n] = 0;
        CHECK(strcmp(hex, golden[i]) == 0);
    }
    CHECK(zf_tx_next(&tx, f, 10) == 0);
    CHECK(zf_frame_count(strlen(req), 10) == 4);
    /* empty message = one header-only frame */
    zf_tx_init(&tx, NULL, 0);
    CHECK(zf_tx_next(&tx, f, 20) == 1 && f[0] == (ZF_HDR_FIRST | ZF_HDR_LAST));
    CHECK(zf_tx_next(&tx, f, 20) == 0);
    CHECK(zf_frame_count(0, 20) == 1);
}

static void test_roundtrip(void)
{
    static uint8_t msg[PIXELCLIP_BLE_API_MAX_BYTES + 200];
    for (size_t i = 0; i < sizeof msg; i++) msg[i] = (uint8_t)(i * 7 + 3);
    const size_t sizes[] = { 2, 3, 20, 182, 244, 509, ZF_FRAME_MAX };
    const size_t lens[] = { 0, 1, 19, 20, 181, 182, 183, 5000, PIXELCLIP_BLE_API_MAX_BYTES, sizeof msg };
    zf_rx_t rx;
    zf_rx_init(&rx, s_buf, CAP);
    for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
        for (size_t l = 0; l < sizeof lens / sizeof lens[0]; l++) {
            size_t nf = 0;
            zf_rx_result_t r = push_all(&rx, msg, lens[l], sizes[s], false, &nf);
            CHECK(r == ZF_DONE);
            CHECK(nf == zf_frame_count(lens[l], sizes[s]));
            CHECK(rx.len == lens[l] && memcmp(rx.buf, msg, lens[l]) == 0 && rx.buf[rx.len] == 0);
            CHECK(rx.state == ZF_RX_IDLE);
        }
    }
    /* > 64 frames: the sequence wraps (and the 64th frame carries 0 again) */
    zf_tx_t tx;
    zf_tx_init(&tx, msg, 1536);
    uint8_t f[20];
    for (int i = 0; i < 65; i++) {
        size_t n = zf_tx_next(&tx, f, 20);
        CHECK(n > 0 && (f[0] & ZF_SEQ_MASK) == (i & ZF_SEQ_MASK));
    }
}

static void test_errors(void)
{
    zf_rx_t rx;
    zf_rx_init(&rx, s_buf, CAP);
    uint8_t first[] = { ZF_HDR_FIRST | 0, 'G', 'E' };
    uint8_t c1[] = { 1, 'T', ' ' };
    uint8_t c2[] = { 2, '/' };
    uint8_t last3[] = { ZF_HDR_LAST | 3, 's' };

    /* gap: 0, 2 -> bad frame once, then silent until the next first frame */
    CHECK(zf_rx_push(&rx, first, sizeof first, false) == ZF_MORE);
    CHECK(zf_rx_push(&rx, c2, sizeof c2, false) == ZF_BAD_FRAME);
    CHECK(zf_rx_push(&rx, last3, sizeof last3, false) == ZF_MORE);
    CHECK(rx.state == ZF_RX_DISCARD);
    /* a fresh request after the error works */
    CHECK(zf_rx_push(&rx, first, sizeof first, false) == ZF_MORE);
    CHECK(zf_rx_push(&rx, c1, sizeof c1, false) == ZF_MORE);
    CHECK(zf_rx_push(&rx, c2, sizeof c2, false) == ZF_MORE);
    CHECK(zf_rx_push(&rx, last3, sizeof last3, false) == ZF_DONE);
    CHECK(rx.len == 6 && memcmp(rx.buf, "GET /s", 6) == 0);

    /* continuation with nothing open */
    CHECK(zf_rx_push(&rx, c1, sizeof c1, false) == ZF_BAD_FRAME);
    CHECK(zf_rx_push(&rx, c2, sizeof c2, false) == ZF_MORE);   /* already reported */
    /* empty frame */
    zf_rx_reset(&rx);
    CHECK(zf_rx_push(&rx, NULL, 0, false) == ZF_BAD_FRAME);
    /* duplicate frame (same seq twice) is a gap too */
    CHECK(zf_rx_push(&rx, first, sizeof first, false) == ZF_MORE);
    CHECK(zf_rx_push(&rx, c1, sizeof c1, false) == ZF_MORE);
    CHECK(zf_rx_push(&rx, c1, sizeof c1, false) == ZF_BAD_FRAME);

    /* new first frame while one is open: the open one is abandoned, the new one completes */
    zf_rx_reset(&rx);
    const uint32_t ab = rx.abandoned;
    CHECK(zf_rx_push(&rx, first, sizeof first, false) == ZF_MORE);
    CHECK(zf_rx_push(&rx, c1, sizeof c1, false) == ZF_MORE);
    uint8_t single[] = { ZF_HDR_FIRST | ZF_HDR_LAST | 5, 'X' };   /* any start sequence is accepted */
    CHECK(zf_rx_push(&rx, single, sizeof single, false) == ZF_DONE);
    CHECK(rx.abandoned == ab + 1 && rx.len == 1 && rx.buf[0] == 'X');

    /* busy at the first frame: consumed without storing, 429 at the last frame, buffer untouched */
    memcpy(s_buf, "KEEP", 5);
    rx.len = 4;
    CHECK(zf_rx_push(&rx, first, sizeof first, true) == ZF_MORE);
    CHECK(memcmp(s_buf, "KEEP", 4) == 0);
    CHECK(zf_rx_push(&rx, c1, sizeof c1, false) == ZF_MORE);   /* busy only matters at the first frame */
    CHECK(zf_rx_push(&rx, c2, sizeof c2, false) == ZF_MORE);
    CHECK(zf_rx_push(&rx, last3, sizeof last3, false) == ZF_BUSY);
    CHECK(memcmp(s_buf, "KEEP", 4) == 0);
    CHECK(rx.state == ZF_RX_IDLE);
    /* a gap inside a rejected request is still a bad frame */
    CHECK(zf_rx_push(&rx, first, sizeof first, true) == ZF_MORE);
    CHECK(zf_rx_push(&rx, c2, sizeof c2, true) == ZF_BAD_FRAME);

    /* too large: one byte over the cap -> TOO_LARGE once, then silent; the next request works */
    static uint8_t big[CAP + 1];
    memset(big, 'a', sizeof big);
    zf_rx_reset(&rx);
    size_t nf = 0;
    CHECK(push_all(&rx, big, CAP, ZF_FRAME_MAX, false, &nf) == ZF_DONE);   /* exactly the cap fits */
    zf_tx_t tx;
    zf_tx_init(&tx, big, sizeof big);
    uint8_t f[ZF_FRAME_MAX];
    size_t n;
    int too_large = 0, other = 0;
    while ((n = zf_tx_next(&tx, f, ZF_FRAME_MAX)) > 0) {
        zf_rx_result_t r = zf_rx_push(&rx, f, n, false);
        if (r == ZF_TOO_LARGE) too_large++;
        else if (r != ZF_MORE) other++;
    }
    CHECK(too_large == 1 && other == 0);
    CHECK(push_all(&rx, (const uint8_t *)"GET /status\n", 12, 20, false, NULL) == ZF_DONE);
}

static void test_parse(void)
{
    char p1[] = "POST /brightness\n{\"value\":200}";
    zf_req_t r;
    CHECK(zf_parse_request(p1, strlen(p1), &r));
    CHECK(strcmp(r.method, "POST") == 0 && strcmp(r.path, "/brightness") == 0);
    CHECK(r.body_len == 13 && strcmp(r.body, "{\"value\":200}") == 0);

    char p2[] = "GET /status";                       /* no LF: no body */
    CHECK(zf_parse_request(p2, strlen(p2), &r) && strcmp(r.path, "/status") == 0 && r.body_len == 0 && *r.body == 0);
    char p3[] = "GET /status\n";
    CHECK(zf_parse_request(p3, strlen(p3), &r) && strcmp(r.path, "/status") == 0 && r.body_len == 0);
    char p4[] = "PUT /config\r\n{}";                 /* CR tolerated */
    CHECK(zf_parse_request(p4, strlen(p4), &r) && strcmp(r.path, "/config") == 0 && r.body_len == 2);
    char p5[] = "GET /texts?x=1\n";
    CHECK(zf_parse_request(p5, strlen(p5), &r) && strcmp(r.path, "/texts?x=1") == 0);
    char p6[] = "DELETE /assets/a-1\n";
    CHECK(zf_parse_request(p6, strlen(p6), &r) && strcmp(r.method, "DELETE") == 0);
    char p7[] = "POST /show/heart\n";
    CHECK(zf_parse_request(p7, strlen(p7), &r) && strcmp(r.path, "/show/heart") == 0);

    const char *bad[] = { "", "GET", "GET ", "GET status\n", "get /status\n", "GET  /status\n", "GET /a b\n",
                          "GETTINGS /x\n", "GET /x\r", "GET /x\ty\n", " /x\n", "GET\n/x" };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        char b[32];
        strcpy(b, bad[i]);
        const bool ok = zf_parse_request(b, strlen(b), &r);
        if (ok) printf("  accepted bad request line #%zu\n", i);
        CHECK(!ok);
    }
    char longp[ZF_PATH_MAX + 16];
    memset(longp, 'a', sizeof longp);
    memcpy(longp, "GET /", 5);
    longp[5 + ZF_PATH_MAX] = 0;                                   /* path of ZF_PATH_MAX + 1 chars */
    CHECK(!zf_parse_request(longp, strlen(longp), &r));
    longp[3] = ' ';                                               /* the failed parse may have cut it */
    longp[4 + ZF_PATH_MAX] = 0;                                   /* exactly ZF_PATH_MAX */
    CHECK(zf_parse_request(longp, strlen(longp), &r));
}

int main(void)
{
    test_golden();
    test_roundtrip();
    test_errors();
    test_parse();
    printf("%s: %d checks, %d failed\n", s_fail ? "FAIL" : "PASS", s_checks, s_fail);
    return s_fail ? 1 : 0;
}
