#!/usr/bin/env python3
"""ble_wake.py — ring the clip's BLE "doorbell" from this Mac (contract: components/ble/include/pixelclip_ble_uuids.h).

    scripts/ble_wake.py                 # first PixelClip-* found: write 0x01 to `wake`, then print `status`
    scripts/ble_wake.py PixelClip-1A2B       # a specific clip (name = its SSID)
    scripts/ble_wake.py --end           # write 0x02 instead (end the WiFi session)
    scripts/ble_wake.py --status        # only read `info` + `status`, write nothing

Needs `bleak` (python3 -m pip install --user bleak). On macOS the terminal app must be allowed to use
Bluetooth (System Settings > Privacy & Security > Bluetooth); the first run triggers the prompt.
After a successful wake, join the hotspot as usual (scripts/e2e.sh does that itself).
"""
import argparse, asyncio, os, re, struct, sys

HDR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "components", "ble", "include", "pixelclip_ble_uuids.h")


def load_contract():
    """Read the UUIDs and codes from the shared header, so this script can never drift from the firmware."""
    defs = {}
    with open(HDR, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'#define\s+(PIXELCLIP_BLE_\w+)\s+("([^"]*)"|0x[0-9A-Fa-f]+\b|\d+(\.\d+)?\b)', line)
            if m:
                v = m.group(3) if m.group(3) is not None else m.group(2)
                defs[m.group(1)] = v if m.group(3) is not None else (int(v, 16) if v.startswith("0x") else float(v) if "." in v else int(v))
    return defs


C = load_contract()
SERVICE, WAKE, STATUS, INFO = (C[k].lower() for k in ("PIXELCLIP_BLE_SERVICE_UUID", "PIXELCLIP_BLE_CHR_WAKE_UUID",
                                                      "PIXELCLIP_BLE_CHR_STATUS_UUID", "PIXELCLIP_BLE_CHR_INFO_UUID"))
FLAGS = [(C["PIXELCLIP_BLE_FLAG_SESSION_ACTIVE"], "session_active"), (C["PIXELCLIP_BLE_FLAG_USB_PRESENT"], "usb_present"),
         (C["PIXELCLIP_BLE_FLAG_CLOCK_OK"], "clock_ok"), (C["PIXELCLIP_BLE_FLAG_PLAYING"], "playing"),
         (C["PIXELCLIP_BLE_FLAG_LOW_BATTERY"], "low_battery"), (C["PIXELCLIP_BLE_FLAG_ALWAYS_ON"], "always_on")]
KINDS = {C["PIXELCLIP_BLE_KIND_NONE"]: "none", C["PIXELCLIP_BLE_KIND_ASSET"]: "asset",
         C["PIXELCLIP_BLE_KIND_SCENE"]: "scene", C["PIXELCLIP_BLE_KIND_READER"]: "reader"}
RESULTS = {C["PIXELCLIP_BLE_RESULT_NONE"]: "none", C["PIXELCLIP_BLE_RESULT_ACCEPTED"]: "accepted",
           C["PIXELCLIP_BLE_RESULT_LOW_BATTERY"]: "refused: battery below the WiFi floor", C["PIXELCLIP_BLE_RESULT_INVALID"]: "refused: invalid value"}


def decode_status(b):
    if len(b) < 6:
        return f"short status ({len(b)} B): {bytes(b).hex()}"
    mv, pct, flags, kind, proto = struct.unpack_from("<HBBBB", b)
    last = b[6] if len(b) > 6 else 0
    names = [n for bit, n in FLAGS if flags & bit] or ["-"]
    return (f"battery {mv} mV {pct}%, flags 0x{flags:02x} [{', '.join(names)}], item {KINDS.get(kind, kind)}, "
            f"protocol {proto}, last wake: {RESULTS.get(last, last)}")


