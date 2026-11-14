#!/usr/bin/env python3
"""Minimal in-memory imitation of the clip HTTP API (PROTOCOL section 4, plus the pass-4 session keys and
GET /ble), only for testing the scripts
without hardware:  python3 scripts/mock_clip.py 18080 &  SKIP_WIFI=1 CLIP=http://127.0.0.1:18080 scripts/e2e.sh
Not a reference implementation: the firmware is the source of truth.
Request checks (PROTOCOL 4 "Request checks"), like the firmware's HTTP adapter: a request with an Origin header (or a
Sec-Fetch-Site other than none / same-origin) is 403 cross_origin; a Host that is neither the clip's (192.168.4.1,
pixelclip.local) nor this mock's own address is 403 bad_host (no Host at all is served); a JSON body that is not sent
as application/json is 415 unsupported_media_type; JSON nested deeper than 16 levels is not JSON (400 bad_json).
Config: GET /config and the PUT /config answer never contain ap_password (it stays settable here, the mock being the
WiFi side); low_battery_pct is 0-20.
Core dump: GET/DELETE /coredump answer 404 no_coredump by default; MOCK_COREDUMP=1 starts with a fake 4 KB image
(/status.resets.coredump true until DELETE /coredump).
Oracle (PROTOCOL 5f, 5f.2, 5f.6, 5f.7): items are validated like the firmware (id = the reader bundle under /texts with
a [prompt] line and a card.<i>.reading line per card, "font" required, "font_big" optional, the deck atlas (108x206,
5f.12), the optional keys atlas (160x34, 5f.12), frame counts, cards 3..78; "mode", "daily", "pages", "notes" ignored); the state machine follows core/oracle.c with its
timings (shuffle 1.2 s, face_ms, page_ms, hold_ms; no random shuffle frames): one three-card reading, POST /oracle/draw
({"cards":[a,b,c]} forces the row) | turn | back (extension, the previous screen) and /status.oracle; face_ms / page_ms
default 0 (no auto-advance), hold_ms (default 300000) is the idle timeout back to waits.
Board (PROTOCOL 5g): board items are validated like the firmware (parse_board); playlist.current "board:<sheet>";
the mock does not render the rows (the screenshot is the generic test pattern).
Arming (5f.8): a tap on waits arms (state "armed"), a shake or a tap on armed deals, back disarms; shakes are ignored
elsewhere; POST /bench/shake {"g":1.5} (mock only) injects one shake edge. While a draw is in progress (not waits) the
item's end, queue entries and window changes wait (see the scheduler model below).
The lean draw (5f.7): three, lean screens 0..4 (state "lean", page = the screen, reading = its text), detail A, B, C
(state "detail", page 0..2, card = the card, reading = its card.<i>.brief from the bundle; a card without a brief has
no detail screen), hold; back walks the list in reverse; reading is the whole paragraph on three and hold. The mock
does not compose: fixed texts (OR_LEAN_TEXTS, ORACLE_PARAGRAPH), the briefs come from the uploaded bundle."""
import json, hashlib, random, struct, sys, time, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
assets = {}; playlist = '{"version":1,"items":[]}'
texts = {}; fonts = {}; progress = {}; reader = {"paused": False}   # Reader mode (PROTOCOL 5c)
cfg = {"name":"PixelClip","brightness":160,"upload_timeout_s":120,"ap_password":"pixelclip-2026","low_battery_pct":8,"default_transition":"fade","tz_offset_s":0,
       "display_during_upload":True,"wifi_always_on":False,"ble_wake":True,"orientation":"auto"}
# What the API shows of the config: everything but the hotspot passphrase, which is write-only (PROTOCOL 4).
def cfg_view(): return dict({k: v for k, v in cfg.items() if k != "ap_password"}, ok=True)
# JSON as the firmware parses it: cJSON built with CJSON_NESTING_LIMIT 16 (firmware/json_limit.cmake). Deeper
# documents are "not JSON". The depth is counted before parsing (Python's own parser would recurse).
JSON_NESTING_LIMIT = 16
def jloads(b):
    if isinstance(b, bytes): b = b.decode("utf-8")
    depth = 0; in_str = esc = False
    for ch in b:
        if in_str:
            if esc: esc = False
            elif ch == "\\": esc = True
            elif ch == '"': in_str = False
        elif ch == '"': in_str = True
        elif ch in "[{":
            depth += 1
            if depth > JSON_NESTING_LIMIT: raise ValueError("nested deeper than %d" % JSON_NESTING_LIMIT)
        elif ch in "]}": depth -= 1
    return json.loads(b)
# Routes whose body is JSON (the firmware's read_json / PUT /playlist / PUT /fonts): Content-Type must say so.
def json_route(method, p):
    if method == "PUT": return p in ("/playlist", "/config") or p.startswith("/fonts/")
    return method == "POST" and p not in ("/ota", "/next", "/prev", "/session/end")
CFG_BOOLS = ("display_during_upload", "wifi_always_on", "ble_wake")
ORIENTATIONS = ("auto", "normal", "flipped")   # PROTOCOL 4 "Orientation"
# Mock gravity is fixed (IMU_RAW["rest"], gy ~ 0): auto never flips, so flipped == (mode == "flipped").
def orient_flipped(): return cfg["orientation"] == "flipped"
# The mock's one session started with the defaults: screen on (display_during_upload), not always-on.
# Like the firmware, the panel mode is fixed at session start; always-on follows PUT /config at once.
# MOCK_PANEL_OFF=1 models a panel-off session (display_during_upload false when it started).
import os
if os.environ.get("MOCK_PANEL_OFF"): cfg["display_during_upload"] = False
session = {"display_on": cfg["display_during_upload"], "t0": time.time()}
BLE_SERVICE_UUID = "737B9B00-A500-43FC-B410-86AC8852E678"   # components/ble/include/pixelclip_ble_uuids.h
clock = {"delta":0,"synced":False}          # clip time = time.time() + delta once POST /time ran
# Boot clock state (firmware timekeeping): MOCK_TIME=approx (default: rebuilt from the NVS anchor, as a clip
# that was synced before a reboot) or unknown (no anchor ever saved: 1970). POST /time makes it synced.
clock["approx"] = os.environ.get("MOCK_TIME", "approx") != "unknown"
clock["anchor_t"] = time.time() - 42 if clock["approx"] else None   # anchor saved 42 s before "now"
# POST /show override (firmware player): {"item", "t0", "until"} or None; /next, /prev end it.
show = {"cur": None}
playlist_t0 = {"t": time.time()}
queue_state = {"done":set(),"active":None}  # fired/skipped ids, queue entry on screen (POST /queue/test)
# GET /scenes body = scene_describe_json() of core/src/scene.c, verbatim (the firmware sends it unchanged).
# Regenerate after registry changes: cc -Icore/include x.c core/src/scene*.c, printing scene_describe_json().
SCENES_JSON = '{"ok":true,"scenes":[{"id":"sand","name":"Sand","params":{"palette":["amber","ocean","forest","candy","mono","ember"],"density":[10,100],"smooth":[0,1],"scale":[2,8]},"defaults":{"palette":"amber","density":50,"smooth":0,"scale":4}},{"id":"water","name":"Water","params":{"palette":["amber","ocean","forest","candy","mono","ember"],"density":[10,100],"smooth":[0,1],"scale":[2,8]},"defaults":{"palette":"ocean","density":50,"smooth":0,"scale":4}},{"id":"snow","name":"Snow","params":{"palette":["amber","ocean","forest","candy","mono","ember"],"density":[10,100],"smooth":[0,1],"scale":[2,8]},"defaults":{"palette":"mono","density":50,"smooth":0,"scale":4}},{"id":"fire","name":"Fire","params":{"palette":["classic","blue","emerald"],"intensity":[10,100],"smooth":[0,1],"scale":[2,8]},"defaults":{"palette":"classic","intensity":70,"smooth":1,"scale":4}},{"id":"lava","name":"Lava","params":{"palette":["amber","ocean","forest","candy","mono","ember"],"density":[10,100],"smooth":[0,1],"scale":[2,8]},"defaults":{"palette":"ember","density":50,"smooth":1,"scale":4}},{"id":"balls","name":"Balls","params":{"palette":["amber","ocean","forest","candy","mono","ember"],"count":[6,24],"size":[6,40],"bounce":[60,90],"trail":[0,1]},"defaults":{"palette":"candy","count":12,"size":16,"bounce":75,"trail":0}},{"id":"words","name":"Words","params":{"bounce":[0,100]},"defaults":{"bounce":60}}]}'
SCENES = {s["id"]: s["params"] for s in json.loads(SCENES_JSON)["scenes"]}
# Bench calibration model: a pretend QMI8658 mounted rotated (chip X up when the clip is upright, chip Z
# toward the viewer). Without a calibration the firmware uses the compiled map (identity here), so the
# face-up resting reading comes out wrong (+z) until POST /imu/calibrate has run both steps.
IMU_RAW = {"rest":[0.004,0.012,0.998], "upright":[0.991,0.013,-0.021], "faceup":[0.011,-0.006,0.996]}
imu = {"map":[[1,0,0],[0,1,0],[0,0,1]], "calibrated":False, "up":None, "face":None}
def now(): return int(time.time() + clock["delta"])
# Core dump (GET/DELETE /coredump, /status.resets.coredump): none by default; MOCK_COREDUMP=1 holds a fake
# 4 KB image (an ELF-looking header + a deterministic pattern) until DELETE /coredump erases it.
coredump = {"img": (b"\x7fELF\x01\x01\x01" + bytes(9) + bytes((i * 7 + 3) & 0xFF for i in range(4080)))
                   if os.environ.get("MOCK_COREDUMP") else None}
