/* pixelclip_frame.h — BLE fast-lane framing (PROTOCOL §3b). Plain C99, no ESP-IDF: also built and unit-tested
 * on the host (firmware/test_host).
 *
 * Wire format (both directions): a message is split into frames of at most MTU-3 bytes. Byte 0 of every
 * frame is a header: bit7 = first frame of a message, bit6 = last frame, bits 0-5 = sequence number
 * (mod 64, +1 per frame). The rest of the frame is message bytes. A one-frame message has both bits set.
 *   request  (`req`, write without response): "METHOD SP path LF [body]"
 *   response (`rsp`, notify):                 "STATUS SP LF [body]"   (e.g. "200 \n{\"ok\":true}")
 *
 * Receiver rules implemented by zf_rx_push():
 *   - a first frame starts a message; its sequence number may be anything (senders start at 0), every
 *     following frame must carry the previous number + 1 (mod 64);
 *   - a gap, a continuation frame with no message open, or an empty frame -> ZF_BAD_FRAME once, then all
 *     frames are dropped silently until the next first frame;
 *   - a first frame while a message is still open abandons the open one (the sender gave up on it: it can
 *     never have received a response) and starts over;
 *   - a message larger than the buffer -> ZF_TOO_LARGE once, then dropped until the next first frame;
 *   - `busy` (a request is still being handled) at a message's first frame -> the message is consumed
 *     without being stored (the buffer belongs to the running request) and ZF_BUSY is returned at its last
 *     frame, so the caller answers 429 after the sender has finished.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZF_HDR_FIRST    0x80
#define ZF_HDR_LAST     0x40
#define ZF_SEQ_MASK     0x3F
#define ZF_FRAME_MAX    514     /* ATT_MTU 517 - 3: the largest frame (header + 513 bytes) */
#define ZF_METHOD_MAX   7       /* "DELETE" */
#define ZF_PATH_MAX     255     /* request path incl. query (ids are <= 32 chars) */

typedef enum {
    ZF_RX_IDLE,       /* waiting for a first frame */
    ZF_RX_RECV,       /* storing a message */
    ZF_RX_REJECT,     /* consuming a message that arrived while busy (not stored) */
    ZF_RX_DISCARD,    /* after an error: dropping frames until the next first frame */
} zf_rx_state_t;

typedef enum {
    ZF_MORE,          /* frame consumed; nothing to do yet */
    ZF_DONE,          /* message complete: buf[0..len) plus a NUL at buf[len]; back to idle */
    ZF_BUSY,          /* last frame of a message that started while busy: answer 429 */
    ZF_BAD_FRAME,     /* sequence gap / stray continuation / empty frame: answer 400 "bad_frame" */
    ZF_TOO_LARGE,     /* message larger than cap: answer 413 */
} zf_rx_result_t;

typedef struct {
    uint8_t *buf;          /* cap + 1 bytes (room for the terminating NUL) */
    size_t cap;
    size_t len;
    uint8_t next_seq;
    zf_rx_state_t state;
    uint32_t frames;       /* frames of the current message */
    uint32_t abandoned;    /* messages replaced by a new first frame before their last frame (stats) */
} zf_rx_t;

void zf_rx_init(zf_rx_t *rx, uint8_t *buf, size_t cap);
/* Forget any open message (connect / disconnect). Keeps the statistics. */
void zf_rx_reset(zf_rx_t *rx);
zf_rx_result_t zf_rx_push(zf_rx_t *rx, const uint8_t *frame, size_t n, bool busy);

typedef struct {
    const uint8_t *p;
    size_t len, off;
    uint8_t seq;
    bool started, done;
} zf_tx_t;

void zf_tx_init(zf_tx_t *tx, const uint8_t *payload, size_t len);   /* sequence starts at 0 */
/* Write the next frame (at most max_frame bytes, >= 2) into out; returns its length, 0 once the whole
 * message has been framed. An empty message is one header-only frame (first|last). */
size_t zf_tx_next(zf_tx_t *tx, uint8_t *out, size_t max_frame);
/* Number of frames zf_tx_next() produces for len bytes. */
size_t zf_frame_count(size_t len, size_t max_frame);

/* A parsed request "METHOD SP path LF [body]". method/path point into the payload, which is modified in
 * place (the SP and LF become NULs); body points just after the LF (NUL-terminated if the payload was). */
typedef struct {
    const char *method;
    const char *path;
    const char *body;
    size_t body_len;
} zf_req_t;

/* payload[len] must be a writable NUL (zf_rx_push() guarantees it for a ZF_DONE message).
 * false: malformed request line. Rules: METHOD = 1..ZF_METHOD_MAX upper-case letters, exactly one SP,
 * path = 1..ZF_PATH_MAX printable non-space ASCII starting with '/', then LF (a CR before it is tolerated;
 * no LF at all = no body). */
bool zf_parse_request(char *payload, size_t len, zf_req_t *out);

#ifdef __cplusplus
}
#endif