async def main():
    ap = argparse.ArgumentParser(description="BLE doorbell for the PixelClip")
    ap.add_argument("name", nargs="?", help="advertised name (= SSID), e.g. PixelClip-1A2B; default: first PixelClip-* found")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--end", action="store_true", help="write 0x02 (end the session) instead of 0x01")
    g.add_argument("--status", action="store_true", help="only read info + status")
    ap.add_argument("--scan", type=float, default=10.0, help="scan timeout in seconds (default 10)")
    ap.add_argument("--wait", type=float, default=8.0, help="seconds to wait for session_active after a wake (default 8)")
    a = ap.parse_args()

    try:
        from bleak import BleakClient, BleakScanner
        from bleak.exc import BleakError
    except ImportError:
        print("bleak is not installed. Install it with:\n\n    python3 -m pip install --user bleak\n\n"
              "(macOS: allow your terminal to use Bluetooth in System Settings > Privacy & Security > Bluetooth.)")
        return 2

    print(f"scanning {a.scan:.0f} s for {a.name or 'PixelClip-*'} (service {SERVICE}) ...")
    found = await BleakScanner.discover(timeout=a.scan, return_adv=True)
    cands = []
    for dev, adv in found.values():
        name = adv.local_name or dev.name or ""
        has_svc = SERVICE in [u.lower() for u in (adv.service_uuids or [])]
        if (a.name and name == a.name) or (not a.name and (name.startswith("PixelClip-") or has_svc)):
            cands.append((adv.rssi if adv.rssi is not None else -999, name or "(no name)", dev))
    if not cands:
        print("no clip found. Is ble_wake on (GET /ble), the clip awake and within a few metres?")
        return 1
    cands.sort(key=lambda c: -c[0])
    rssi, name, dev = cands[0]
    # What the device says about itself is printed as printable ASCII only (no terminal escapes).
    shown = lambda s: "".join(c if " " <= c <= "~" else "?" for c in str(s))[:64]
    name = shown(name)
    print(f"found {name} ({shown(dev.address)}, RSSI {rssi} dBm)" + (f", {len(cands) - 1} more" if len(cands) > 1 else ""))

    notes = []

    def on_status(_, data):
        notes.append(bytes(data))
        print("  notify:", decode_status(data))

    async with BleakClient(dev) as cl:
        info = (await cl.read_gatt_char(INFO)).decode("ascii", "replace")
        print("info:  ", shown(info), "(device id;fw)")
        print("status:", decode_status(await cl.read_gatt_char(STATUS)))
        if a.status:
            return 0
        await cl.start_notify(STATUS, on_status)
        cmd = C["PIXELCLIP_BLE_CMD_END"] if a.end else C["PIXELCLIP_BLE_CMD_WAKE"]
        print(f"writing 0x{cmd:02x} to wake ...")
        try:
            await cl.write_gatt_char(WAKE, bytes([cmd]), response=True)
        except BleakError as e:
            msg = str(e)
            low = C["PIXELCLIP_BLE_ATT_ERR_LOW_BATTERY"]
            if f"Code={low}" in msg or f"0x{low:02x}" in msg.lower() or f"0x{low:02X}" in msg:
                print("refused: battery below the WiFi floor (ATT error 0x80). Charge the clip.")
            else:
                print("write failed:", msg)
            print("status:", decode_status(await cl.read_gatt_char(STATUS)))
            return 1
        print("accepted")
        want = not a.end
        deadline = asyncio.get_running_loop().time() + a.wait
        while asyncio.get_running_loop().time() < deadline:
            st = await cl.read_gatt_char(STATUS)
            if len(st) >= 4 and bool(st[3] & C["PIXELCLIP_BLE_FLAG_SESSION_ACTIVE"]) == want:
                break
            await asyncio.sleep(0.5)
        st = await cl.read_gatt_char(STATUS)
        print("status:", decode_status(st))
        active = len(st) >= 4 and bool(st[3] & C["PIXELCLIP_BLE_FLAG_SESSION_ACTIVE"])
        if want and active:
            print(f"hotspot is up: join {name} (password pixelclip-2026 unless changed), then http://192.168.4.1")
        elif not want and not active:
            print("session ended")
        else:
            print("the session flag did not change within", a.wait, "s")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