def hhmm(v, allow24):
    m = re.fullmatch(r"([0-9]{2}):([0-9]{2})", v) if isinstance(v, str) else None
    if not m: return None
    h, mi = int(m[1]), int(m[2])
    if mi > 59 or h > 24 or (h == 24 and (mi or not allow24)): return None
    return h*60 + mi
def in_window(it):
    if "from" not in it and "until" not in it: return True
    if not clock["synced"]: return False
    f = hhmm(it.get("from","00:00"), False); u = hhmm(it.get("until","24:00"), True)
    m = ((now() + cfg["tz_offset_s"]) % 86400) // 60
    return f <= m < u if f < u else (m >= f or m < u)
def int_in(v, lo, hi): return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi
def num_in(v, lo, hi): return isinstance(v, (int, float)) and not isinstance(v, bool) and lo <= v <= hi
def validate_scroll(sc):
    if sc is None: return True
    if not isinstance(sc, dict): return False
    return ((("px_per_s" not in sc) or num_in(sc["px_per_s"], 10, 400)) and sc.get("direction", "left") in ("left", "right")
            and (("gap_px" not in sc) or int_in(sc["gap_px"], 0, 2000)) and (("loops" not in sc) or int_in(sc["loops"], 1, 65535)))
def tokenize(txt):
    """Word count like core rsvp_tokenize for plain text: whitespace (no-break spaces join) and en/em dashes
    end words, words longer than 32 code points are split."""
    n = 0
    for w in re.split(r"[\s\u2028\u2029\ufeff\u200b]+", txt.replace("\u00a0", "\x01").replace("\u202f", "\x01").replace("\u2007", "\x01")):
        for part in re.split(r"(?<=[\u2013\u2014\u2015])", w):
            if part: n += (len(part) + 31) // 32
    return n
def text_json(k):
    t = texts[k]
    return {"id": k, "bytes": len(t["data"]), "words": t["words"], "title": t["title"], "progress_word": progress.get(k, 0),
            "sha256": hashlib.sha256(t["data"]).hexdigest(), "minutes": max(1, round(t["words"] / 300))}
ID_RE = r"[a-z0-9][a-z0-9-]{0,31}"
def validate_font(j):
    """-> None or (code, error). Mirrors core rsvp_font_parse (the whole document: normal, optional "compact" and,
    5f.11, optional "large", null = absent) then reader_font_validate (atlases: normal, compact, large)."""
    def syntax(f):
        if not isinstance(f, dict): return False
        for k in ("glyphs", "advance", "cell_w", "cell_h", "baseline", "atlas_white", "atlas_accent"):
            if k not in f: return False
        g, a = f["glyphs"], f["advance"]
        if not isinstance(g, str) or not 1 <= len(g) <= 256 or len(set(g)) != len(g): return False
        if not isinstance(a, list) or len(a) != len(g) or not all(int_in(v, 0, 1024) for v in a): return False
        if not int_in(f["cell_w"], 1, 536) or not int_in(f["cell_h"], 1, 240) or not int_in(f["baseline"], 0, f["cell_h"]): return False
        return all(isinstance(f[k], str) and re.fullmatch(ID_RE, f[k]) for k in ("atlas_white", "atlas_accent"))
    if not isinstance(j, dict): return (422, "malformed")
    faces = [j] + [j[k] for k in ("compact", "large") if j.get(k) is not None]
    if not all(syntax(f) for f in faces): return (422, "malformed")
    for f in faces:
        for k in ("atlas_white", "atlas_accent"):
            info = valid_hca(assets[f[k]]) if f[k] in assets else None
            if not info or not info["atlas"]: return (422, "unknown_asset")
            if (info["width"], info["height"]) != (f["cell_w"], f["cell_h"]) or info["frames"] < len(f["glyphs"]): return (422, "malformed")
    return None
def content_name(it):
    t = it.get("type")
    if t == "scene": return "scene:" + it.get("scene","")
    if t == "reader": return "reader:" + it.get("text","")
    if t == "oracle": return "oracle:" + (it.get("asset") or it.get("id") or "")
    if t == "board": return "board:" + (it.get("asset") or it.get("id") or "")
    return it.get("asset") or it.get("id")
# ---- Oracle (PROTOCOL 5f; firmware playlist.c parse_oracle / playlist_oracle_check, core/oracle.c) ----
OR_ASSETS = (("deck", 108, 206), ("keys", 160, 34))   # 5f.12: deck 108x206, keys 160x34 (optional); "notes" (5f.7) ignored
OR_BUNDLE_MAX = 96 * 1024          # PL_OR_BUNDLE_MAX
OR_LINE_MAX = 512                  # ORR_LINE_MAX: longer bundle lines are ignored
def bundle_lines(data):
    """{section: first usable line} like core orr_parse (lines with control chars, invalid UTF-8, blank or longer than
    ORR_LINE_MAX are skipped; a header is a whole line [name])"""
    out = {}; cur = None
    for raw in data.split(b"\n"):
        if raw.endswith(b"\r"): raw = raw[:-1]
        if len(raw) > OR_LINE_MAX or any((c < 0x20 and c != 9) or c == 0x7F for c in raw): continue
        try: l = raw.decode("utf-8")
        except UnicodeDecodeError: continue
        if len(l) >= 2 and l[0] == "[" and l[-1] == "]": cur = l[1:-1]; continue
        if cur is None or not l.strip(" \t"): continue
        out.setdefault(cur, l)
    return out
