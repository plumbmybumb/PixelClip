#!/usr/bin/env python3
"""ble_api.py — call the clip's HTTP API over the BLE fast lane (PROTOCOL §3b), no WiFi needed.

    scripts/ble_api.py GET /status
    scripts/ble_api.py PUT /playlist @playlist.json       # body from a file
    scripts/ble_api.py POST /brightness '{"value":200}'
    scripts/ble_api.py --name PixelClip-1A2B POST /next
    scripts/ble_api.py --repeat 10 GET /status            # timing: min / median / max over one connection
    echo '{"epoch":1760100000}' | scripts/ble_api.py POST /time -
    scripts/ble_api.py --selftest                         # framing unit test, no Bluetooth needed

Prints the status, the elapsed time and the body (pretty-printed JSON). Exit status 0 for 2xx, 1 otherwise.

It is also the reference client for the framing (contract: components/ble/include/pixelclip_ble_uuids.h, parsed at
start so this script cannot drift from the firmware): subscribe to `rsp`, write the request
"METHOD SP path LF [body]" to `req` as frames of at most MTU-3 bytes (byte 0 = header: bit7 first, bit6 last,
bits 0-5 sequence mod 64 starting at 0; write without response), reassemble the notified response
"STATUS SP LF [body]" the same way. One request in flight per connection.

Needs `bleak` for the BLE part (python3 -m pip install --user bleak); macOS: allow the terminal to use
Bluetooth (System Settings > Privacy & Security > Bluetooth).
"""
import argparse, asyncio, json, os, statistics, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ble_wake import load_contract  # noqa: E402  (same directory; parses pixelclip_ble_uuids.h)

C = load_contract()
SERVICE, REQ, RSP = (C[k].lower() for k in ("PIXELCLIP_BLE_SERVICE_UUID", "PIXELCLIP_BLE_CHR_REQ_UUID", "PIXELCLIP_BLE_CHR_RSP_UUID"))
FIRST, LAST, SEQ = C["PIXELCLIP_BLE_FRAME_FIRST"], C["PIXELCLIP_BLE_FRAME_LAST"], C["PIXELCLIP_BLE_FRAME_SEQ_MASK"]
MAX_BYTES = C["PIXELCLIP_BLE_API_MAX_BYTES"]


# ----------------------------------------------------------------------------------------------- framing

def frames(payload: bytes, max_frame: int):
    """Split a message into frames of at most max_frame bytes (header + data). Sequence starts at 0."""
    if max_frame < 2:
        raise ValueError("max_frame must be >= 2")
    room = max_frame - 1
    out, off, seq = [], 0, 0
    while True:
        chunk = payload[off:off + room]
        hdr = seq & SEQ
        if off == 0:
            hdr |= FIRST
        off += len(chunk)
        if off >= len(payload):
            hdr |= LAST
        out.append(bytes([hdr]) + chunk)
        seq = (seq + 1) & SEQ
        if hdr & LAST:
            return out


class BadFrame(Exception):
    pass


class Reassembler:
    """Receiver side, same rules as the firmware (components/ble/pixelclip_frame.c)."""

    def __init__(self):
        self.buf, self.next_seq, self.open = bytearray(), 0, False

    def push(self, frame: bytes):
        """Returns the complete message, or None. Raises BadFrame on a gap / stray frame."""
        if not frame:
            raise BadFrame("empty frame")
        hdr, seq = frame[0], frame[0] & SEQ
        if hdr & FIRST:
            self.buf, self.open = bytearray(), True
        elif not self.open:
            raise BadFrame(f"continuation 0x{hdr:02x} without a first frame")
        elif seq != self.next_seq:
            self.open = False
            raise BadFrame(f"sequence gap: got {seq}, expected {self.next_seq}")
        self.next_seq = (seq + 1) & SEQ
        self.buf += frame[1:]
        if hdr & LAST:
            self.open = False
            return bytes(self.buf)
        return None


