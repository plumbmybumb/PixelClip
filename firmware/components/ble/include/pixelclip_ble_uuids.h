/* pixelclip_ble_uuids.h — the PixelClip BLE "doorbell" contract, shared verbatim with the iOS app.
 *
 * The clip advertises as "PixelClip-XXXX" (same suffix as its SoftAP SSID; the name is in the scan
 * response) with PIXELCLIP_BLE_SERVICE_UUID in the advertising packet, connectable, no pairing/bonding.
 * Advertising interval PIXELCLIP_BLE_ADV_ITVL_MIN_MS..PIXELCLIP_BLE_ADV_ITVL_MAX_MS (Apple-recommended
 * values, so iOS background scans still find it).
 *
 * App recipe: CoreBluetooth scan for PIXELCLIP_BLE_SERVICE_UUID -> connect -> write 0x01 (with response)
 * to `wake` -> read/subscribe `status` until PIXELCLIP_BLE_FLAG_SESSION_ACTIVE -> NEHotspotConfiguration
 * join "PixelClip-XXXX" -> HTTP as usual. Write 0x02 to end the session (e.g. after the sync).
 *
 * Fast lane (PROTOCOL §3b): small HTTP-style requests over the same connection, no WiFi. Subscribe to
 * `rsp`, write the request to `req` as frames (see "Fast lane" below), reassemble the notified response.
 *
 * Everything here is plain C (no ESP-IDF types) so the app can copy the file or mirror the values.
 */
#pragma once
#include <stdint.h>

/* ---- UUIDs (128-bit, random base 737B9B00-A500-43FC-B410-86AC8852E678; characteristics differ
 *      only in the first group) ---- */
#define PIXELCLIP_BLE_SERVICE_UUID     "737B9B00-A500-43FC-B410-86AC8852E678"
#define PIXELCLIP_BLE_CHR_WAKE_UUID    "737B9B01-A500-43FC-B410-86AC8852E678"   /* write (with response) */
#define PIXELCLIP_BLE_CHR_STATUS_UUID  "737B9B02-A500-43FC-B410-86AC8852E678"   /* read + notify */
#define PIXELCLIP_BLE_CHR_INFO_UUID    "737B9B03-A500-43FC-B410-86AC8852E678"   /* read */
#define PIXELCLIP_BLE_CHR_REQ_UUID     "737B9B04-A500-43FC-B410-86AC8852E678"   /* write without response: fast-lane request frames */
#define PIXELCLIP_BLE_CHR_RSP_UUID     "737B9B05-A500-43FC-B410-86AC8852E678"   /* notify: fast-lane response frames */

/* The same UUIDs as little-endian byte lists (NimBLE BLE_UUID128_INIT order). */
#define PIXELCLIP_BLE_SERVICE_UUID_LE    0x78, 0xe6, 0x52, 0x88, 0xac, 0x86, 0x10, 0xb4, 0xfc, 0x43, 0x00, 0xa5, 0x00, 0x9b, 0x7b, 0x73
#define PIXELCLIP_BLE_CHR_WAKE_UUID_LE   0x78, 0xe6, 0x52, 0x88, 0xac, 0x86, 0x10, 0xb4, 0xfc, 0x43, 0x00, 0xa5, 0x01, 0x9b, 0x7b, 0x73
#define PIXELCLIP_BLE_CHR_STATUS_UUID_LE 0x78, 0xe6, 0x52, 0x88, 0xac, 0x86, 0x10, 0xb4, 0xfc, 0x43, 0x00, 0xa5, 0x02, 0x9b, 0x7b, 0x73
#define PIXELCLIP_BLE_CHR_INFO_UUID_LE   0x78, 0xe6, 0x52, 0x88, 0xac, 0x86, 0x10, 0xb4, 0xfc, 0x43, 0x00, 0xa5, 0x03, 0x9b, 0x7b, 0x73
#define PIXELCLIP_BLE_CHR_REQ_UUID_LE    0x78, 0xe6, 0x52, 0x88, 0xac, 0x86, 0x10, 0xb4, 0xfc, 0x43, 0x00, 0xa5, 0x04, 0x9b, 0x7b, 0x73
#define PIXELCLIP_BLE_CHR_RSP_UUID_LE    0x78, 0xe6, 0x52, 0x88, 0xac, 0x86, 0x10, 0xb4, 0xfc, 0x43, 0x00, 0xa5, 0x05, 0x9b, 0x7b, 0x73

/* ---- Advertising ---- */
#define PIXELCLIP_BLE_ADV_ITVL_MIN_MS  1022.5   /* 1636 x 0.625 ms */
#define PIXELCLIP_BLE_ADV_ITVL_MAX_MS  1285.0   /* 2056 x 0.625 ms */

/* ---- `wake` characteristic: exactly one byte ---- */
#define PIXELCLIP_BLE_CMD_WAKE         0x01     /* start upload mode (SoftAP + HTTP), exactly like a long press;
                                              during a session: resets its idle timer */