def or_briefs(bundle, cards):
    """card.<i>.brief of the bundle per card ("" = no detail screen for that card, 5f.7)"""
    t = texts.get(bundle)
    L = bundle_lines(t["data"]) if t else {}
    return [L.get("card.%d.brief" % i, "") for i in range(cards)]
def oracle_cfg(it):
    b = it.get("asset") or it.get("id")
    return dict(cards=it["cards"], face=it.get("face_ms", 0), page=it.get("page_ms", 0), hold=it.get("hold_ms", 300000),
                bundle=b, font=it.get("font"), briefs=or_briefs(b, it["cards"]))
# The mock does not compose (the clip runs core/oracle_reader.c orr_compose_lean on the bundle): fixed texts for every
# row. The lean draw (5f.7): five one-page screens (by card, by position, by the numbers, together, and; <= 150 chars).
OR_LEAN_TEXTS = (
    "I The Magician, a beginning. II The Popess, what ripens in silence. III The Empress, a creative force.",
    "You come from a beginning; in the centre, The Popess, the knowledge that waits; you go towards a flowering.",
    "The path climbs (I, II, III): a beginning, then gestation, then a flowering.",
    "The Empress looks back at The Popess: what you kept quiet wants to be born.",
    "Start with what is already in your hands.")
OR_LEAN_SCREENS = 5
# The full paragraph (5f.1; no screens since 5f.7, /status.oracle.reading on three / hold; <= 600 bytes UTF-8).
ORACLE_PARAGRAPH = ("The Magician, The High Priestess and The Empress: a beginning, a patient knowledge, a creative force. In the "
                    "centre, The High Priestess turns towards The Empress: what ripens in silence meets what wants to be born. "
                    "The path climbs (I, II, III): a beginning, then gestation, then a flowering. On the left, where you come from; "
                    "in the centre, what you live now; on the right, where it is going. Start with what is already in your hands.")
def or_has_reader():
    """every oracle item has the short reading and the paragraph (its bundle and font exist: deleting either removes it)"""
    c = orc["c"]
    return c["bundle"] in texts and c["font"] in fonts
def validate_oracle(it, a):
    """firmware parse_oracle + playlist_oracle_check + oracle_bundle_check -> None or (code, error); `a` = the bundle id"""
    if not isinstance(a, str) or not re.fullmatch(ID_RE, a): return (422,"invalid_playlist")
    # "mode", "daily" and "pages": accepted and ignored (5f.6: one reading only)
    if not int_in(it.get("cards"), 3, 78): return (422,"invalid_playlist")
    # "deck" required; "keys" optional (5f.12: absent -> no keyword row; present, null included: an asset id);
    # "notes" (5f.7) accepted and ignored
    for k in ("deck", "keys"):
        if k == "keys" and k not in it: continue
        if not isinstance(it.get(k), str) or not re.fullmatch(ID_RE, it[k]): return (422,"invalid_playlist")
    if "shake_g" in it and not num_in(it["shake_g"], 0.4, 2.0): return (422,"invalid_playlist")
    for k in ("face_ms", "page_ms", "hold_ms"):
        if k in it and not int_in(it[k], 0, 86400000): return (422,"invalid_playlist")
    # "reader" (5f.1, kept for one release) must be the id; "font" required, "font_big" optional ("pages" ignored)
    if "reader" in it and it["reader"] != a: return (422,"invalid_playlist")
    if not isinstance(it.get("font"), str) or not re.fullmatch(ID_RE, it["font"]): return (422,"invalid_playlist")
    if "font_big" in it and not (isinstance(it["font_big"], str) and re.fullmatch(ID_RE, it["font_big"])): return (422,"invalid_playlist")
    # playlist_oracle_check: bundle, fonts, then the three atlases
    if a not in texts: return (422,"unknown_text")
    if it["font"] not in fonts or ("font_big" in it and it["font_big"] not in fonts): return (422,"unknown_font")
    n = it["cards"]
    frames = {"deck": 1 + n, "keys": n}
    for role, w, h in OR_ASSETS:
        k = it.get(role)
        if k is None: continue
        if k not in assets: return (422,"unknown_asset")
        info = valid_hca(assets[k])
        if info["strip"] or not info["atlas"] or (info["width"], info["height"]) != (w, h) or info["frames"] != frames[role]:
            return (422,"invalid_playlist")
    # oracle_bundle_check: 1..96 KB, a [prompt] line and card.<i>.reading for every card
    d = texts[a]["data"]
    if not 0 < len(d) <= OR_BUNDLE_MAX: return (422,"invalid_playlist")
    L = bundle_lines(d)
    if not L.get("prompt") or any(not L.get("card.%d.reading" % i) for i in range(n)): return (422,"invalid_playlist")
    return None
orc = {"key": None}
# The state machine is a port of core/src/oracle.c (5f.3, 5f.6, 5f.7): waits -> shuffle (1.2 s) -> three -> lean
# screens 0..4 (one page each; a screen without text is skipped) -> detail A, B, C (one page each, only for a card whose
# bundle has a card.<i>.brief line) -> hold (the three) -> waits; POST /oracle/back walks it in reverse (waits is the
# floor, a shuffle runs to its end). Timers only when non-zero: face_ms on three, page_ms on each lean / detail screen;
# hold_ms is the idle timeout (no turn / back / draw for that long -> waits; 0 = never), counted from orc["idle0"];
# orc["t0"] = when the screen began. Every random draw: A, B, C distinct and not the previous draw's three as a set.
def or_reset(it, key):
    orc.update(key=key, it=it, c=oracle_cfg(it), phase="waits", t0=time.time(), idle0=time.time(), three=[-1,-1,-1],
               prev=None, screen=0)
def or_enter(ph, screen=0):
    orc.update(phase=ph, screen=screen, t0=time.time())
def or_to_waits(): or_enter("waits")
def or_pick_three():
    n = orc["c"]["cards"]
    for _ in range(64):
        t = random.sample(range(n), 3)
        if n == 3 or orc["prev"] is None or set(t) != set(orc["prev"]): return t
    return t
def or_draw(cards=None):
    """start_draw: the forced row, else random (distinct, not the previous set); the shuffle"""
    orc.update(three=list(cards) if cards else or_pick_three(), idle0=time.time())
    or_enter("shuffle")
def or_lean_has(s): return or_has_reader() and bool(OR_LEAN_TEXTS[s])
def or_detail_has(i): return bool(orc["c"]["briefs"][orc["three"][i]])
def or_find(has, frm, d, n):
    i = frm
    while 0 <= i < n:
        if has(i): return i
        i += d
    return -1
def or_forward_from_lean(frm):
    s = or_find(or_lean_has, frm, 1, OR_LEAN_SCREENS)
    if s >= 0: or_enter("lean", s); return
    d = or_find(or_detail_has, 0, 1, 3)
    if d >= 0: or_enter("detail", d)
    else: or_enter("hold")
def or_back_from_lean(frm):
    s = or_find(or_lean_has, frm, -1, OR_LEAN_SCREENS)
    if s >= 0: or_enter("lean", s)
    else: or_enter("three")
def or_next():
    """go_next: the next screen (a turn, or a screen timer)"""
    ph = orc["phase"]
    if ph == "waits": or_enter("armed")                          # 5f.8: a tap arms, a shake (or a tap) deals
    elif ph == "armed": or_draw()
    elif ph == "three": or_forward_from_lean(0)
    elif ph == "lean": or_forward_from_lean(orc["screen"] + 1)
    elif ph == "detail":
        d = or_find(or_detail_has, orc["screen"] + 1, 1, 3)
        if d >= 0: or_enter("detail", d)
        else: or_enter("hold")
    elif ph == "hold": or_to_waits()
def or_turn():
    orc["idle0"] = time.time()
    if orc["phase"] != "shuffle": or_next()
