/* pixelclip_frame.c — BLE fast-lane framing (PROTOCOL §3b); see pixelclip_frame.h. Portable C99. */
#include "pixelclip_frame.h"

#include <string.h>

void zf_rx_init(zf_rx_t *rx, uint8_t *buf, size_t cap)
{
    memset(rx, 0, sizeof *rx);
    rx->buf = buf;
    rx->cap = cap;
    rx->state = ZF_RX_IDLE;
}

void zf_rx_reset(zf_rx_t *rx)
{
    rx->len = 0;
    rx->frames = 0;
    rx->state = ZF_RX_IDLE;
}

static zf_rx_result_t rx_error(zf_rx_t *rx, zf_rx_result_t r)
{
    rx->len = 0;
    rx->state = ZF_RX_DISCARD;
    return r;
}

zf_rx_result_t zf_rx_push(zf_rx_t *rx, const uint8_t *frame, size_t n, bool busy)
{
    if (n == 0) {
        /* Not even a header. Report it unless we are already dropping a broken message. */
        if (rx->state == ZF_RX_DISCARD) return ZF_MORE;
        return rx_error(rx, ZF_BAD_FRAME);
    }
    const uint8_t h = frame[0];
    const uint8_t seq = h & ZF_SEQ_MASK;
    const uint8_t *p = frame + 1;
    const size_t pn = n - 1;

    if (h & ZF_HDR_FIRST) {
        if (rx->state == ZF_RX_RECV || rx->state == ZF_RX_REJECT) rx->abandoned++;
        rx->len = 0;
        rx->frames = 0;
        rx->state = busy ? ZF_RX_REJECT : ZF_RX_RECV;
    } else {
        switch (rx->state) {
        case ZF_RX_IDLE:
            return rx_error(rx, ZF_BAD_FRAME);       /* continuation without a first frame */
        case ZF_RX_DISCARD:
            return ZF_MORE;                          /* already reported */
        default:
            if (seq != rx->next_seq) return rx_error(rx, ZF_BAD_FRAME);
            break;
        }
    }
    rx->next_seq = (uint8_t)((seq + 1) & ZF_SEQ_MASK);
    rx->frames++;

    if (rx->state == ZF_RX_RECV) {
        if (pn > rx->cap - rx->len) return rx_error(rx, ZF_TOO_LARGE);
        if (pn) memcpy(rx->buf + rx->len, p, pn);
        rx->len += pn;
    }
    if (h & ZF_HDR_LAST) {
        const bool rejected = rx->state == ZF_RX_REJECT;
        rx->state = ZF_RX_IDLE;
        if (rejected) {
            rx->len = 0;
            return ZF_BUSY;
        }
        rx->buf[rx->len] = 0;
        return ZF_DONE;
    }
    return ZF_MORE;
}

void zf_tx_init(zf_tx_t *tx, const uint8_t *payload, size_t len)
{
    memset(tx, 0, sizeof *tx);
    tx->p = payload;
    tx->len = len;
}

size_t zf_tx_next(zf_tx_t *tx, uint8_t *out, size_t max_frame)
{
    if (tx->done || max_frame < 2) return 0;
    const size_t room = max_frame - 1;
    const size_t left = tx->len - tx->off;
    const size_t n = left < room ? left : room;
    uint8_t h = tx->seq & ZF_SEQ_MASK;
    if (!tx->started) h |= ZF_HDR_FIRST;
    if (tx->off + n == tx->len) {
        h |= ZF_HDR_LAST;
        tx->done = true;
    }
    out[0] = h;
    if (n) memcpy(out + 1, tx->p + tx->off, n);
    tx->off += n;
    tx->started = true;
    tx->seq = (uint8_t)((tx->seq + 1) & ZF_SEQ_MASK);
    return n + 1;
}

size_t zf_frame_count(size_t len, size_t max_frame)
{
    if (max_frame < 2) return 0;
    const size_t room = max_frame - 1;
    return len == 0 ? 1 : (len + room - 1) / room;
}

bool zf_parse_request(char *payload, size_t len, zf_req_t *out)
{
    memset(out, 0, sizeof *out);
    size_t i = 0;
    while (i < len && payload[i] >= 'A' && payload[i] <= 'Z') i++;
    if (i == 0 || i > ZF_METHOD_MAX || i >= len || payload[i] != ' ') return false;
    payload[i] = '\0';
    out->method = payload;
    const size_t ps = ++i;
    while (i < len && payload[i] > ' ' && payload[i] < 0x7F) i++;
    size_t pe = i;   /* end of the path (exclusive) */
    if (pe == ps || pe - ps > ZF_PATH_MAX || payload[ps] != '/') return false;
    if (i < len && payload[i] == '\r') i++;
    if (i < len) {
        if (payload[i] != '\n') return false;   /* a space or a control character inside the path */
        i++;
    } else if (i > pe) {
        return false;                           /* "...\r" with no LF */
    }
    payload[pe] = '\0';                         /* the CR, the LF, or the terminating NUL at payload[len] */
    out->path = payload + ps;
    out->body = payload + i;
    out->body_len = len - i;
    return true;
}