def build_request(method: str, path: str, body: bytes = b"") -> bytes:
    if not path.startswith("/") or " " in path:
        raise ValueError("path must start with / and contain no spaces")
    return method.upper().encode("ascii") + b" " + path.encode("utf-8") + b"\n" + body


def parse_response(msg: bytes):
    """'STATUS SP LF [body]' -> (status int, body bytes)."""
    head, sep, body = msg.partition(b"\n")
    if not sep:
        raise ValueError(f"no LF in response: {msg[:40]!r}")
    return int(head.strip() or b"0"), body


def selftest():
    """Offline checks of the framing (the same vectors as firmware/test_host/test_frame.c)."""
    req = build_request("POST", "/brightness", b'{"value":200}')
    assert req == b'POST /brightness\n{"value":200}'
    f = frames(req, 10)
    golden = ["80504f5354202f627269", "016768746e6573730a7b", "022276616c7565223a32", "4330307d"]
    assert [x.hex() for x in f] == golden, [x.hex() for x in f]
    assert [x.hex() for x in frames(b'200 \n{"ok":true}', 8)] == ["80323030200a7b22", "016f6b223a747275", "42657d"]
    assert frames(b"", 20) == [bytes([FIRST | LAST])]
    for size in (2, 3, 20, 182, 509, 514):
        for n in (0, 1, size - 1, size, 5000, MAX_BYTES):
            msg = bytes((i * 7 + 3) & 0xFF for i in range(n))
            fr = frames(msg, size)
            assert all(len(x) <= size for x in fr)
            assert fr[0][0] & FIRST and fr[-1][0] & LAST
            r = Reassembler()
            got = [r.push(x) for x in fr]
            assert got[-1] == msg and all(g is None for g in got[:-1])
    big = bytes(range(256)) * 6
    fr = frames(big, 20)          # 81 frames: the sequence wraps after 63
    assert len(fr) > 64 and fr[64][0] & SEQ == 0 and fr[63][0] & SEQ == 63
    r = Reassembler()
    for x in fr[:-1]:
        assert r.push(x) is None
    assert r.push(fr[-1]) == big
    r = Reassembler()
    r.push(fr[0])
    try:
        r.push(fr[2])
        raise AssertionError("gap not detected")
    except BadFrame:
        pass
    try:
        Reassembler().push(fr[1])
        raise AssertionError("stray continuation not detected")
    except BadFrame:
        pass
    assert parse_response(b"200 \n{\"ok\":true}") == (200, b"{\"ok\":true}")
    assert parse_response(b"400 \nbad_frame") == (400, b"bad_frame")
    print("selftest: OK (framing, reassembly, sequence wrap, gap / stray detection, golden vector)")
    return 0


# ----------------------------------------------------------------------------------------------- BLE

async def find_clip(BleakScanner, name, timeout):
    print(f"scanning {timeout:.0f} s for {name or 'PixelClip-*'} ...", file=sys.stderr)
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    cands = []
    for dev, adv in found.values():
        n = adv.local_name or dev.name or ""
        has_svc = SERVICE in [u.lower() for u in (adv.service_uuids or [])]
        if (name and n == name) or (not name and (n.startswith("PixelClip-") or has_svc)):
            cands.append((adv.rssi if adv.rssi is not None else -999, n or "(no name)", dev))
    if not cands:
        return None
    cands.sort(key=lambda c: -c[0])
    rssi, n, dev = cands[0]
    print(f"found {n} ({dev.address}, RSSI {rssi} dBm)", file=sys.stderr)
    return dev