#define PIXELCLIP_BLE_CMD_END          0x02     /* end the session (also suspends wifi_always_on until reboot) */

/* ATT error returned for a refused write (CoreBluetooth: CBATTError with this raw code). */
#define PIXELCLIP_BLE_ATT_ERR_LOW_BATTERY  0x80 /* battery below the WiFi floor (3.5 V, no USB): wake refused */
/* Other refusals use the standard codes: 0x0D invalid length (not 1 byte), 0x13 value not allowed. */

/* ---- `status` characteristic: PIXELCLIP_BLE_STATUS_LEN bytes, little-endian ----
 *   [0..1] battery mV (u16, 0 = unknown)
 *   [2]    battery percent (u8, 0..100)
 *   [3]    flags (PIXELCLIP_BLE_FLAG_*)
 *   [4]    current item kind (PIXELCLIP_BLE_KIND_*)
 *   [5]    HTTP protocol version (u8, same as /status device.protocol)
 *   [6]    result of the last `wake` write (PIXELCLIP_BLE_RESULT_*)
 * Readers must accept longer values (fields may be appended). Notified on change while subscribed
 * (checked every 2 s, and at once after a `wake` write and at session start/end). */
#define PIXELCLIP_BLE_STATUS_LEN       7
#define PIXELCLIP_BLE_FLAG_SESSION_ACTIVE  0x01 /* SoftAP + HTTP API up */
#define PIXELCLIP_BLE_FLAG_USB_PRESENT     0x02
#define PIXELCLIP_BLE_FLAG_CLOCK_OK        0x04 /* time.synced */
#define PIXELCLIP_BLE_FLAG_PLAYING         0x08 /* the panel is on and shows a playlist item (not the idle screen) */
#define PIXELCLIP_BLE_FLAG_LOW_BATTERY     0x10 /* below the WiFi floor: a wake would be refused right now */
#define PIXELCLIP_BLE_FLAG_ALWAYS_ON       0x20 /* wifi_always_on is in effect */
#define PIXELCLIP_BLE_KIND_NONE        0        /* idle screen / nothing */
#define PIXELCLIP_BLE_KIND_ASSET       1        /* image, animation or strip */
                                           /* 2: retired (no longer sent; not reused) */
#define PIXELCLIP_BLE_KIND_SCENE       3
#define PIXELCLIP_BLE_KIND_READER      4
#define PIXELCLIP_BLE_RESULT_NONE          0    /* no write since boot */
#define PIXELCLIP_BLE_RESULT_ACCEPTED      1
#define PIXELCLIP_BLE_RESULT_LOW_BATTERY   2    /* refused: battery below the WiFi floor */
#define PIXELCLIP_BLE_RESULT_INVALID       3    /* refused: not one byte, or not 0x01 / 0x02 */

/* ---- `info` characteristic: ASCII "<device id>;<fw version>", e.g. "a1b2;0.1.0" (device id = the
 *      lower-case hex suffix of the SSID, as /status device.id). More ';'-separated fields may follow. */

/* ---- Fast lane (PROTOCOL §3b): `req` (write without response) and `rsp` (notify) ----
 * A message is sent as frames of at most ATT_MTU-3 bytes. Frame byte 0 = header:
 *   bit7 PIXELCLIP_BLE_FRAME_FIRST, bit6 PIXELCLIP_BLE_FRAME_LAST, bits 0-5 sequence number (mod 64, starts at 0,
 *   +1 per frame); the rest of the frame is message bytes (a one-frame message has both bits set).
 * Request  (app -> clip, `req`): "METHOD SP path LF [body]", e.g. "POST /brightness\n{\"value\":200}".
 * Response (clip -> app, `rsp`): "STATUS SP LF [body]",      e.g. "200 \n{\"ok\":true}".
 * The body is exactly what the HTTP endpoint takes / returns (same handlers, same status codes).
 * One request in flight (a request sent before the previous response's last frame -> 429); requests up
 * to PIXELCLIP_BLE_API_MAX_BYTES of body (-> 413 "too_large" beyond); a frame sequence gap -> "400 \nbad_frame"
 * (plain text). Bulk endpoints (PUT /assets/{id}, PUT /texts/{id}, POST /ota, GET /screenshot,
 * GET /assets/{id}, GET /batlog) and responses larger than PIXELCLIP_BLE_API_MAX_BYTES ->
 * 413 {"ok":false,"error":"use_wifi"}: use the doorbell + hotspot for those. */
#define PIXELCLIP_BLE_FRAME_FIRST      0x80
#define PIXELCLIP_BLE_FRAME_LAST       0x40
#define PIXELCLIP_BLE_FRAME_SEQ_MASK   0x3F
#define PIXELCLIP_BLE_API_MAX_BYTES    16384    /* max body per request and per response */
#define PIXELCLIP_BLE_PREFERRED_MTU    517      /* the clip's preferred ATT MTU (iOS negotiates up to ~512) */