def or_back():
    ph = orc["phase"]
    orc["idle0"] = time.time()
    if ph in ("waits", "shuffle"): return                        # waits is the floor; a shuffle runs to its end
    if ph in ("armed", "three"): or_to_waits()                   # back on armed disarms
    elif ph == "lean": or_back_from_lean(orc["screen"] - 1)
    elif ph in ("detail", "hold"):
        d = or_find(or_detail_has, orc["screen"] - 1 if ph == "detail" else 2, -1, 3)
        if d >= 0: or_enter("detail", d)
        else: or_back_from_lean(OR_LEAN_SCREENS - 1)
def or_shake(g):
    """one shake edge of metric g (POST /bench/shake): deals only on armed (5f.8); elsewhere ignored, and an ignored
    shake does not reset the idle timer (the edge is used up; the mock's impulse re-arms at once)"""
    if g >= orc["it"].get("shake_g", 0.9) and orc["phase"] == "armed": or_draw()
def or_advance():
    c = orc["c"]
    if orc["phase"] != "waits" and c["hold"] and time.time() - orc["idle0"] >= c["hold"] / 1000.0:
        or_to_waits(); return
    for _ in range(64):
        ph = orc["phase"]
        if ph == "waits": return
        dur = 1200 if ph == "shuffle" else c["face"] if ph == "three" else c["page"] if ph in ("lean", "detail") else 0
        if not dur or time.time() - orc["t0"] < dur / 1000.0: return
        t1 = orc["t0"] + dur / 1000.0
        if ph == "shuffle": or_enter("three"); orc["prev"] = list(orc["three"])
        else: or_next()
        orc["t0"] = t1
def oracle_current():
    """the oracle item on screen (state advanced), else None"""
    it = current_item()
    if not it or it.get("type") != "oracle": return None
    key = json.dumps(it, sort_keys=True)
    if orc["key"] != key: or_reset(it, key)
    or_advance()
    return it
def oracle_status():
    """/status.oracle (5f.6, 5f.7): cards, state, cards_drawn, card, page, reading"""
    it = oracle_current()
    if not it: return {"cards":0,"state":"waits","cards_drawn":[-1,-1,-1],"card":-1,"page":-1,"reading":""}
    ph, sc = orc["phase"], orc["screen"]
    shown = ph not in ("waits", "armed", "shuffle")
    reading = (OR_LEAN_TEXTS[sc] if ph == "lean" else orc["c"]["briefs"][orc["three"][sc]] if ph == "detail" else
               ORACLE_PARAGRAPH if shown else "")
    return {"cards":orc["c"]["cards"],"state":ph,"cards_drawn":list(orc["three"]) if shown else [-1,-1,-1],
            "card":orc["three"][sc] if ph == "detail" else -1,"page":sc if ph in ("lean", "detail") else -1,"reading":reading}
WORDS_MAX, WORDS_MAX_W, WORDS_MAX_H, WORDS_MAX_PX = 12, 536, 240, 514560   # core/include/scene.h
def validate_words_sheet(a):
    """firmware playlist.c parse_words_sheet (PROTOCOL 5b.1): the sheet of a words scene ("id"; queue entries:
    "asset") -> None or (code, error). Any stored asset that fits (an atlas, as the app's sheets are, or 536x240)."""
    if not isinstance(a, str) or not re.fullmatch(ID_RE, a): return (422,"invalid_playlist")
    if a not in assets: return (422,"unknown_asset")
    info = valid_hca(assets[a])
    if (info["strip"] or not 1 <= info["frames"] <= WORDS_MAX or info["width"] > WORDS_MAX_W or info["height"] > WORDS_MAX_H
            or info["frames"] * info["width"] * info["height"] > WORDS_MAX_PX): return (422,"invalid_playlist")
    return None
BOARD_MAX_FRAMES, BOARD_MAX_ROWS, BOARD_MAX_PX = 48, 47, 1048576   # PROTOCOL 5g (firmware PL_BOARD_*)
def nint(v, lo, hi):
    """firmware playlist.c num_int: a JSON number (not a bool) with an integral value in lo..hi"""
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == int(v) and lo <= v <= hi
def validate_board(it, queue):
    """firmware playlist.c parse_board (PROTOCOL 5g) -> None or (code, error), in the firmware's order"""
    a = it.get("asset" if queue else "id")
    if not isinstance(a, str) or not re.fullmatch(ID_RE, a): return (422,"invalid_playlist")
    if a not in assets: return (422,"unknown_asset")
    info = valid_hca(assets[a]); n = info["frames"]
    if (info["strip"] or not 1 <= n <= BOARD_MAX_FRAMES or info["width"] > 536 or not 16 <= info["height"] <= 240
            or n * info["width"] * info["height"] > BOARD_MAX_PX): return (422,"invalid_playlist")
    for k in ("header", "empty"):                    # optional frames; null = absent
        if it.get(k) is not None and not nint(it[k], 0, n - 1): return (422,"invalid_playlist")
    if "scroll_px_s" in it and not nint(it["scroll_px_s"], 4, 60): return (422,"invalid_playlist")
    rows = it.get("rows")
    if not isinstance(rows, list) or not 1 <= len(rows) <= BOARD_MAX_ROWS: return (422,"invalid_playlist")
    for r in rows:
        if not isinstance(r, dict) or not nint(r.get("frame"), 0, n - 1): return (422,"invalid_playlist")
        if r.get("until") is not None and not nint(r["until"], 0, 4294967295): return (422,"invalid_playlist")
    return None
def validate_item(it, queue):
    """-> None or (code, error)"""
    if not isinstance(it, dict) or not isinstance(it.get("type"), str): return (422,"invalid_playlist")
    t = it["type"]
    if t == "asset":
        a = it.get("asset" if queue else "id")
        if a not in assets or valid_hca(assets[a])["atlas"]: return (422,"unknown_asset")
    elif t == "scene":
        sc = SCENES.get(it.get("scene"))
        if sc is None: return (422,"unknown_scene")
        p = it.get("params", {})
        if not isinstance(p, dict): return (422,"invalid_params")
        for k, v in p.items():
            if not isinstance(v, (str, int, float)): return (422,"invalid_params")
            d = sc.get(k)
            if d is None: continue
            if isinstance(d[0], str):
                if v not in d: return (422,"invalid_params")          # (bools are never enum values)
            else:
                if isinstance(v, bool): v = int(v)                       # booleans map to 1/0
                if not isinstance(v, int) or not d[0] <= v <= d[1]: return (422,"invalid_params")
        if it["scene"] == "words":
            e = validate_words_sheet(it.get("asset" if queue else "id"))
            if e: return e
        if "seed" in it and not int_in(it["seed"], 0, 4294967295): return (422,"invalid_playlist")
    elif t == "reader":
        tx, fo = it.get("text"), it.get("font")
        if not isinstance(tx, str) or not re.fullmatch(ID_RE, tx) or not isinstance(fo, str) or not re.fullmatch(ID_RE, fo): return (422,"invalid_playlist")
        if tx not in texts: return (422,"unknown_text")
        if fo not in fonts: return (422,"unknown_font")
        if "wpm" in it and not int_in(it["wpm"], 50, 1500): return (422,"invalid_playlist")
        if "from_word" in it and not int_in(it["from_word"], 0, 4294967295): return (422,"invalid_playlist")
        if "loop" in it and not isinstance(it["loop"], bool): return (422,"invalid_playlist")
    elif t == "oracle":
        e = validate_oracle(it, it.get("asset" if queue else "id"))
        if e: return e
    elif t == "board":
        e = validate_board(it, queue)
        if e: return e
    elif t not in (() if queue else ("clock","text")): return (422,"invalid_playlist")
    if not validate_scroll(it.get("scroll")): return (422,"invalid_playlist")
    if not queue:
        f, u = it.get("from"), it.get("until")
        if (f is not None and hhmm(f, False) is None) or (u is not None and hhmm(u, True) is None): return (422,"invalid_playlist")
        if (f is not None or u is not None) and hhmm(f or "00:00", False) == hhmm(u or "24:00", True): return (422,"invalid_playlist")
    return None