async def run(a, body):
    try:
        from bleak import BleakClient, BleakScanner
    except ImportError:
        print("bleak is not installed. Install it with:\n\n    python3 -m pip install --user bleak\n", file=sys.stderr)
        return 2
    dev = await find_clip(BleakScanner, a.name, a.scan)
    if dev is None:
        print("no clip found. Is ble_wake on (GET /ble), the clip awake and within a few metres?", file=sys.stderr)
        return 2
    payload = build_request(a.method, a.path, body)
    if len(body) > MAX_BYTES:
        print(f"warning: body is {len(body)} B, the fast lane takes at most {MAX_BYTES} B (expect 413)", file=sys.stderr)

    t_conn = time.monotonic()
    async with BleakClient(dev) as cl:
        svc = cl.services.get_service(SERVICE)
        req_chr = svc.get_characteristic(REQ) if svc else None
        if req_chr is None or svc.get_characteristic(RSP) is None:
            print("this clip's firmware has no fast lane (no req/rsp characteristics)", file=sys.stderr)
            return 2
        size = a.frame or getattr(req_chr, "max_write_without_response_size", 0) or (cl.mtu_size - 3)
        print(f"connected in {time.monotonic() - t_conn:.2f} s, frames of {size} B (MTU {size + 3})", file=sys.stderr)

        loop = asyncio.get_running_loop()
        rx = Reassembler()
        done: asyncio.Future = loop.create_future()

        def on_rsp(_, data):
            try:
                msg = rx.push(bytes(data))
            except BadFrame as e:
                print(f"response framing error: {e}", file=sys.stderr)
                return
            if msg is not None and not done.done():
                done.set_result(msg)

        await cl.start_notify(RSP, on_rsp)
        times, status, rbody = [], 0, b""
        for i in range(a.repeat):
            done = loop.create_future()
            fr = frames(payload, size)
            t0 = time.monotonic()
            for f in fr:
                await cl.write_gatt_char(req_chr, f, response=False)
            try:
                msg = await asyncio.wait_for(done, a.timeout)
            except asyncio.TimeoutError:
                print(f"no response within {a.timeout:.0f} s", file=sys.stderr)
                return 1
            dt = time.monotonic() - t0
            times.append(dt)
            status, rbody = parse_response(msg)
            if a.repeat > 1:
                print(f"  #{i + 1}: {status} {len(rbody)} B in {dt * 1000:.0f} ms ({len(fr)} frames up)", file=sys.stderr)
        await cl.stop_notify(RSP)

    print(f"{status}  ({len(payload)} B up in {len(frames(payload, size))} frames, {len(rbody)} B back, "
          f"{times[-1] * 1000:.0f} ms)")
    if a.repeat > 1:
        print(f"timing over {a.repeat}: min {min(times) * 1000:.0f} ms, median {statistics.median(times) * 1000:.0f} ms, "
              f"max {max(times) * 1000:.0f} ms")
    if rbody:
        try:
            print(json.dumps(json.loads(rbody), indent=2, ensure_ascii=False))
        except ValueError:
            print(rbody.decode("utf-8", "replace"))
    return 0 if 200 <= status < 300 else 1


def main():
    ap = argparse.ArgumentParser(description="PixelClip HTTP API over the BLE fast lane",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n")[1])
    ap.add_argument("method", nargs="?", help="GET, PUT, POST, DELETE")
    ap.add_argument("path", nargs="?", help="e.g. /status, /show/heart")
    ap.add_argument("body", nargs="?", default="", help="JSON text, @file, or - for stdin")
    ap.add_argument("--name", help="advertised name (= SSID), e.g. PixelClip-1A2B; default: strongest PixelClip-*")
    ap.add_argument("--scan", type=float, default=8.0, help="scan timeout in seconds (default 8)")
    ap.add_argument("--timeout", type=float, default=10.0, help="response timeout in seconds (default 10)")
    ap.add_argument("--repeat", type=int, default=1, help="send the request N times on one connection (timing)")
    ap.add_argument("--frame", type=int, default=0, help="force the frame size (default: MTU-3 as negotiated)")
    ap.add_argument("--selftest", action="store_true", help="run the offline framing tests and exit")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.method or not a.path:
        ap.error("METHOD and PATH are required (or --selftest)")
    if a.body == "-":
        body = sys.stdin.buffer.read()
    elif a.body.startswith("@"):
        with open(a.body[1:], "rb") as f:
            body = f.read()
    else:
        body = a.body.encode("utf-8")
    return asyncio.run(run(a, body))


if __name__ == "__main__":
    sys.exit(main())