def validate_playlist(j):
    if not isinstance(j, dict) or not isinstance(j.get("items"), list): return (400,"bad_json")
    for it in j["items"]:
        e = validate_item(it, False)
        if e: return e
    q = j.get("queue", [])
    if not isinstance(q, list): return (400,"bad_json")
    if len(q) > 64: return (422,"invalid_playlist")
    seen = set()
    for e in q:
        if not isinstance(e, dict) or not isinstance(e.get("id"), str) or e["id"] in seen: return (422,"invalid_playlist")
        if not re.fullmatch(r"[\x20-\x7e]{1,40}", e["id"]): return (422,"invalid_playlist")
        if not isinstance(e.get("at"), (int, float)) or not 1600000000 <= e["at"] <= 4102444800: return (422,"invalid_playlist")
        seen.add(e["id"]); err = validate_item(e, True)
        if err: return err
    return None
def valid_hca(d):
    if len(d) < 32 or d[:4] != b"HCA1": return None
    w,h,n,pf,comp,loop,flags,fto,ds = struct.unpack_from("<HHHBBHHII", d, 4)
    if ds != len(d) or n == 0 or pf != 0 or comp not in (0, 1) or fto != 32: return None
    strip = bool(flags & 2)
    if strip:
        if flags & 1 or n != 1 or h != 240 or not 537 <= w <= 8192: return None
    elif not flags & 1 and (w, h) != (536, 240): return None
    elif w > 536 or h > 240: return None
    px = w*h
    for i in range(n):
        off, ln, dur, fl = struct.unpack_from("<IIHH", d, 32+12*i)
        if off+ln > len(d): return None
        if comp == 0:
            if ln != px*2: return None
            continue
        p, got, end = off, 0, off+ln
        while got < px:
            if p+2 > end: return None
            c = struct.unpack_from("<H", d, p)[0]; p += 2; k = (c & 0x7FFF)+1
            need = 2 if c & 0x8000 else 2*k
            if p+need > end or got+k > px: return None
            p += need; got += k
        if p != end: return None
    return dict(width=w,height=h,frames=n,atlas=bool(flags&1),strip=strip)
# ---- scheduler (mock model): rotation, /show end, queue entries; PROTOCOL 4 Scheduling + 5f.8 deferrals ----
# Rotation: active items (window open, not clock/text) rotate by their duration_ms; a lone active item is held
# (lone item rule); mock simplification: an item with no duration_ms (or 0) is held too. Queue entries fire at `at`
# (clock synced, screen on, not more than 600 s late: else skipped), one at a time, for duration_ms (default 60 s).
# 5f.8: while an oracle draw is in progress on screen (state != waits), its end (rotation duration_ms, /show
# override, queue entry), a queue entry's start and window changes are deferred; once back at waits they happen at
# once if still due. /show, PUT /playlist and POST /queue/test act at once.
rot = {"cur": None, "since": time.time()}       # cur = index into items of the rotation item on screen
def or_busy(it):
    """5f.8: `it` is the oracle on screen with a draw in progress (armed included)"""
    if not it or it.get("type") != "oracle" or orc.get("key") != json.dumps(it, sort_keys=True): return False
    or_advance()
    return orc["phase"] != "waits"
def rotation():
    """(index into items, item) of the rotation item on screen, or (-1, None); advances the rotation"""
    items = json.loads(playlist)["items"]; t = time.time()
    act = [i for i, it in enumerate(items) if in_window(it) and it.get("type") not in ("clock", "text")]
    cur = rot["cur"]
    if cur is not None and cur < len(items) and or_busy(items[cur]): return cur, items[cur]   # deferred
    if not act: rot["cur"] = None; return -1, None
    if cur not in act:                                     # first call, a new playlist, or its window closed
        cur = next((i for i in act if cur is not None and i > cur), act[0]); rot.update(cur=cur, since=t)
    for _ in range(64):
        if len(act) < 2: break
        d = items[cur].get("duration_ms") or 0
        if not isinstance(d, (int, float)) or d <= 0 or t < rot["since"] + d / 1000.0: break
        late = items[cur].get("type") == "oracle"            # an oracle's end may have waited for the draw: at once
        nxt = next((i for i in act if i > cur), act[0])
        rot.update(cur=nxt, since=t if late else rot["since"] + d / 1000.0); cur = nxt
    return cur, items[cur]
def show_item():
    sh = show["cur"]
    if sh and time.time() >= sh["until"] and not or_busy(sh["item"]): show["cur"] = sh = None
    return sh["item"] if sh else None
def queue_active():
    """the queue entry on screen (its end checked; deferred during a draw), else None"""
    doc = json.loads(playlist)
    qa = next((e for e in doc.get("queue", []) if e["id"] == queue_state["active"]), None)
    if qa is None: queue_state["active"] = None; return None
    d = qa.get("duration_ms") or 60000
    if time.time() >= queue_state.get("t0", 0) + d / 1000.0 and not or_busy(qa): queue_state["active"] = None; return None
    return qa
def queue_tick(shown):
    """start the next due queue entry (not during a draw, not while the panel is off or the clock unknown)"""
    if queue_state["active"] or not clock["synced"] or not session["display_on"] or or_busy(shown): return None
    for e in sorted(json.loads(playlist).get("queue", []), key=lambda e: e["at"]):
        if e["id"] in queue_state["done"] or e["at"] > now(): continue
        queue_state["done"].add(e["id"])
        if now() - e["at"] > 600: continue                  # more than 10 minutes late: skipped
        queue_state.update(active=e["id"], t0=time.time()); return e
    return None
def current_item():
    qa = queue_active()
    if qa: return qa
    shown = show_item() or rotation()[1]
    return queue_tick(shown) or shown
def reader_json():
    it = current_item()
    if not it or it.get("type") != "reader" or it.get("text") not in texts:
        return {"ok":True,"active":False,"text":None,"word":0,"words":0,"paused":False,"wpm":0}
    k = it["text"]; w = progress.get(k, 0)
    return {"ok":True,"active":True,"text":k,"word":w if w < texts[k]["words"] else 0,"words":texts[k]["words"],"paused":reader["paused"],
            "wpm":it.get("wpm",300),"font":it["font"],"title":texts[k]["title"],"end_card":False}
def drop_refs(refs):
    """firmware remove_refs: drop the playlist items / queue entries refs(it, queue) names; a /show of one ends"""
    global playlist
    doc = json.loads(playlist)
    doc["items"] = [it for it in doc["items"] if not refs(it, False)]
    if "queue" in doc: doc["queue"] = [e for e in doc["queue"] if not refs(e, True)]
    playlist = json.dumps(doc)
    if show["cur"] and refs(show["cur"]["item"], False): show["cur"] = None
def drop_text_refs(k):    # playlist_remove_reader("text"): reader items, oracle items whose bundle it is
    drop_refs(lambda it, q: (it.get("type") == "reader" and it.get("text") == k) or
                            (it.get("type") == "oracle" and it.get("asset" if q else "id") == k))
def drop_font_refs(k):    # playlist_remove_reader("font"): reader items, oracle items whose body font it is (not font_big)
    drop_refs(lambda it, q: it.get("type") in ("reader", "oracle") and it.get("font") == k)
def drop_asset_refs(k):   # playlist_remove_asset: asset items, oracle items using it as deck or keys (not notes),
    # words scene items whose sheet it is (5b.1)
    drop_refs(lambda it, q: (it.get("type") == "asset" and it.get("asset" if q else "id") == k) or
                            (it.get("type") == "oracle" and k in (it.get("deck"), it.get("keys"))) or
                            (((it.get("type") == "scene" and it.get("scene") == "words") or it.get("type") == "board")
                             and it.get("asset" if q else "id") == k))
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self, code, obj=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def err(self, code, e): self.send(code, {"ok":False,"error":e,"message":e})
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return self.rfile.read(n) if n else b""
    def jbody(self):
        b = self.body()
        try: j = jloads(b) if b else {}
        except Exception: return None
        return j if isinstance(j, dict) else None
    # PROTOCOL 4 "Request checks" (the firmware's http_request_allowed / json_type_ok). True = go on.
    def gate(self, method):
        h = self.headers; p = self.path.split("?")[0]
        host = (h.get("Host") or "").lower()
        if host.endswith(":80"): host = host[:-3]
        own = "%s:%d" % self.server.server_address
        if h.get("Origin") or (h.get("Sec-Fetch-Site") or "none").lower() not in ("none", "same-origin"):
            self.body(); self.err(403, "cross_origin"); return False
        if host and host not in ("192.168.4.1", "pixelclip.local", own, "localhost:%d" % self.server.server_address[1]):
            self.body(); self.err(403, "bad_host"); return False
        n = int(h.get("Content-Length") or 0)
        if n and json_route(method, p) and (h.get("Content-Type") or "").split(";")[0].strip().lower() != "application/json":
            self.body(); self.err(415, "unsupported_media_type"); return False
        return True
    def do_GET(self):
        if self.gate("GET"): self.get()
    def do_PUT(self):
        if self.gate("PUT"): self.put()
    def do_POST(self):
        if self.gate("POST"): self.post()
    def do_DELETE(self):
        if self.gate("DELETE"): self.delete()
    def get(self):
        p = self.path.split("?")[0]
        if p == "/status":
            doc = json.loads(playlist); items = doc["items"]; q = sorted(doc.get("queue", []), key=lambda e: e["at"])
            shown = current_item()
            ri = rotation()[0]; idx = ri if ri >= 0 else (0 if items else -1)
            qa = queue_active()
            cur = content_name(shown) if shown else None
            pend = [e for e in q if e["id"] not in queue_state["done"]]
            return self.send(200, {"ok":True,"device":{"name":cfg["name"],"id":"a1b2","fw":"0.1.0","hw":"ws-amoled-1.91","protocol":1},
              "battery":{"mv":3900,"pct":66,"charging":False,"usb_present":False},
              "power":{"usb_hold":False,"light_sleeps":0,"light_sleeps_while_usb":0,"awake_violations":0},
              "orientation":{"mode":cfg["orientation"],"flipped":orient_flipped()},"storage":{"total":10000000,"used":1000,"free":9999000},
              "playlist":{"count":len(items),"index":idx,"current":cur},"time":{"epoch":now() if clock["synced"] or clock["approx"] else 5,"tz_offset_s":cfg["tz_offset_s"],"synced":clock["synced"],
                "approximate":clock["approx"] and not clock["synced"],
                "anchor_age_s":int(time.time() - clock["anchor_t"]) if clock["approx"] and not clock["synced"] else None},
              "queue":{"pending":len(pend),"next_at":pend[0]["at"] if pend else None,"done":len(q)-len(pend),"active":qa["id"] if qa else None},
              "clock_ok":clock["synced"],"session":{"idle_s":0,"timeout_s":cfg["upload_timeout_s"],"always_on":cfg["wifi_always_on"],
              "display_on":session["display_on"],"clients":1},
              "oracle":oracle_status(),
              "resets":{"wdt":0,"brownout":0,"panic":1 if coredump["img"] else 0,"rtc_wdt":0,"last":"POWERON","coredump":coredump["img"] is not None},"uptime_s":10})
        if p == "/coredump":   # bulk (WiFi-only) on the clip
            if coredump["img"] is None: return self.err(404, "no_coredump")
            return self.send(200, raw=coredump["img"], ctype="application/octet-stream")
        if p == "/scenes": return self.send(200, raw=SCENES_JSON.encode())
        if p == "/texts": return self.send(200, {"ok":True,"texts":[text_json(k) for k in texts]})
        if p.startswith("/texts/"):
            k = p[7:]; return self.send(200, raw=texts[k]["data"], ctype="text/plain; charset=utf-8") if k in texts else self.err(404,"not_found")
        if p == "/fonts": return self.send(200, {"ok":True,"fonts":[{"id":k,"glyphs":len(f["glyphs"]),"cell_w":f["cell_w"],"cell_h":f["cell_h"],"compact":f.get("compact") is not None,"large":f.get("large") is not None} for k, f in fonts.items()]})
        if p.startswith("/fonts/"):
            k = p[7:]; return self.send(200, dict(fonts[k], ok=True)) if k in fonts else self.err(404,"unknown_font")
        if p == "/reader": return self.send(200, reader_json())
        if p == "/imu":
            H.imu_n = getattr(H, "imu_n", 0) + 25
            raw = IMU_RAW["rest"]; g = [round(sum(imu["map"][i][k]*raw[k] for k in range(3)), 3) for i in range(3)]
            return self.send(200, {"ok":True,"present":True,"g":g,"shake":0.003,"samples":H.imu_n,"g_lp":g,"raw":raw,"flipped":orient_flipped(),
              "calibrated":imu["calibrated"],"axis_map":imu["map"],"addr":"0x6B"})
        if p == "/assets": return self.send(200, {"ok":True,"assets":[dict(id=k,size=len(v),sha256=hashlib.sha256(v).hexdigest(),**valid_hca(v)) for k,v in assets.items()]})
        if p.startswith("/assets/"):
            k = p[8:]; return self.send(200, raw=assets[k], ctype="application/octet-stream") if k in assets else self.err(404,"not_found")
        if p == "/playlist": j = json.loads(playlist); j["ok"]=True; return self.send(200, j)
        if p == "/config": return self.send(200, cfg_view())
        if p == "/screenshot":
            # Screen-on session: the live framebuffer, so an animation on screen changes between two
            # screenshots (the mock moves a bar at 10 fps). Panel-off session: the static offscreen render.
            it = current_item(); live = 0
            if session["display_on"] and it and it.get("type") == "asset":
                a = assets.get(it.get("asset") or it.get("id"))
                info = valid_hca(a) if a else None
                if info and info["frames"] > 1: live = 1 + int((time.time() - session["t0"]) * 10) % info["frames"]
            fb = bytearray(bytes([0xF8,0x00])*(536*240//2)+bytes(536*240))
            # A strip with a scroll block moves (firmware: travel = px_per_s x t, endless for a lone
            # rotation item whatever its loops); a strip without one is a still. Panel-off: static.
            sc = it.get("scroll") if it and it.get("type") == "asset" else None
            sa = assets.get(it.get("asset") or it.get("id")) if sc is not None else None
            if session["display_on"] and sa and valid_hca(sa)["strip"]:
                t0 = show["cur"]["t0"] if show_item() is it else playlist_t0["t"]
                x = int((time.time() - t0) * sc.get("px_per_s", 80)) % 516
                for y in range(0, 120): fb[(y*536 + x)*2:(y*536 + x + 20)*2] = b"\x00\x1f"*20
            if live:
                for y in range(120, 240): fb[(y*536 + live*20)*2:(y*536 + live*20 + 20)*2] = b"\x07\xe0"*20
            return self.send(200, raw=bytes(fb), ctype="application/octet-stream")
        if p == "/ble":
            return self.send(200, {"ok":True,"enabled":cfg["ble_wake"],"name":"PixelClip-A1B2","service_uuid":BLE_SERVICE_UUID,"connected":False})
        if p == "/batlog": return self.send(200, raw=b"epoch,uptime_s,mv,pct,usb,mode,display,brightness\n1,2,3900,66,0,playing,on,160\n", ctype="text/csv")
        self.err(404,"not_found")
    def put(self):
        global playlist
        p = self.path
        if p.startswith("/assets/"):
            k = p[8:]
            if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", k): self.body(); return self.err(400,"invalid_id")
            h = self.headers.get("X-Content-SHA256")
            if not h or len(h) != 64: self.body(); return self.err(400,"missing_sha256")
            n = int(self.headers.get("Content-Length") or 0)
            if k in assets and hashlib.sha256(assets[k]).hexdigest()==h and len(assets[k])==n:
                self.body(); v=assets[k]; return self.send(409, dict(ok=False,error="exists",id=k,size=len(v),sha256=h,**valid_hca(v)))
            d = self.body()
            if hashlib.sha256(d).hexdigest() != h.lower(): return self.err(422,"sha256_mismatch")
            if not valid_hca(d): return self.err(422,"malformed")
            assets[k] = d; return self.send(201, {"ok":True,"id":k,"size":len(d),"sha256":h})
        if p.startswith("/texts/"):
            k = p[7:]
            if not re.fullmatch(ID_RE, k): self.body(); return self.err(400,"invalid_id")
            h = self.headers.get("X-Content-SHA256")
            if not h or len(h) != 64: self.body(); return self.err(400,"missing_sha256")
            n = int(self.headers.get("Content-Length") or 0)
            if n == 0: return self.err(411,"empty_body")
            if n > 1024*1024: self.body(); return self.err(413,"too_large")
            d = self.body()
            if k in texts and hashlib.sha256(texts[k]["data"]).hexdigest() == h.lower() and len(texts[k]["data"]) == n:
                return self.send(409, dict(text_json(k), ok=False, error="exists"))
            if hashlib.sha256(d).hexdigest() != h.lower(): return self.err(422,"sha256_mismatch")
            try: txt = d.decode("utf-8")
            except UnicodeDecodeError: return self.err(422,"malformed")
            words = tokenize(txt)
            if "\x00" in txt or words == 0: return self.err(422,"malformed")
            title = txt.lstrip("\ufeff").split("\n")[0].split("\r")[0].strip()
            while len(title.encode()) > 63: title = title[:-1]
            texts[k] = {"data": d, "words": words, "title": title}
            return self.send(201, dict(text_json(k), ok=True))
        if p.startswith("/fonts/"):
            k = p[7:]
            if not re.fullmatch(ID_RE, k): self.body(); return self.err(400,"invalid_id")
            b = self.body()
            if len(b) > 16384: return self.err(413,"too_large")
            try: j = jloads(b)
            except Exception: return self.err(422,"malformed")
            e = validate_font(j)
            if e: return self.err(*e)
            fonts[k] = j; return self.send(201, {"ok":True,"id":k,"size":len(b)})
        if p == "/playlist":
            b = self.body()
            try: j = jloads(b)
            except Exception: return self.err(400,"bad_json")
            e = validate_playlist(j)
            if e: return self.err(*e)
            ids = {q["id"] for q in j.get("queue", [])}
            queue_state["done"] &= ids          # forget done-state of ids no longer in the document
            queue_state["active"] = None
            for it in j["items"] + j.get("queue", []):
                if it.get("type") == "reader" and it.get("from_word", 0) > 0: progress[it["text"]] = it["from_word"]
            playlist = b.decode(); playlist_t0["t"] = time.time(); rot.update(cur=None, since=time.time()); return self.send(200, {"ok":True})
        if p == "/config":
            j = self.jbody()
            if j is None: return self.err(400,"bad_json")
            if "upload_timeout_s" in j and not 30 <= j["upload_timeout_s"] <= 1800: return self.err(422,"invalid_config")
            if any(k in j and not isinstance(j[k], bool) for k in CFG_BOOLS): return self.err(422,"invalid_config")
            if "orientation" in j and j["orientation"] not in ORIENTATIONS: return self.err(422,"invalid_config")
            if "low_battery_pct" in j and not num_in(j["low_battery_pct"], 0, 20): return self.err(422,"invalid_config")
            pw = j.get("ap_password")
            if "ap_password" in j and not (isinstance(pw, str) and 8 <= len(pw) <= 63 and all(" " <= c <= "~" for c in pw)):
                return self.err(422,"invalid_config")
            cfg.update(j); return self.send(200, cfg_view())
        self.err(404,"not_found")
    def post(self):
        p = self.path
        if p == "/time":
            j = self.jbody()
            if j is None: return self.err(400,"bad_json")
            if not (1600000000 <= j.get("epoch",0) <= 4102444800): return self.err(422,"invalid_time")
            clock["synced"]=True; clock["approx"]=False; clock["delta"]=j["epoch"]-time.time(); cfg["tz_offset_s"]=j.get("tz_offset_s",cfg["tz_offset_s"]); return self.send(200,{"ok":True})
        if p == "/brightness":
            j = self.jbody()
            if j is None: return self.err(400,"bad_json")
            v = j.get("value",-1)
            return self.send(200,{"ok":True}) if 0<=v<=255 else self.err(422,"invalid_brightness")
        if p == "/session/end" and cfg["wifi_always_on"]:
            self.body(); return self.send(200, {"ok":True,"always_on":True,"message":"wifi_always_on: the hotspot stays up"})
        if p in ("/next","/prev","/session/end"): self.body(); queue_state["active"]=None; show["cur"]=None; return self.send(200,{"ok":True})
        if p == "/reader":
            j = self.jbody()
            if j is None: return self.err(400,"bad_json")
            a = j.get("action")
            if not isinstance(a, str): return self.err(400,"bad_json")
            if a not in ("pause","resume","seek"): return self.err(422,"invalid_action")
            w = j.get("word")
            if a == "seek" and not int_in(w, 0, 4294967295): return self.err(422,"invalid_word")
            r = reader_json()
            if not r["active"]: return self.err(409,"no_reader")
            if a == "seek":
                if w >= r["words"]: return self.err(422,"invalid_word")
                progress[r["text"]] = w
            else: reader["paused"] = a == "pause"
            return self.send(200, reader_json())
        if p == "/queue/test":
            j = self.jbody()
            if j is None or not isinstance(j.get("id"), str): return self.err(400,"bad_json")
            if j["id"] not in [e["id"] for e in json.loads(playlist).get("queue", [])]: return self.err(404,"unknown_entry")
            queue_state.update(active=j["id"], t0=time.time()); return self.send(200,{"ok":True})
        if p == "/imu/calibrate":
            j = self.jbody()
            if j is None or not isinstance(j.get("step"), str): return self.err(400,"bad_json")
            st = j["step"]
            if st == "reset":
                imu.update(map=[[1,0,0],[0,1,0],[0,0,1]], calibrated=False, up=None, face=None)
                return self.send(200, {"ok":True,"step":st,"calibrated":False,"axis_map":imu["map"]})
            if st not in ("upright","faceup"): return self.err(422,"invalid_step")
            raw = IMU_RAW[st]; imu["up" if st == "upright" else "face"] = raw
            if imu["up"] is None or imu["face"] is None:
                return self.send(200, {"ok":True,"step":st,"raw":raw,"next":"faceup" if imu["up"] else "upright","calibrated":imu["calibrated"]})
            up, face = imu["up"], imu["face"]; imu["up"] = imu["face"] = None
            # scene_axis_map_calibrate(): row y = sign*axis of the upright reading, row z = -(face-up axis), x = y cross z
            ay = max(range(3), key=lambda k: abs(up[k])); az = max(range(3), key=lambda k: abs(face[k]))
            if ay == az: return self.err(422,"calibration_failed")
            ry = [0,0,0]; ry[ay] = 1 if up[ay] > 0 else -1
            rz = [0,0,0]; rz[az] = -1 if face[az] > 0 else 1
            rx = [ry[1]*rz[2]-ry[2]*rz[1], ry[2]*rz[0]-ry[0]*rz[2], ry[0]*rz[1]-ry[1]*rz[0]]
            imu.update(map=[rx, ry, rz], calibrated=True)
            return self.send(200, {"ok":True,"step":st,"raw":raw,"calibrated":True,"axis_map":imu["map"]})
        if p == "/bench/shake":                  # mock only (the clip has no such route): one shake edge
            j = self.jbody()
            if j is None: return self.err(400,"bad_json")
            g = j.get("g", 2.0)
            if not num_in(g, 0, 16): return self.err(422,"invalid_g")
            if not oracle_current() or not session["display_on"]: return self.err(409,"not_showing")
            or_shake(g)
            return self.send(200, dict(oracle_status(), ok=True))
        if p in ("/oracle/draw", "/oracle/turn", "/oracle/back"):
            j = self.jbody()
            if j is None: return self.err(400,"bad_json")
            # draw (5f.6): {"cards":[a,b,c]} forces the row (three distinct integers 0..77, then < the item's cards);
            # no "cards" (or null): random; other keys are ignored
            k = j.get("cards") if p == "/oracle/draw" else None
            if k is not None:
                ok = isinstance(k, list) and len(k) == 3 and all(
                    isinstance(v, (int, float)) and not isinstance(v, bool) and v == int(v) and 0 <= v < 78 for v in k)
                if not ok or len({int(v) for v in k}) != 3: return self.err(422,"invalid_cards")
                k = [int(v) for v in k]
            it = oracle_current()
            if not it or not session["display_on"]: return self.err(409,"not_showing")
            if k is not None and max(k) >= orc["c"]["cards"]: return self.err(422,"invalid_cards")
            if p == "/oracle/draw": or_draw(k)
            elif p == "/oracle/turn": or_turn()
            else: or_back()                      # PROTOCOL 5f.3 extension: the previous screen (a double tap)
            return self.send(200, dict(oracle_status(), ok=True))
        if p.startswith("/show/"):
            k = p[6:]; j = self.jbody()
            if j is None: return self.err(400,"bad_json")
            if "type" in j:
                # firmware playlist_parse_show_item: an oracle, a scene (5b.1: words) or a board (5g) item body, the
                # path names the asset
                if j["type"] not in ("oracle", "scene", "board"): return self.err(422,"invalid_item")
                it = dict(j, id=k)
                e = validate_oracle(it, k) if j["type"] == "oracle" else validate_item(it, False)
                if e: return self.err(404,"unknown_asset") if e[1] == "unknown_asset" else self.err(422,"invalid_item")
                d = it.get("duration_ms", 0)
                if not num_in(d, 0, 86400000): return self.err(422,"invalid_item")
                show["cur"] = {"item":it, "t0":time.time(), "until":time.time() + (d or 60000)/1000.0}
                return self.send(200,{"ok":True})
            d = j.get("duration_ms", 0)
            if not num_in(d, 0, 86400000): return self.err(422,"invalid_duration")
            if not validate_scroll(j.get("scroll")): return self.err(422,"invalid_scroll")
            if k in assets and j.get("scroll") is None and self.words_src(k):
                it = self.words_src(k)               # 5b.1 / 5g: a sheet a words item or a board uses is shown as it
            elif k in assets and not valid_hca(assets[k])["atlas"]:
                it = {"type":"asset","id":k}
                info = valid_hca(assets[k])
                if info["strip"]:
                    # Firmware: the given scroll, else the first playlist item / queue entry showing the
                    # asset with one (its loops dropped), else the default (80 px/s, left, gap 0).
                    sc = j.get("scroll")
                    if sc is None:
                        doc = json.loads(playlist)
                        sc = next((x["scroll"] for x in doc["items"] if x.get("type") == "asset" and x.get("id") == k and "scroll" in x), None)
                        sc = sc or next((x["scroll"] for x in doc.get("queue", []) if x.get("type") == "asset" and x.get("asset") == k and "scroll" in x), None)
                        sc = {kk: v for kk, v in (sc or {"px_per_s":80}).items() if kk != "loops"}
                    it["scroll"] = sc
                    if not d and "loops" in sc:
                        d = 1000 * (536 + sc["loops"]*info["width"] + (sc["loops"]-1)*sc.get("gap_px",0)) / sc.get("px_per_s",80)
            elif k in texts and self.oracle_src(k): it = self.oracle_src(k)
            else: return self.err(404,"unknown_asset")
            show["cur"] = {"item":it, "t0":time.time(), "until":time.time() + (d or 60000)/1000.0}
            return self.send(200,{"ok":True})
        self.err(404,"not_found")
    @staticmethod
    def words_src(k):
        """show_item_borrow (5b.1, 5g): the first words or board playlist item (then queue entry) whose sheet is asset k,
        as a shown item, else None"""
        doc = json.loads(playlist)
        w = lambda x: (x.get("type") == "scene" and x.get("scene") == "words") or x.get("type") == "board"
        src = next((x for x in doc["items"] if w(x) and x.get("id") == k), None)
        src = src or next((x for x in doc.get("queue", []) if w(x) and x.get("asset") == k), None)
        if not src: return None
        it = {kk: v for kk, v in src.items() if kk not in ("id","asset","at","duration_ms","transition","from","until")}
        it.update(id=k); return it
    @staticmethod
    def oracle_src(k):
        """firmware playlist_oracle_uses: the first oracle playlist item (then queue entry) whose bundle is text k, as a
        shown item (the old show borrow), else None"""
        doc = json.loads(playlist)
        src = next((x for x in doc["items"] if x.get("type") == "oracle" and x.get("id") == k), None)
        src = src or next((x for x in doc.get("queue", []) if x.get("type") == "oracle" and x.get("asset") == k), None)
        if not src: return None
        it = {kk: v for kk, v in src.items() if kk not in ("id","asset","at","duration_ms","transition","from","until")}
        it.update(id=k); return it
    def delete(self):
        p = self.path
        if p.startswith("/assets/"):
            k=p[8:]
            if k in assets:
                del assets[k]
                if show_item() and show_item().get("id") == k: show["cur"] = None
                drop_asset_refs(k)
                return self.send(200,{"ok":True})
            return self.err(404,"not_found")
        if p == "/batlog": return self.send(200,{"ok":True})
        if p == "/coredump":
            if coredump["img"] is None: return self.err(404, "no_coredump")
            coredump["img"] = None; return self.send(200, {"ok": True})
        if p.startswith("/texts/"):
            k = p[7:]
            if k not in texts: return self.err(404,"not_found")
            del texts[k]; progress.pop(k, None); drop_text_refs(k); return self.send(200,{"ok":True})
        if p.startswith("/fonts/"):
            k = p[7:]
            if k not in fonts: return self.err(404,"unknown_font")
            del fonts[k]; drop_font_refs(k); return self.send(200,{"ok":True})
        self.err(404,"not_found")
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
