#!/usr/bin/env bash
# e2e.sh [SSID] — end-to-end test of a real clip from this Mac over its SoftAP (PROTOCOL §3/§4).
#
#   scripts/e2e.sh                 # SSID taken from firmware/last_boot.log (written by flash.sh)
#   scripts/e2e.sh PixelClip-A1B2
#   PIXELCLIP_PASS=... scripts/e2e.sh   # if the AP passphrase was changed with PUT /config
#   PREV_SSID="My WiFi" scripts/e2e.sh   # rejoin this network at the end (else Wi-Fi is power-cycled
#                                        # so macOS auto-joins its preferred network)
#   SKIP_WIFI=1 CLIP=http://127.0.0.1:8080 scripts/e2e.sh   # already joined / mock server: no Wi-Fi juggling
#   E2E_OTA=1 scripts/e2e.sh       # also POST build/pixelclip.bin to /ota (clip reboots; runs last). The clip
#                                  # shows "Update?": press its button once when the script asks you to.
#   E2E_CLEAR_BATLOG=1             # also DELETE /batlog (wipes the discharge log)
#   KEEP_SESSION=1                 # do not POST /session/end at the end
#   E2E_CALIB=1                    # interactive IMU bench calibration (prompts you to hold the clip
#                                  # upright, then face up); stores the axis map on the clip. Against the
#                                  # mock (CLIP on 127.0.0.1/localhost) the calibration flow runs automatically.
#
# Why no SSID scan: on current macOS (14.4+) Wi-Fi scan results from system_profiler, ipconfig and
# CoreWLAN show "<redacted>" unless the terminal has Location Services permission, and `airport` is
# gone. So the script polls by trying to join the known SSID until the AP is up.
#
# The test uploads the three fixtures under their own ids (deleting earlier copies first), replaces
# the playlist, changes brightness/config and restores the config, moves the
# clip's clock to test time windows (then restores it), exercises the queue (POST /queue/test),
# scenes (GET /scenes, a scene item, seed), scrolling strips (generated here: uploads, rejects, scroll
# items), orientation (config round trip of auto/normal/flipped, 422s, /status.orientation, /imu.flipped; restored),
# GET /imu (+ POST /imu/calibrate error paths) and Reader mode (generated text + font pair: /texts,
# /fonts, reader items, POST/GET /reader, 409/413/422 cases), and finally restores the 3-item playlist and
# deletes the test strips, text, font and atlases. Session modes: the display_during_upload /
# wifi_always_on / ble_wake config round-trip, /status session flags, a live screenshot, always-on
# (/session/end ignored) and GET /ble. Words (§5b.1: generated sheets, words items / queue / /show, 422s, delete).
# Board (§5g: a generated sheet of rows, board items / queue / /show, every 422, accepted edge cases, delete).
# Oracle (generated deck / keys atlases via hcaenc (notes: ignored), the
# core/fixtures/tarot/reader-en.txt bundle as the item's id (§5f.2: text drawn from the bundle) and a reader font:
# one three-card reading (§5f.6: forced rows, random rows never repeating the last set), the lean draw (§5f.7: three,
# five lean screens, a detail screen per card with a brief, hold; the paragraph in /status.oracle.reading on three /
# hold), POST /oracle/draw|turn|back with full forward / backward walks, a bundle without briefs, the idle timeout
# (hold_ms), default timers, /show borrow, deletes that remove the item, 404/409/422 cases). The removed Magic 8 Ball stays gone (eightball items 422, no route, no status key). Crash diagnostics: a core dump (GET /coredump) is saved to
# firmware/e2e_coredump.bin and never deleted. Each assertion prints PASS/FAIL; the exit status is non-zero if any failed.
set -uo pipefail

FW="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$FW/.." && pwd)"
FIX="$REPO/tools/fixtures"
CLIP="${CLIP:-http://192.168.4.1}"
PASSPHRASE="${PIXELCLIP_PASS:-pixelclip-2026}"
TMP="$(mktemp -d -t pixelclip-e2e)"
FAILS=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); printf '  PASS  %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$*"; }
info() { printf '  ....  %s\n' "$*"; }
sha()  { shasum -a 256 "$1" | cut -d' ' -f1; }

for f in gradient anim12 rsvp-dot-w; do
    [ -f "$FIX/$f.hca" ] || { echo "missing fixture $FIX/$f.hca (run tools/fixtures/make_fixtures.sh)"; exit 2; }
done

# ---------------------------------------------------------------- HTTP helpers
# What the clip sends back is DATA, never code (security audit WIFI-7): the clip on the other end may be an
# impostor with the published SSID and passphrase, or run someone else's firmware. So
#   - a response never becomes part of a Python expression, of shell arithmetic or of a command: the expressions
#     below are written here, and a value read from the clip that a check needs is handed to them as an
#     argument (`a[0]`, `a[1]`, ...: plain strings), never pasted into their text;
#   - a value kept in a shell variable is read with a typed reader (jint / jbool / jenum), which prints it only
#     if it has exactly that shape and fails otherwise;
#   - everything printed to the terminal is reduced to printable ASCII first (`clean`).
# clean [MAX]  -> stdin on one line as printable ASCII (anything else becomes '?'), at most MAX characters (default 300)
clean() { LC_ALL=C tr -d '\r' | LC_ALL=C tr '\n\t' '  ' | LC_ALL=C tr -c '\40-\176' '?' | head -c "${1:-300}" | sed -e 's/ *$//'; }
# req METHOD PATH [curl args...]  ->  $CODE, body in $TMP/body (and $BODY: its first 2000 bytes, cleaned, for messages)
req() {
    local method="$1" path="$2"; shift 2
    CODE=$(curl -sS -m 60 -H 'Expect:' -o "$TMP/body" -w '%{http_code}' -X "$method" "$CLIP$path" "$@" 2>"$TMP/curl.err")
    [[ $CODE =~ ^[0-9]{3}$ ]] || CODE=000
    BODY=$(head -c 2000 "$TMP/body" 2>/dev/null | clean 2000 || true)
}
# The evaluator behind jget / jjson / jint / jbool / jenum: MODE BODY-FILE EXPR [ARGS...]. EXPR is an expression
# written in this script; it sees the JSON body as `j` and ARGS as the list of strings `a`. No builtins that
# import, open, execute or reflect (a second line of defence: nothing from the clip reaches EXPR anyway).
cat >"$TMP/jq.py" <<'PY'
import builtins, json, sys
mode, path, expr, a = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
SAFE = {n: getattr(builtins, n) for n in (
    "abs", "all", "any", "bool", "bytes", "dict", "enumerate", "filter", "float", "frozenset", "int",
    "isinstance", "len", "list", "map", "max", "min", "range", "reversed", "round", "set", "sorted", "str",
    "sum", "tuple", "zip")}
try:
    with open(path, encoding="utf-8") as f:
        j = json.load(f)
    v = eval(expr, {"__builtins__": SAFE, "json": json, "j": j, "a": a})
except Exception:
    sys.exit(1)
if mode == "json":                       # exact, ASCII only: for values handed back to a later check as an argument
    out = json.dumps(v)
elif mode == "int":                      # a JSON integer (not a bool, not a float, not a string)
    if not isinstance(v, int) or isinstance(v, bool) or abs(v) >= 10 ** 15: sys.exit(1)
    out = str(v)
elif mode == "bool":
    if not isinstance(v, bool): sys.exit(1)
    out = str(v)
elif mode == "enum":                     # a string that is one of ARGS
    if not isinstance(v, str) or v not in a: sys.exit(1)
    out = v
else:                                    # "text": for comparisons with a literal and for messages
    out = "".join(c if " " <= c <= "~" else "?" for c in str(v))[:2000]
print(out)
PY
# jget EXPR [ARGS...]   -> the value as printable ASCII text (True / False for booleans), nothing if EXPR fails
jget()  { local e="$1"; shift; python3 "$TMP/jq.py" text "$TMP/body" "$e" "$@" 2>/dev/null; }
# jjson EXPR [ARGS...]  -> the value as JSON (ASCII)
jjson() { local e="$1"; shift; python3 "$TMP/jq.py" json "$TMP/body" "$e" "$@" 2>/dev/null; }
# jint EXPR / jbool EXPR / jenum EXPR CHOICE...  -> the value if it is an integer / True|False / one of the
# choices; else nothing and a non-zero status. The shell checks the shape again before it prints.
jint()  { local v; v=$(python3 "$TMP/jq.py" int "$TMP/body" "$1" 2>/dev/null) && [[ $v =~ ^-?(0|[1-9][0-9]{0,14})$ ]] && printf '%s\n' "$v"; }
jbool() { local v; v=$(python3 "$TMP/jq.py" bool "$TMP/body" "$1" 2>/dev/null) && { [ "$v" = True ] || [ "$v" = False ]; } && printf '%s\n' "$v"; }
jenum() {
    local e="$1" v c; shift
    v=$(python3 "$TMP/jq.py" enum "$TMP/body" "$e" "$@" 2>/dev/null) || return 1
    for c in "$@"; do [ "$v" = "$c" ] && { printf '%s\n' "$v"; return 0; }; done
    return 1
}
# expect CODE DESCRIPTION [python-bool-expr on j [ARGS...]]   (ARGS: the strings a[0], a[1], ... of the expression)
expect() {
    local want="$1" desc="$2" expr="${3:-}"
    if [ $# -ge 3 ]; then shift 3; else shift $#; fi
    if [ "$CODE" != "$want" ]; then
        fail "$desc: HTTP $CODE (want $want) $(printf '%s' "$BODY" | head -c 200)$(clean 200 <"$TMP/curl.err" 2>/dev/null)"
        return 1
    fi
    if [ -n "$expr" ] && [ "$(jget "bool($expr)" "$@")" != "True" ]; then
        fail "$desc: body check failed ($expr): $(printf '%s' "$BODY" | head -c 300)"
        return 1
    fi
    pass "$desc"
    return 0
}
# poll_status EXPR TIMEOUT_S  -> GET /status every 0.25 s until the python bool EXPR (on j) holds or the time is up;
# the last response stays in $TMP/body / $CODE for the following expect (timing checks wait on state, not sleeps).
poll_status() {
    local expr="$1" end=$(( $(date +%s) + ${2:-3} ))
    while :; do
        req GET /status
        [ "$CODE" = 200 ] && [ "$(jget "bool($expr)")" = True ] && return 0
        [ "$(date +%s)" -ge "$end" ] && return 1
        sleep 0.25
    done
}
put_asset() { # put_asset ID FILE [SHA]
    local id="$1" file="$2" h="${3:-$(sha "$2")}"
    req PUT "/assets/$id" -H "X-Content-SHA256: $h" -H 'Content-Type: application/octet-stream' --data-binary "@$file"
}

# ---------------------------------------------------------------- Wi-Fi join / restore
IFACE=$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
JOINED=0
restore_wifi() {
    [ "$JOINED" = 1 ] || return 0
    echo
    echo "== restoring Wi-Fi"
    networksetup -removepreferredwirelessnetwork "$IFACE" "$SSID" >/dev/null 2>&1 || true
    if [ -n "${PREV_SSID:-}" ]; then
        networksetup -setairportnetwork "$IFACE" "$PREV_SSID" >/dev/null 2>&1 || true
    else
        # The previous SSID is redacted by macOS, so let it auto-join its preferred network.
        networksetup -setairportpower "$IFACE" off; sleep 2; networksetup -setairportpower "$IFACE" on
    fi
    for _ in $(seq 1 30); do
        ip=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
        if [ -n "$ip" ] && [ "${ip#192.168.4.}" = "$ip" ]; then info "back on the previous network ($ip)"; return 0; fi
        sleep 1
    done
    info "not yet back on a network: check the Wi-Fi menu"
}
cleanup() { restore_wifi; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ -z "${SKIP_WIFI:-}" ]; then
    [ -n "$IFACE" ] || { echo "no Wi-Fi interface found"; exit 2; }
    SSID="${1:-${PIXELCLIP_SSID:-}}"
    if [ -z "$SSID" ] && [ -f "$FW/last_boot.log" ]; then
        SSID=$(grep -Eo 'SSID PixelClip-[0-9A-F]{4}|ssid PixelClip-[0-9A-F]{4}' "$FW/last_boot.log" | head -n1 | awk '{print $2}')
    fi
    if [ -z "$SSID" ]; then
        echo "Pass the clip's SSID (shown on its splash screen, e.g. PixelClip-A1B2): scripts/e2e.sh PixelClip-A1B2"
        exit 2
    fi
    cat <<MSG
== join $SSID on $IFACE
   Long-press BOOT on the clip (hold 1.5-6 s, then release), or run scripts/ble_wake.py. It shows
   "WiFi: $SSID" for 2 s (3 s and then a dark panel with display_during_upload false) and starts the
   access point. Waiting up to 120 s...
MSG
    deadline=$((SECONDS + 120))
    while :; do
        out=$(networksetup -setairportnetwork "$IFACE" "$SSID" "$PASSPHRASE" 2>&1 || true)
        ip=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
        if [ "${ip#192.168.4.}" != "$ip" ] && curl -s -m 3 -o /dev/null "$CLIP/status"; then
            JOINED=1
            pass "joined $SSID, got $ip"
            break
        fi
        if [ $SECONDS -ge $deadline ]; then
            fail "could not join $SSID within 120 s (last: ${out:-no output}, ip ${ip:-none})"
            echo "RESULT: FAIL"; exit 1
        fi
        sleep 3
    done
else
    SSID="(skipped)"
    info "SKIP_WIFI set: talking to $CLIP directly"
fi

echo "== status"
req GET /status
expect 200 "GET /status" "j['ok'] is True and j['device']['protocol']==1 and j['device']['hw']=='ws-amoled-1.91'" &&
    info "fw $(jget "j['device']['fw']"), id $(jget "j['device']['id']"), battery $(jget "j['battery']['mv']") mV / $(jget "j['battery']['pct']")%, storage free $(jget "j['storage']['free']") B, idle timeout $(jget "j['session']['timeout_s']") s"
expect 200 "status has battery/storage/playlist/time/session/uptime" \
    "all(k in j for k in ('battery','storage','playlist','time','session','uptime_s')) and j['storage']['total']>0 and 2500<=j['battery']['mv']<=4500"
# Reset counters (README "Light sleep on battery"): rtc_wdt > 0 means the light-sleep safety net fired.
expect 200 "status.resets: wdt / brownout / panic / rtc_wdt counters (ints >= 0) and this boot's reason" \
    "(lambda r: all(isinstance(r.get(k),int) and not isinstance(r.get(k),bool) and r[k]>=0 for k in ('wdt','brownout','panic','rtc_wdt')) and isinstance(r.get('last'),str) and r['last'])(j['resets'])" &&
    info "resets: $(jget "j['resets']")"
# USB light-sleep inhibit (README "USB light-sleep inhibit"): on USB the clip holds POWER_AWAKE_USB and never
# light-sleeps (each light sleep disables the USB-Serial-JTAG pad: the host loses the port). On battery (or the
# mock, which models a clip on battery) only the field types are checked.
expect 200 "status.power: usb_hold / light-sleep counters; with USB present the usb hold is on and light_sleeps_while_usb == 0" \
    "(lambda p, u: isinstance(p.get('usb_hold'), bool) and all(isinstance(p.get(k), int) and not isinstance(p.get(k), bool) and p[k] >= 0 for k in ('light_sleeps','light_sleeps_while_usb','awake_violations')) and isinstance(u, bool) and (not u or (p['usb_hold'] and p['light_sleeps_while_usb'] == 0)))(j.get('power', {}), j['battery'].get('usb_present'))" &&
    info "power: $(jget "j['power']") (usb_present $(jget "j['battery']['usb_present']")$([ "$(jget "j['battery']['usb_present']")" = True ] || echo ': the USB branch is not exercised'))"

echo "== crash diagnostics (GET/DELETE /coredump, /status.resets.coredump)"
# A core dump stored on the clip is the evidence of a crash: it is saved to firmware/e2e_coredump.bin and NOT
# deleted here (decode it with `idf.py coredump-info -c firmware/e2e_coredump.bin`; erase it on the clip with
# DELETE /coredump once read). With no dump both GET and DELETE answer 404 no_coredump.
req GET /status
expect 200 "status.resets.coredump is a boolean" "isinstance(j['resets'].get('coredump'), bool)"
CD_FLAG=$(jbool "j['resets'].get('coredump')") || CD_FLAG=invalid
req GET /coredump -D "$TMP/coredump.hdr"
if [ "$CODE" = 200 ]; then
    CD_SIZE=$(wc -c <"$TMP/body" | tr -d ' ')
    CD_TYPE=$(tr -d '\r' <"$TMP/coredump.hdr" | awk -F': *' 'tolower($1)=="content-type"{t=$2} END{print t}' | clean 80)
    if [ "$CD_SIZE" -gt 0 ] && [ "${CD_TYPE%%;*}" = application/octet-stream ]; then
        pass "GET /coredump: 200 $CD_TYPE, $CD_SIZE B (the clip recorded a crash)"
    else
        fail "GET /coredump: 200 but $CD_SIZE B, Content-Type '${CD_TYPE}' (want > 0 B application/octet-stream)"
    fi
    cp "$TMP/body" "$FW/e2e_coredump.bin"
    if cmp -s "$TMP/body" "$FW/e2e_coredump.bin"; then
        pass "core dump saved to firmware/e2e_coredump.bin ($CD_SIZE B; left on the clip, not deleted)"
    else
        fail "could not save the core dump to $FW/e2e_coredump.bin"
    fi
    if [ "$CD_FLAG" = True ]; then pass "status.resets.coredump true while a dump is stored"
    else fail "GET /coredump returned a dump but status.resets.coredump is $CD_FLAG"; fi
else
    expect 404 "GET /coredump with no dump -> 404 no_coredump" "j['ok'] is False and j['error']=='no_coredump'"
    req DELETE /coredump
    expect 404 "DELETE /coredump with no dump -> 404 no_coredump" "j['ok'] is False and j['error']=='no_coredump'"
    if [ "$CD_FLAG" = False ]; then pass "status.resets.coredump false with no dump stored"
    else fail "no core dump (404) but status.resets.coredump is $CD_FLAG"; fi
fi

echo "== time"
# Before the sync: the clock state the clip booted with. "approximate" = rebuilt from the NVS time anchor
# (the clip was synced before the reboot): a real date, anchor_age_s = seconds since that anchor, never
# synced. Neither synced nor approximate = unknown (no anchor ever saved: 1970), anchor_age_s null.
req GET /status
expect 200 "status.time has synced / approximate (bools) and anchor_age_s (int >= 0 or null)" \
    "(lambda t: isinstance(t['synced'],bool) and isinstance(t.get('approximate'),bool) and 'anchor_age_s' in t and (t['anchor_age_s'] is None or (isinstance(t['anchor_age_s'],int) and t['anchor_age_s']>=0)))(j['time'])"
expect 200 "time state is consistent (not synced+approximate; anchor_age_s set iff approximate; approximate/synced => a real date; clock_ok == synced)" \
    "(lambda t: not (t['synced'] and t['approximate']) and ((t['anchor_age_s'] is not None) == t['approximate']) and (t['epoch']>=1577836800 or not (t['synced'] or t['approximate'])) and j['clock_ok']==t['synced'])(j['time'])"
info "boot clock: synced=$(jget "j['time']['synced']") approximate=$(jget "j['time'].get('approximate')") anchor_age_s=$(jget "j['time'].get('anchor_age_s')") epoch=$(jget "j['time']['epoch']")"
NOW=$(date +%s)
TZ_S=$(python3 -c 'import time; print(time.localtime().tm_gmtoff)')
req POST /time -H 'Content-Type: application/json' -d "{\"epoch\":$NOW,\"tz_offset_s\":$TZ_S}"
expect 200 "POST /time" "j['ok'] is True"
req GET /status
expect 200 "clock synced and within 5 s" "j['time']['synced'] is True and abs(j['time']['epoch']-$NOW)<=5 and j['time']['tz_offset_s']==$TZ_S"
expect 200 "POST /time clears approximate (approximate false, anchor_age_s null)" "j['time']['approximate'] is False and j['time']['anchor_age_s'] is None"
req POST /time -H 'Content-Type: application/json' -d '{"epoch":12}'
expect 422 "POST /time with a 1970 epoch -> 422" "j['ok'] is False"

echo "== assets"
for id in gradient anim12 rsvp-dot-w e2e-tmp e2e-strip e2e-strip-raw; do
    req DELETE "/assets/$id"   # clean slate: 200 or 404 both fine
done
for id in gradient anim12 rsvp-dot-w; do
    f="$FIX/$id.hca"; h=$(sha "$f"); sz=$(wc -c <"$f" | tr -d ' ')
    put_asset "$id" "$f" "$h"
    expect 201 "PUT /assets/$id ($sz B)" "j['ok'] is True and j['id']=='$id' and j['size']==$sz and j['sha256']=='$h'"
done
put_asset anim12 "$FIX/anim12.hca"
expect 409 "re-upload identical anim12 -> 409" "j['ok'] is False and j['sha256']=='$(sha "$FIX/anim12.hca")'"

# Corrupted copies (each with a *correct* X-Content-SHA256 for the corrupted bytes, so only the
# .hca validation can reject them), plus a hash mismatch.
python3 - "$FIX/anim12.hca" "$TMP" <<'PY'
import struct, sys
src, tmp = sys.argv[1], sys.argv[2]
d = bytearray(open(src, "rb").read())
bad = bytearray(d); bad[3:4] = b"X"                      # magic HCA1 -> HCAX
open(tmp + "/bad-hdr.hca", "wb").write(bad)
off, length = struct.unpack_from("<II", d, 32)           # frame 0
rle = bytearray(d)
if d[11] == 1:                                           # RLE16: first control word -> literal x32768
    struct.pack_into("<H", rle, off, 0x7FFF)
else:                                                    # raw: claim a wrong frame length
    struct.pack_into("<I", rle, 36, length - 2)
open(tmp + "/bad-rle.hca", "wb").write(rle)
open(tmp + "/bad-size.hca", "wb").write(d[:-100])         # data_size != body length
PY
put_asset e2e-bad "$TMP/bad-hdr.hca";  expect 422 "corrupted header (bad magic) -> 422" "j['error']=='malformed'"
put_asset e2e-bad "$TMP/bad-rle.hca";  expect 422 "corrupted frame data (RLE overrun) -> 422" "j['error']=='malformed'"
put_asset e2e-bad "$TMP/bad-size.hca"; expect 422 "truncated file (data_size mismatch) -> 422" "j['error']=='malformed'"
put_asset e2e-bad "$FIX/anim12.hca" 0000000000000000000000000000000000000000000000000000000000000000
expect 422 "wrong X-Content-SHA256 -> 422" "j['error']=='sha256_mismatch'"
req PUT /assets/e2e-bad -H 'Content-Type: application/octet-stream' --data-binary "@$FIX/anim12.hca"
expect 400 "missing X-Content-SHA256 -> 400" "j['ok'] is False"
req PUT /assets/Bad_Id -H "X-Content-SHA256: $(sha "$FIX/anim12.hca")" --data-binary "@$FIX/anim12.hca"
expect 400 "invalid asset id -> 400" "j['ok'] is False"

req GET /assets
expect 200 "GET /assets lists the 3 fixtures, no rejected uploads" \
    "set(a['id'] for a in j['assets'])>={'gradient','anim12','rsvp-dot-w'} and 'e2e-bad' not in [a['id'] for a in j['assets']]"
expect 200 "asset metadata (atlas flags, geometry, frames)" \
    "{a['id']:(a['atlas'],a['width'],a['height'],a['frames']) for a in j['assets']}['anim12']==(False,536,240,12) and {a['id']:a['atlas'] for a in j['assets']}['rsvp-dot-w'] is True"
req GET /assets/anim12
if [ "$CODE" = 200 ] && [ "$(sha "$TMP/body")" = "$(sha "$FIX/anim12.hca")" ]; then pass "GET /assets/anim12 round-trips byte-exact"; else fail "GET /assets/anim12: HTTP $CODE, hash differs"; fi
put_asset e2e-tmp "$FIX/gradient.hca"
expect 201 "PUT /assets/e2e-tmp (copy of gradient under a new id)"
req DELETE /assets/e2e-tmp
expect 200 "DELETE /assets/e2e-tmp" "j['ok'] is True"
req DELETE /assets/e2e-tmp
expect 404 "DELETE it again -> 404" "j['ok'] is False"

echo "== playlist"
PL='{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":8000,"transition":"fade"},{"type":"asset","id":"anim12","duration_ms":0,"loops":3,"transition":"cut"},{"type":"scene","scene":"sand","duration_ms":30000,"transition":"fade"}]}'
req PUT /playlist -H 'Content-Type: application/json' -d "$PL"
expect 200 "PUT /playlist (2 assets + a scene)" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips" "[i['type'] for i in j['items']]==['asset','asset','scene'] and j['items'][1]['loops']==3"
req PUT /playlist -H 'Content-Type: application/json' -d '{"version":1,"items":[{"type":"asset","id":"does-not-exist"}]}'
expect 422 "playlist with unknown asset -> 422" "j['error']=='unknown_asset'"
req PUT /playlist -H 'Content-Type: application/json' -d '{"version":1,"items":[{"type":"asset","id":"rsvp-dot-w"}]}'
expect 422 "playlist referencing a glyph atlas -> 422" "j['ok'] is False"
req PUT /playlist -H 'Content-Type: application/json' -d 'not json'
expect 400 "playlist that is not JSON -> 400" "j['ok'] is False"
req GET /status
expect 200 "status reflects the playlist" "j['playlist']['count']==3"

echo "== strips (PROTOCOL §2 is_strip, §4 scrolling strips)"
# Generated here (no fixture): a 1400x240 RLE strip (colour blocks on black, like rendered text), a
# 600x240 raw strip, and three that must be rejected (2 frames, only 536 px wide, corrupt RLE).
python3 - "$TMP" <<'PY'
import struct, sys
tmp = sys.argv[1]
def be(v): return struct.pack(">H", v)
def rle(px):
    out = bytearray(); i = 0; n = len(px)
    while i < n:
        j = i
        while j < n and j - i < 32768 and px[j] == px[i]: j += 1
        if j - i >= 3:
            out += struct.pack("<H", 0x8000 | (j - i - 1)) + be(px[i]); i = j; continue
        k = i
        while k < n and k - i < 32768 and not (k + 2 < n and px[k] == px[k+1] == px[k+2]): k += 1
        out += struct.pack("<H", k - i - 1) + b"".join(be(p) for p in px[i:k]); i = k
    return bytes(out)
def hca(w, h, frames, comp, flags):
    data = [rle(f) if comp else b"".join(be(p) for p in f) for f in frames]
    off = 32 + 12 * len(frames); table = b""; body = b""
    for d in data:
        table += struct.pack("<IIHH", off + len(body), len(d), 0, 0); body += d
    total = off + len(body)
    return b"HCA1" + struct.pack("<HHHBBHHII", w, h, len(frames), 0, comp, 0, flags, 32, total) + bytes(8) + table + body
COLS = [0xF800, 0xFFE0, 0x07E0, 0x07FF, 0x001F, 0xF81F, 0xFDE0]
def strip(w, h=240):
    px = []
    for y in range(h):
        for x in range(w):
            on = 60 <= y < 180 and (x // 24) % 4 != 3 and ((x // 6 + y // 6) % 5 != 0)
            px.append(COLS[(x // 96) % len(COLS)] if on else 0)
    return px
s1400 = strip(1400)
open(tmp + "/strip.hca", "wb").write(hca(1400, 240, [s1400], 1, 2))
open(tmp + "/strip-raw.hca", "wb").write(hca(600, 240, [strip(600)], 0, 2))
open(tmp + "/strip-2f.hca", "wb").write(hca(1400, 240, [s1400, s1400], 1, 2))
open(tmp + "/strip-536.hca", "wb").write(hca(536, 240, [strip(536)], 1, 2))
bad = bytearray(hca(1400, 240, [s1400], 1, 2)); struct.pack_into("<H", bad, 44, 0x7FFF)   # first run -> literal x32768
open(tmp + "/strip-badrle.hca", "wb").write(bad)
PY
put_asset e2e-strip "$TMP/strip.hca"
expect 201 "PUT /assets/e2e-strip (1400x240 RLE strip, $(wc -c <"$TMP/strip.hca" | tr -d ' ') B)" "j['ok'] is True and j['id']=='e2e-strip'"
put_asset e2e-strip-raw "$TMP/strip-raw.hca"
expect 201 "PUT /assets/e2e-strip-raw (600x240 raw strip)" "j['ok'] is True"
put_asset e2e-bad "$TMP/strip-2f.hca";     expect 422 "strip with 2 frames -> 422 malformed" "j['error']=='malformed'"
put_asset e2e-bad "$TMP/strip-536.hca";    expect 422 "strip only 536 px wide -> 422 malformed" "j['error']=='malformed'"
put_asset e2e-bad "$TMP/strip-badrle.hca"; expect 422 "strip with a corrupt RLE stream -> 422 malformed" "j['error']=='malformed'"
req GET /assets
expect 200 "GET /assets reports strip:true + width for strips, strip:false otherwise" \
    "(lambda A: A['e2e-strip']['strip'] is True and A['e2e-strip']['width']==1400 and A['e2e-strip']['height']==240 and A['e2e-strip']['frames']==1 and A['e2e-strip-raw']['width']==600 and A['gradient']['strip'] is False and 'e2e-bad' not in A)({a['id']:a for a in j['assets']})"
SCR1='{"version":1,"items":[{"type":"asset","id":"e2e-strip","scroll":{"px_per_s":80,"direction":"left","gap_px":120,"loops":2},"transition":"fade"},{"type":"asset","id":"gradient","duration_ms":5000}]}'
req PUT /playlist -H 'Content-Type: application/json' -d "$SCR1"
expect 200 "PUT /playlist with a scrolling strip item" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips scroll" "j['items'][0]['scroll']=={'px_per_s':80,'direction':'left','gap_px':120,'loops':2}"
sleep 1
req GET /status
expect 200 "strip item playing -> playlist.current == e2e-strip" "j['playlist']['current']=='e2e-strip'"
req GET /screenshot
SNB=$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(sum(1 for i in range(0,len(d),2) if d[i]|d[i+1]))' "$TMP/body" 2>/dev/null || echo 0)
if [ "$CODE" = 200 ] && [ "$SNB" -gt 1000 ]; then pass "strip screenshot has content ($SNB non-black pixels: the first 536 px, rendered offscreen)"; else fail "strip screenshot: HTTP $CODE, $SNB non-black pixels"; fi
req PUT /playlist -H 'Content-Type: application/json' -d '{"version":1,"items":[{"type":"asset","id":"e2e-strip-raw","duration_ms":4000}]}'
expect 200 "PUT /playlist with a strip without scroll (plays as a still)" "j['ok'] is True"
sleep 1
req GET /status
expect 200 "still strip -> playlist.current == e2e-strip-raw" "j['playlist']['current']=='e2e-strip-raw'"
req PUT /playlist -H 'Content-Type: application/json' -d '{"version":1,"items":[{"type":"asset","id":"e2e-strip","scroll":{"px_per_s":33.5,"direction":"right"},"duration_ms":20000},{"type":"asset","id":"e2e-strip-raw","scroll":{}}]}'
expect 200 "scroll right at 33.5 px/s for duration_ms, and an empty scroll object (defaults)" "j['ok'] is True"
for bad in '{"px_per_s":5}' '{"px_per_s":401}' '{"direction":"up"}' '{"gap_px":2001}' '{"gap_px":1.5}' '{"loops":0}' '"fast"'; do
    req PUT /playlist -H 'Content-Type: application/json' -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"e2e-strip\",\"scroll\":$bad}]}"
    expect 422 "scroll $bad -> 422 invalid_playlist" "j['error']=='invalid_playlist'"
done
QAT=$(( $(date +%s) + 7200 ))
req PUT /playlist -H 'Content-Type: application/json' -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000}],\"queue\":[{\"id\":\"e2e-qs\",\"at\":$QAT,\"type\":\"asset\",\"asset\":\"e2e-strip\",\"scroll\":{\"px_per_s\":120,\"loops\":1}}]}"
expect 200 "queue entry with a scrolling strip" "j['ok'] is True"
req POST /queue/test -H 'Content-Type: application/json' -d '{"id":"e2e-qs"}'
sleep 1
req GET /status
expect 200 "scrolling queue entry on screen -> current e2e-strip, queue.active e2e-qs" "j['playlist']['current']=='e2e-strip' and j['queue']['active']=='e2e-qs'"
req POST /next
# POST /show of a strip scrolls: with the request's "scroll", else the scroll of the playlist item / queue
# entry showing it, else the default (80 px/s left). In a screen-on session GET /screenshot is the live
# frame, so two shots 300 ms apart differ; in a panel-off session it is the static offscreen render.
req GET /status
LIVE_S=$(jbool "j['session'].get('display_on', True)") || LIVE_S=True
# moves: 0 if two screenshots 300 ms apart are identical, else 1
moves() {
    req GET /screenshot; cp "$TMP/body" "$TMP/mv0"; sleep 0.3; req GET /screenshot
    if [ "$CODE" = 200 ] && ! cmp -s "$TMP/mv0" "$TMP/body"; then echo 1; else echo 0; fi
}
expect_moving() { # expect_moving DESCRIPTION  (moving in a screen-on session, static in a panel-off one)
    local m; m=$(moves)
    if [ "$LIVE_S" = True ]; then
        if [ "$m" = 1 ]; then pass "$1: two screenshots 300 ms apart differ (scrolling)"; else fail "$1: two screenshots 300 ms apart are identical (not scrolling)"; fi
    else
        if [ "$m" = 0 ]; then pass "$1: static offscreen render (panel-off session)"; else fail "$1: the screenshot changed in a panel-off session"; fi
    fi
}
req POST /show/e2e-strip -H 'Content-Type: application/json' -d '{"duration_ms":8000,"scroll":{"px_per_s":120,"direction":"left","gap_px":40}}'
expect 200 "POST /show/e2e-strip with a scroll object" "j['ok'] is True"
sleep 1
req GET /status
expect 200 "shown strip -> playlist.current == e2e-strip" "j['playlist']['current']=='e2e-strip'"
expect_moving "POST /show/e2e-strip with scroll"
for bad in '{"px_per_s":5}' '{"direction":"up"}' '{"loops":0}' '"fast"'; do
    req POST /show/e2e-strip -H 'Content-Type: application/json' -d "{\"duration_ms\":3000,\"scroll\":$bad}"
    expect 422 "POST /show scroll $bad -> 422 invalid_scroll" "j['error']=='invalid_scroll'"
done
req POST /show/gradient -H 'Content-Type: application/json' -d '{"duration_ms":3000,"scroll":{"px_per_s":100}}'
expect 200 "POST /show/gradient with a scroll (validated, ignored on a non-strip)" "j['ok'] is True"
sleep 1
req GET /status
expect 200 "shown non-strip -> playlist.current == gradient" "j['playlist']['current']=='gradient'"
req POST /next
req POST /show/e2e-strip -H 'Content-Type: application/json' -d '{"duration_ms":8000}'
expect 200 "POST /show/e2e-strip without scroll (queue entry e2e-qs has one)" "j['ok'] is True"
sleep 1
req GET /status
expect 200 "shown strip (borrowed scroll) -> playlist.current == e2e-strip" "j['playlist']['current']=='e2e-strip'"
expect_moving "POST /show/e2e-strip, scroll borrowed from its queue entry"
req POST /next
req PUT /playlist -H 'Content-Type: application/json' -d '{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":8000}]}'
expect 200 "playlist without any reference to e2e-strip" "j['ok'] is True"
req POST /show/e2e-strip -H 'Content-Type: application/json' -d '{"duration_ms":8000}'
expect 200 "POST /show/e2e-strip without scroll and no referencing item (default scroll)" "j['ok'] is True"
sleep 1
req GET /status
expect 200 "shown strip (default scroll) -> playlist.current == e2e-strip" "j['playlist']['current']=='e2e-strip'"
expect_moving "POST /show/e2e-strip, default scroll (80 px/s left)"
req POST /next
sleep 1
req GET /status
expect 200 "/next ends the show -> back to gradient" "j['playlist']['current']=='gradient'"

echo "== lone item (a one-item rotation plays indefinitely)"
# A lone still is held: no 5 s re-trigger, its duration_ms ignored -> two screenshots 6 s apart identical.
req PUT /playlist -H 'Content-Type: application/json' -d '{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":2000,"transition":"fade"}]}'
expect 200 "PUT /playlist with a lone still (duration_ms 2000, to be ignored)" "j['ok'] is True"
sleep 1
req GET /screenshot; cp "$TMP/body" "$TMP/lone0"
sleep 6
req GET /screenshot
if [ "$CODE" = 200 ] && cmp -s "$TMP/lone0" "$TMP/body"; then pass "lone still: two screenshots 6 s apart are identical (held, no re-fade/restart)"
else fail "lone still: the screenshot changed within 6 s (HTTP $CODE)"; fi
req GET /status
expect 200 "lone still still current after 7 s (duration_ms ignored)" "j['playlist']['current']=='gradient' and j['playlist']['count']==1"
# A lone strip scrolls endlessly whatever its loops / duration_ms: 600 px at 400 px/s, loops 1 = 2.8 s of travel.
req PUT /playlist -H 'Content-Type: application/json' -d '{"version":1,"items":[{"type":"asset","id":"e2e-strip-raw","scroll":{"px_per_s":400,"loops":1},"duration_ms":1000}]}'
expect 200 "PUT /playlist with a lone strip (loops 1 = 2.8 s, duration_ms 1000)" "j['ok'] is True"
sleep 4
req GET /status
expect 200 "lone strip still current after 4 s (past its loops and duration_ms)" "j['playlist']['current']=='e2e-strip-raw'"
expect_moving "lone strip past its loops"
req PUT /playlist -H 'Content-Type: application/json' -d "$PL"
expect 200 "playlist back to gradient + anim12 + sand" "j['ok'] is True"

echo "== config"
req GET /config
expect 200 "GET /config" "all(k in j for k in ('name','brightness','upload_timeout_s','low_battery_pct','default_transition','tz_offset_s'))"
# The hotspot passphrase is write-only (PROTOCOL §4): no answer of /config carries it.
expect 200 "GET /config never contains ap_password" "'ap_password' not in j"
# The values to restore later, each read with its type (the fallbacks only keep the script going after a FAIL).
ORIG_B=$(jint "j['brightness']") || { fail "GET /config: brightness is not an integer"; ORIG_B=160; }
ORIG_T=$(jenum "j['default_transition']" cut fade) || { fail "GET /config: default_transition is neither cut nor fade"; ORIG_T=fade; }
ORIG_TO=$(jint "j['upload_timeout_s']") || { fail "GET /config: upload_timeout_s is not an integer"; ORIG_TO=120; }
ORIG_LB=$(jint "j['low_battery_pct']") || { fail "GET /config: low_battery_pct is not an integer"; ORIG_LB=8; }
if [ "$ORIG_B" = 77 ]; then NEW_B=78; else NEW_B=77; fi
if [ "$ORIG_T" = cut ]; then NEW_T=fade; else NEW_T=cut; fi
req PUT /config -H 'Content-Type: application/json' -d "{\"brightness\":$NEW_B,\"default_transition\":\"$NEW_T\",\"upload_timeout_s\":300}"
expect 200 "PUT /config (partial merge) returns the config, without ap_password" \
    "j['brightness']==int(a[0]) and j['default_transition']==a[1] and j['upload_timeout_s']==300 and 'ap_password' not in j" "$NEW_B" "$NEW_T"
req GET /config
expect 200 "GET /config shows the change" "j['brightness']==int(a[0]) and j['default_transition']==a[1]" "$NEW_B" "$NEW_T"
req GET /status
expect 200 "session timeout follows upload_timeout_s" "j['session']['timeout_s']==300"
req PUT /config -H 'Content-Type: application/json' -d '{"upload_timeout_s":5}'
expect 422 "invalid config value -> 422" "j['error']=='invalid_config'"
req PUT /config -H 'Content-Type: application/json' -d "{\"brightness\":$ORIG_B,\"default_transition\":\"$ORIG_T\",\"upload_timeout_s\":$ORIG_TO}"
expect 200 "config restored" "j['brightness']==int(a[0]) and j['default_transition']==a[1] and j['upload_timeout_s']==int(a[2])" "$ORIG_B" "$ORIG_T" "$ORIG_TO"
# ap_password is still settable over WiFi (here: to the value the clip already has, so nothing changes) and is
# validated, but it is never echoed. The body is built by json.dumps: the passphrase is the tester's own input.
python3 -c 'import json,sys; print(json.dumps({"ap_password": sys.argv[1]}))' "$PASSPHRASE" >"$TMP/pw.json"
req PUT /config -H 'Content-Type: application/json' --data-binary "@$TMP/pw.json"
expect 200 "PUT /config ap_password (unchanged value) is accepted over WiFi and not echoed" \
    "j['ok'] is True and 'ap_password' not in j and a[0] not in json.dumps(j)" "$PASSPHRASE"
req PUT /config -H 'Content-Type: application/json' -d '{"ap_password":"short"}'
expect 422 "ap_password shorter than 8 characters -> 422 invalid_config" "j['error']=='invalid_config'"
# ap_password_set (read-only): false while the passphrase is the factory default. The passphrase this script joined
# with is the clip's, so the flag must agree with it.
FACTORY_PASS=pixelclip-2026
if [ "$PASSPHRASE" = "$FACTORY_PASS" ]; then WANT_SET=False; else WANT_SET=True; fi
req GET /config
expect 200 "GET /config: ap_password_set is $WANT_SET (joined with the $([ $WANT_SET = False ] && echo factory || echo own) passphrase), no passphrase" \
    "j.get('ap_password_set') is (a[0]=='True') and a[1] not in json.dumps(j)" "$WANT_SET" "$PASSPHRASE"
case "$CLIP" in *127.0.0.1*|*localhost*) CFGMOCK=1 ;; *) CFGMOCK=0 ;; esac
if [ "$CFGMOCK" = 1 ]; then
    # Mock only: a real clip would take the new passphrase at its next session, and a run that stopped half way
    # would leave it locked to this script's test value. Here: factory -> own -> factory, and the flag follows.
    E2E_PASS="e2e-own-pass-$$"
    python3 -c 'import json,sys; print(json.dumps({"ap_password": sys.argv[1]}))' "$FACTORY_PASS" >"$TMP/pw0.json"
    python3 -c 'import json,sys; print(json.dumps({"ap_password": sys.argv[1]}))' "$E2E_PASS" >"$TMP/pw1.json"
    req PUT /config -H 'Content-Type: application/json' --data-binary "@$TMP/pw0.json"
    expect 200 "PUT /config ap_password = factory default -> ap_password_set false" \
        "j.get('ap_password_set') is False and 'ap_password' not in j and a[0] not in json.dumps(j)" "$FACTORY_PASS"
    req PUT /config -H 'Content-Type: application/json' --data-binary "@$TMP/pw1.json"
    expect 200 "PUT /config ap_password = an own one -> ap_password_set true, passphrase not in the answer" \
        "j.get('ap_password_set') is True and 'ap_password' not in j and a[0] not in json.dumps(j)" "$E2E_PASS"
    req GET /config
    expect 200 "GET /config: ap_password_set true, passphrase not in the answer" \
        "j.get('ap_password_set') is True and 'ap_password' not in j and a[0] not in json.dumps(j)" "$E2E_PASS"
    req PUT /config -H 'Content-Type: application/json' -d '{"ap_password_set":false}'
    expect 200 "PUT /config {\"ap_password_set\":false} is ignored (read-only)" "j.get('ap_password_set') is True"
    req GET /config
    expect 200 "ap_password_set still true after the ignored patch" "j.get('ap_password_set') is True"
    python3 -c 'import json,sys; print(json.dumps({"ap_password": sys.argv[1]}))' "$PASSPHRASE" >"$TMP/pw.json"
    req PUT /config -H 'Content-Type: application/json' --data-binary "@$TMP/pw.json"
    expect 200 "ap_password restored, ap_password_set back to $WANT_SET" "j.get('ap_password_set') is (a[0]=='True')" "$WANT_SET"
else
    info "real clip: ap_password_set false -> true -> false is checked against the mock only (no passphrase change here)"
fi
# low_battery_pct is 0-20 (was 0-50: at 50 a single request switched the clip off below half charge).
for v in 21 50 -1; do
    req PUT /config -H 'Content-Type: application/json' -d "{\"low_battery_pct\":$v}"
    expect 422 "low_battery_pct $v -> 422 invalid_config" "j['error']=='invalid_config'"
done
req PUT /config -H 'Content-Type: application/json' -d '{"low_battery_pct":20}'
expect 200 "low_battery_pct 20 (the maximum) is accepted" "j['low_battery_pct']==20"
req PUT /config -H 'Content-Type: application/json' -d "{\"low_battery_pct\":$ORIG_LB}"
expect 200 "low_battery_pct restored" "j['low_battery_pct']==int(a[0])" "$ORIG_LB"

echo "== request checks (PROTOCOL §4: Host, Origin, Content-Type; nesting depth)"
# A web page in the phone's browser must not be able to drive the clip while the phone is on its hotspot.
req GET /status -H 'Origin: http://evil.example'
expect 403 "a request with an Origin header -> 403 cross_origin" "j['ok'] is False and j['error']=='cross_origin'"
req POST /next -H 'Origin: null'
expect 403 "POST /next with Origin: null -> 403 cross_origin (nothing ran)" "j['error']=='cross_origin'"
req GET /status -H 'Sec-Fetch-Site: cross-site'
expect 403 "Sec-Fetch-Site: cross-site -> 403 cross_origin" "j['error']=='cross_origin'"
req GET /status -H 'Sec-Fetch-Site: none'
expect 200 "Sec-Fetch-Site: none (typed into the address bar) is served" "j['ok'] is True"
req GET /status -H 'Host: evil.example'
expect 403 "a Host that is not the clip (DNS rebinding) -> 403 bad_host" "j['ok'] is False and j['error']=='bad_host'"
req GET /status -H 'Host: 192.168.4.1.evil.example'
expect 403 "a Host that only starts with the clip's address -> 403 bad_host" "j['error']=='bad_host'"
req GET /status -H 'Host: pixelclip.local'
expect 200 "Host: pixelclip.local is served" "j['ok'] is True"
req GET /status -H 'Host: PixelClip.local:80'
expect 200 "Host: PixelClip.local:80 (any case, port 80) is served" "j['ok'] is True"
req GET /status -H 'Host:'
expect 200 "a request without a Host header (HTTP/1.0 tools) is served" "j['ok'] is True"
req POST /brightness -H 'Content-Type: text/plain' -d '{"value":121}'
expect 415 "a JSON body sent as text/plain -> 415 unsupported_media_type" "j['ok'] is False and j['error']=='unsupported_media_type'"
req POST /brightness -d '{"value":121}'
expect 415 "a JSON body without a JSON Content-Type (curl -d: form-urlencoded) -> 415" "j['error']=='unsupported_media_type'"
req PUT /playlist -H 'Content-Type: text/plain' -d "$PL"
expect 415 "PUT /playlist as text/plain -> 415" "j['error']=='unsupported_media_type'"
req POST /brightness -H 'Content-Type: application/json; charset=utf-8' -d '{"value":120}'
expect 200 "application/json with a charset parameter is accepted" "j['ok'] is True"
# JSON nested deeper than 16 levels is not JSON (the parser used to recurse 1000 levels deep on 8-10 KB stacks:
# a crash, and with a stored playlist a crash at every boot).
python3 - "$TMP" <<'PY'
import sys
tmp = sys.argv[1]
open(tmp + "/deep-open.json", "w").write("[" * 200)                                   # never closed: the parser recursed before failing
open(tmp + "/deep-1000.json", "w").write("[" * 1000 + "]" * 1000)
for d in (16, 100):                                                                   # the root object is level 1
    open(tmp + "/deep-pl-%d.json" % d, "w").write('{"version":1,"items":[],"x":' + "[" * d + "]" * d + "}")
PY
req POST /time -H 'Content-Type: application/json' --data-binary "@$TMP/deep-open.json"
expect 400 "POST /time with 200 unclosed '[' -> 400 bad_json (no crash)" "j['error']=='bad_json'"
req POST /brightness -H 'Content-Type: application/json' --data-binary "@$TMP/deep-1000.json"
expect 400 "POST /brightness with JSON nested 1000 deep -> 400 bad_json" "j['error']=='bad_json'"
for d in 16 100; do
    req PUT /playlist -H 'Content-Type: application/json' --data-binary "@$TMP/deep-pl-$d.json"
    expect 400 "PUT /playlist with an ignored key nested $d arrays deep (level $((d + 1))) -> 400 bad_json, not stored" "j['error']=='bad_json'"
done
req GET /playlist
expect 200 "the stored playlist is untouched by the rejected documents" "len(j['items'])==3 and 'x' not in j"
req GET /status
expect 200 "the clip still answers after the deep documents" "j['ok'] is True and j['playlist']['count']==3"

echo "== live controls"
req POST /brightness -H 'Content-Type: application/json' -d '{"value":120}'
expect 200 "POST /brightness 120" "j['ok'] is True"
req POST /brightness -H 'Content-Type: application/json' -d '{"value":300}'
expect 422 "POST /brightness 300 -> 422" "j['ok'] is False"
req POST /next;  expect 200 "POST /next" "j['ok'] is True"
req POST /prev;  expect 200 "POST /prev" "j['ok'] is True"
req POST /show/anim12 -H 'Content-Type: application/json' -d '{"duration_ms":15000}'
expect 200 "POST /show/anim12 (15 s)" "j['ok'] is True"
req POST /show/gradient
expect 200 "POST /show/gradient" "j['ok'] is True"
req POST /show/does-not-exist
expect 404 "POST /show/unknown -> 404" "j['ok'] is False"
sleep 1

echo "== screenshot"
req GET /screenshot
SZ=$(wc -c <"$TMP/body" | tr -d ' ')
if [ "$CODE" = 200 ] && [ "$SZ" = 257280 ]; then
    pass "GET /screenshot is 257280 bytes"
    cp "$TMP/body" "$FW/e2e_screenshot.raw"
    if python3 "$FW/scripts/rgb565_to_png.py" "$FW/e2e_screenshot.raw" "$FW/e2e_screenshot.png" --scale 2; then
        info "saved firmware/e2e_screenshot.png (expected: the gradient, live or rendered offscreen)"
    fi
    NONBLACK=$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(sum(1 for i in range(0,len(d),2) if d[i]|d[i+1]))' "$TMP/body")
    if [ "$NONBLACK" -gt 1000 ]; then pass "screenshot has content ($NONBLACK non-black pixels)"; else fail "screenshot is (almost) black ($NONBLACK non-black pixels)"; fi
else
    fail "GET /screenshot: HTTP $CODE, $SZ bytes (want 257280)"
fi

echo "== batlog"
req GET /batlog
if [ "$CODE" = 200 ] && head -n1 "$TMP/body" | grep -q ','; then
    pass "GET /batlog: $(wc -l <"$TMP/body" | tr -d ' ') CSV lines (header: $(head -n1 "$TMP/body" | clean 120))"
elif [ "$CODE" = 404 ]; then
    pass "GET /batlog -> 404 (optional endpoint not implemented)"
else
    fail "GET /batlog: HTTP $CODE"
fi
if [ -n "${E2E_CLEAR_BATLOG:-}" ]; then
    req DELETE /batlog; expect 200 "DELETE /batlog" "j['ok'] is True"
fi

JH='Content-Type: application/json'
# Any "show now" from the live-controls section would survive a playlist reload: drop it first.
req POST /next

echo "== session modes (screen-on sessions, always-on) + BLE doorbell"
# The three pass-4 config keys, the session flags in /status, the live framebuffer of a screen-on
# session, wifi_always_on (/session/end is then ignored) and GET /ble. Everything is restored.
BLE_UUID=$(sed -n 's/^#define PIXELCLIP_BLE_SERVICE_UUID  *"\([0-9A-F-]*\)".*/\1/p' "$FW/components/ble/include/pixelclip_ble_uuids.h")
pyb() { [ "$1" = True ] && echo true || echo false; }      # Python bool -> JSON literal
neg() { [ "$1" = True ] && echo false || echo true; }      # Python bool -> negated JSON literal
req GET /config
expect 200 "GET /config has display_during_upload / wifi_always_on / ble_wake (booleans)" \
    "all(isinstance(j.get(k), bool) for k in ('display_during_upload','wifi_always_on','ble_wake'))"
O_DISP=$(jbool "j['display_during_upload']") || { fail "GET /config: display_during_upload is not a boolean"; O_DISP=True; }
O_AON=$(jbool "j['wifi_always_on']") || { fail "GET /config: wifi_always_on is not a boolean"; O_AON=False; }
O_BLE=$(jbool "j['ble_wake']") || { fail "GET /config: ble_wake is not a boolean"; O_BLE=True; }
info "display_during_upload=$O_DISP wifi_always_on=$O_AON ble_wake=$O_BLE"
req GET /status
expect 200 "status.session has always_on / display_on (bools) and clients >= 1" \
    "isinstance(j['session'].get('always_on'), bool) and isinstance(j['session'].get('display_on'), bool) and j['session'].get('clients', 0) >= 1"
LIVE=$(jbool "j['session']['display_on']") || { fail "status.session.display_on is not a boolean"; LIVE=True; }
# In the checks below a[i]=='True' turns the saved True / False text back into a boolean.
expect 200 "session.display_on == display_during_upload (or always-on), session.always_on == wifi_always_on" \
    "j['session']['display_on'] == (a[0]=='True' or a[1]=='True') and j['session']['always_on'] == (a[1]=='True')" "$O_DISP" "$O_AON"

req PUT /config -H "$JH" -d "{\"display_during_upload\":$(neg "$O_DISP"),\"ble_wake\":$(neg "$O_BLE")}"
expect 200 "PUT /config flips display_during_upload and ble_wake" \
    "j['display_during_upload'] is (a[0]!='True') and j['ble_wake'] is (a[1]!='True') and j['wifi_always_on'] is (a[2]=='True')" "$O_DISP" "$O_BLE" "$O_AON"
req GET /config
expect 200 "GET /config shows both flipped (persisted)" "j['display_during_upload'] is (a[0]!='True') and j['ble_wake'] is (a[1]!='True')" "$O_DISP" "$O_BLE"
req GET /ble
expect 200 "GET /ble follows ble_wake (enabled $(neg "$O_BLE"))" "j['ok'] is True and j['enabled'] is (a[0]!='True')" "$O_BLE"
req GET /status
expect 200 "display_during_upload does not change the running session (display_on still $LIVE)" "j['session']['display_on'] is (a[0]=='True')" "$LIVE"
for bad in '"display_during_upload":"yes"' '"wifi_always_on":1' '"ble_wake":null'; do
    req PUT /config -H "$JH" -d "{$bad}"
    expect 422 "PUT /config {$bad} -> 422 invalid_config" "j['error']=='invalid_config'"
done
req PUT /config -H "$JH" -d "{\"display_during_upload\":$(pyb "$O_DISP"),\"ble_wake\":$(pyb "$O_BLE")}"
expect 200 "display_during_upload / ble_wake restored" "j['display_during_upload'] is (a[0]=='True') and j['ble_wake'] is (a[1]=='True')" "$O_DISP" "$O_BLE"

req GET /ble
expect 200 "GET /ble: enabled == ble_wake, name PixelClip-XXXX, service UUID from pixelclip_ble_uuids.h, connected bool" \
    "j['ok'] is True and j['enabled'] is (a[0]=='True') and j['name'].startswith('PixelClip-') and len(j['name'])==len('PixelClip-')+4 and j['service_uuid'].upper()==a[1] and isinstance(j['connected'], bool)" "$O_BLE" "$BLE_UUID"
if [ "$SSID" != "(skipped)" ]; then
    expect 200 "BLE name == SSID ($SSID)" "j['name']==a[0]" "$SSID"
fi

req PUT /config -H "$JH" -d '{"wifi_always_on":true}'
expect 200 "PUT /config wifi_always_on true" "j['wifi_always_on'] is True"
req GET /status
expect 200 "status.session.always_on true" "j['session']['always_on'] is True"
req POST /session/end
expect 200 "POST /session/end while always-on -> ok + always_on (hotspot stays up)" "j['ok'] is True and j.get('always_on') is True"
sleep 2
req GET /status
expect 200 "session still answers 2 s after /session/end (always-on)" "j['session']['always_on'] is True"
req PUT /config -H "$JH" -d "{\"wifi_always_on\":$(pyb "$O_AON")}"
expect 200 "wifi_always_on restored ($O_AON)" "j['wifi_always_on'] is (a[0]=='True')" "$O_AON"
req GET /status
expect 200 "status.session.always_on back to $O_AON" "j['session']['always_on'] is (a[0]=='True')" "$O_AON"

# Live framebuffer: anim12 alone loops forever. In a screen-on session GET /screenshot is the frame on
# the panel, so it changes between two screenshots; in a panel-off session it is the static offscreen
# render of the first frame.
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"anim12","duration_ms":0,"transition":"cut"}]}'
expect 200 "playlist = anim12 alone (loops)" "j['ok'] is True"
sleep 1
req GET /screenshot
cp "$TMP/body" "$TMP/shot0"
CHANGED=0
for _ in 1 2 3 4 5 6; do
    sleep 0.3
    req GET /screenshot
    if [ "$CODE" = 200 ] && ! cmp -s "$TMP/shot0" "$TMP/body"; then CHANGED=1; break; fi
done
if [ "$LIVE" = True ]; then
    if [ "$CHANGED" = 1 ]; then pass "screen-on session: GET /screenshot is the live frame (anim12 advanced between two shots)"
    else fail "screen-on session: 7 screenshots of anim12 over ~2 s are identical (not the live frame?)"; fi
else
    if [ "$CHANGED" = 0 ]; then pass "panel-off session: GET /screenshot is the static offscreen render"
    else fail "panel-off session: the screenshot changed although the panel is off"; fi
fi
req PUT /playlist -H "$JH" -d "$PL"
expect 200 "playlist back to gradient + anim12 + sand" "j['ok'] is True"
req POST /next

echo "== scheduler: status"
req GET /status
expect 200 "status has queue {pending,next_at,done} and clock_ok" \
    "isinstance(j['queue']['pending'],int) and 'next_at' in j['queue'] and isinstance(j['queue']['done'],int) and isinstance(j['clock_ok'],bool)"

echo "== scheduler: time windows (clip clock moved, restored afterwards)"
DAY=$(( (NOW / 86400) * 86400 ))
T_IN=$(( DAY + 23 * 3600 ))            # 23:00 local (tz 0): inside 21:30-01:00
T_IN2=$(( DAY + 86400 + 1800 ))        # 00:30 the next day: inside too (window crosses midnight)
T_OUT=$(( DAY + 12 * 3600 ))           # 12:00: outside
WPL1='{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":8000,"transition":"cut","from":"21:30","until":"01:00"}]}'
req POST /time -H "$JH" -d "{\"epoch\":$T_IN,\"tz_offset_s\":0}"
expect 200 "POST /time 23:00 local (tz 0)" "j['ok'] is True"
req PUT /playlist -H "$JH" -d "$WPL1"
expect 200 "PUT /playlist with a 21:30-01:00 item" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips from/until" "j['items'][0]['from']=='21:30' and j['items'][0]['until']=='01:00' and j['ok'] is True"
sleep 1
req GET /status
expect 200 "23:00 is inside the window -> playlist.current == gradient" "j['playlist']['current']=='gradient' and j['clock_ok'] is True"
req POST /time -H "$JH" -d "{\"epoch\":$T_OUT,\"tz_offset_s\":0}"
sleep 1
req GET /status
expect 200 "12:00 is outside and every item is windowed out -> idle (current null)" "j['playlist']['current'] is None"
req POST /time -H "$JH" -d "{\"epoch\":$T_IN2,\"tz_offset_s\":0}"
sleep 1
req GET /status
expect 200 "00:30 is inside (window crosses midnight) -> gradient again" "j['playlist']['current']=='gradient'"
req POST /time -H "$JH" -d "{\"epoch\":$T_OUT,\"tz_offset_s\":0}"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":8000,"from":"21:30","until":"01:00"},{"type":"asset","id":"anim12","duration_ms":0,"loops":2}]}'
expect 200 "PUT /playlist (windowed gradient + always-on anim12)" "j['ok'] is True"
sleep 1
req GET /status
expect 200 "rotation skips the windowed-out item -> anim12" "j['playlist']['current']=='anim12'"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","from":"9:30"}]}'
expect 422 "from \"9:30\" (not HH:MM) -> 422" "j['error']=='invalid_playlist'"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","from":"10:00","until":"10:00"}]}'
expect 422 "empty window (from == until) -> 422" "j['error']=='invalid_playlist'"
NOW=$(date +%s)
req POST /time -H "$JH" -d "{\"epoch\":$NOW,\"tz_offset_s\":$TZ_S}"
req GET /status
expect 200 "real clock and tz restored" "j['time']['synced'] is True and abs(j['time']['epoch']-$NOW)<=5 and j['time']['tz_offset_s']==$TZ_S"

echo "== scheduler: queue"
AT=$(( NOW + 3600 ))
QPL="{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000}],\"queue\":[{\"id\":\"e2e-q2\",\"at\":$((AT + 600)),\"type\":\"asset\",\"asset\":\"gradient\"},{\"id\":\"e2e-q1\",\"at\":$AT,\"type\":\"asset\",\"asset\":\"anim12\",\"duration_ms\":20000,\"transition\":\"fade\"}]}"
req PUT /playlist -H "$JH" -d "$QPL"
expect 200 "PUT /playlist with a 2-entry queue (in 1 h and 1 h 10)" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips queue[] as sent" "[q['id'] for q in j['queue']]==['e2e-q2','e2e-q1'] and j['queue'][1]['asset']=='anim12'"
req GET /status
expect 200 "status.queue: 2 pending, next_at = earliest, 0 done, clock_ok" \
    "j['queue']['pending']==2 and j['queue']['next_at']==$AT and j['queue']['done']==0 and j['clock_ok'] is True"
req POST /queue/test -H "$JH" -d '{"id":"e2e-q1"}'
expect 200 "POST /queue/test e2e-q1" "j['ok'] is True"
sleep 1
req GET /status
expect 200 "queue entry on screen: current anim12, queue.active e2e-q1, still pending (tests do not consume)" \
    "j['playlist']['current']=='anim12' and j['queue']['active']=='e2e-q1' and j['queue']['pending']==2"
req POST /queue/test -H "$JH" -d '{"id":"no-such-entry"}'
expect 404 "POST /queue/test with an unknown id -> 404" "j['error']=='unknown_entry'"
req POST /next
sleep 1
req GET /status
expect 200 "/next ends the queue entry -> back to the rotation" "j['queue']['active'] is None and j['playlist']['current']=='gradient'"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[],\"queue\":[{\"id\":\"d\",\"at\":$AT,\"type\":\"asset\",\"asset\":\"gradient\"},{\"id\":\"d\",\"at\":$AT,\"type\":\"asset\",\"asset\":\"gradient\"}]}"
expect 422 "duplicate queue ids -> 422" "j['error']=='invalid_playlist'"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[],\"queue\":[{\"id\":\"u\",\"at\":$AT,\"type\":\"asset\",\"asset\":\"does-not-exist\"}]}"
expect 422 "queue entry with an unknown asset -> 422" "j['error']=='unknown_asset'"

echo "== scheduler: normative details (PROTOCOL §4 Scheduling)"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","from":"22:00","until":"24:00"}]}'
expect 200 "until \"24:00\" is accepted" "j['ok'] is True"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","from":"24:00"}]}'
expect 422 "from \"24:00\" -> 422 (24:00 only as until)" "j['error']=='invalid_playlist'"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","until":"00:00"}]}'
expect 422 "until \"00:00\" alone (from defaults to 00:00 = empty window) -> 422" "j['error']=='invalid_playlist'"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","from":"06:00"}]}'
expect 200 "from alone (until defaults to 24:00) is accepted" "j['ok'] is True"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[],\"queue\":[{\"id\":\"c\",\"at\":$AT,\"type\":\"clock\"}]}"
expect 422 "clock type in the queue -> 422" "j['error']=='invalid_playlist'"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[],\"queue\":[{\"id\":\"$(printf 'x%.0s' $(seq 1 41))\",\"at\":$AT,\"type\":\"asset\",\"asset\":\"gradient\"}]}"
expect 422 "41-character queue id -> 422" "j['error']=='invalid_playlist'"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[],\"queue\":[{\"id\":\"tonight #1 (cake)\",\"at\":$AT,\"type\":\"asset\",\"asset\":\"gradient\"}]}"
expect 200 "queue id with spaces/punctuation (printable) is accepted" "j['ok'] is True"
python3 -c 'import json,sys; at=int(sys.argv[1]); print(json.dumps({"version":1,"items":[],"queue":[{"id":"q%d"%i,"at":at+i,"type":"asset","asset":"gradient"} for i in range(int(sys.argv[2]))]}))' "$AT" 65 >"$TMP/q65.json"
req PUT /playlist -H "$JH" --data-binary "@$TMP/q65.json"
expect 422 "65 queue entries -> 422 (limit 64)" "j['error']=='invalid_playlist'"
python3 -c 'import json,sys; at=int(sys.argv[1]); print(json.dumps({"version":1,"items":[],"queue":[{"id":"q%d"%i,"at":at+i,"type":"asset","asset":"gradient"} for i in range(int(sys.argv[2]))]}))' "$AT" 64 >"$TMP/q64.json"
req PUT /playlist -H "$JH" --data-binary "@$TMP/q64.json"
expect 200 "64 queue entries are accepted" "j['ok'] is True"
req GET /status
expect 200 "status.queue counts 64 pending" "j['queue']['pending']==64 and j['queue']['active'] is None"

echo "== scenes"
req GET /scenes
expect 200 "GET /scenes lists the registry" \
    "j['ok'] is True and {'sand','balls'}<={s['id'] for s in j['scenes']} and all(isinstance(s['params'],dict) for s in j['scenes']) and 'amber' in {s['id']:s for s in j['scenes']}['sand']['params']['palette']"
expect 200 "GET /scenes carries name and defaults (one per param) for every scene" \
    "all(isinstance(s.get('name'),str) and s['name'] and isinstance(s.get('defaults'),dict) and set(s['defaults'])==set(s['params']) for s in j['scenes'])"
SPL="{\"version\":1,\"items\":[{\"type\":\"scene\",\"scene\":\"sand\",\"params\":{\"palette\":\"amber\",\"density\":60},\"duration_ms\":60000,\"transition\":\"fade\"}],\"queue\":[{\"id\":\"e2e-q3\",\"at\":$AT,\"type\":\"scene\",\"scene\":\"balls\",\"params\":{\"palette\":\"candy\"},\"duration_ms\":60000}]}"
req PUT /playlist -H "$JH" -d "$SPL"
expect 200 "PUT /playlist with a sand scene item and a balls queue entry" "j['ok'] is True"
sleep 1
req GET /status
expect 200 "scene item playing -> playlist.current == scene:sand" "j['playlist']['current']=='scene:sand'"
req GET /screenshot
SCN=$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(sum(1 for i in range(0,len(d),2) if d[i]|d[i+1]))' "$TMP/body" 2>/dev/null || echo 0)
info "scene screenshot: HTTP $CODE, $SCN non-black pixels (offscreen warm-up of ~1.3 s)"
req POST /queue/test -H "$JH" -d '{"id":"e2e-q3"}'
sleep 1
req GET /status
expect 200 "scene queue entry -> current scene:balls" "j['playlist']['current']=='scene:balls' and j['queue']['active']=='e2e-q3'"
req POST /next
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"scene","scene":"no-such-scene"}]}'
expect 422 "unknown scene id -> 422 unknown_scene" "j['error']=='unknown_scene'"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"scene","scene":"sand","params":{"palette":"no-such-palette"}}]}'
expect 422 "scene param not in its enum -> 422 invalid_params" "j['error']=='invalid_params'"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"scene","scene":"sand","params":{"density":1000}}]}'
expect 422 "scene param out of range -> 422 invalid_params" "j['error']=='invalid_params'"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"scene","scene":"fire","seed":12345,"params":{"smooth":true},"duration_ms":0}]}'
expect 200 "scene item with a seed and a boolean param" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips the seed" "j['items'][0]['seed']==12345"
sleep 1
req GET /status
expect 200 "seeded scene playing -> current scene:fire" "j['playlist']['current']=='scene:fire'"
for bad in '-1' '1.5' '"abc"' '4294967296'; do
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"scene\",\"scene\":\"sand\",\"seed\":$bad}]}"
    expect 422 "scene seed $bad -> 422 invalid_playlist" "j['error']=='invalid_playlist'"
done
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"scene","scene":"sand","params":{"palette":true}}]}'
expect 422 "boolean for an enum param -> 422 invalid_params" "j['error']=='invalid_params'"

echo "== words (PROTOCOL §5b.1: a words scene, its sheet, /show, queue, 422s, delete)"
# Generated here (Python RLE16): sheets are glyph atlases (storage keeps non-536x240 files only as atlases), black is
# transparent. e2e-words: 3 frames of 200x60 (word-like blocks); e2e-words-13: 13 frames 40x20 (one too many);
# e2e-words-big: 12 frames 536x81 (12 x 536 x 81 = 520 992 px > 514 560).
python3 - "$TMP" <<'PY'
import struct, sys
tmp = sys.argv[1]
def rle(px):
    out = bytearray(); i = 0; n = len(px)
    while i < n:
        j = i
        while j < n and j - i < 32768 and px[j] == px[i]: j += 1
        if j - i >= 3: out += struct.pack("<H", 0x8000 | (j - i - 1)) + struct.pack(">H", px[i]); i = j; continue
        k = i
        while k < n and k - i < 32768 and not (k + 2 < n and px[k] == px[k+1] == px[k+2]): k += 1
        out += struct.pack("<H", k - i - 1) + b"".join(struct.pack(">H", p) for p in px[i:k]); i = k
    return bytes(out)
def atlas(path, w, h, frames):
    data = [rle(f) for f in frames]
    off = 32 + 12 * len(frames); table = b""; body = b""
    for d in data: table += struct.pack("<IIHH", off + len(body), len(d), 0, 0); body += d
    open(path, "wb").write(b"HCA1" + struct.pack("<HHHBBHHII", w, h, len(frames), 0, 1, 0, 1, 32, off + len(body)) + bytes(8) + table + body)
COL = (0xFFFF, 0xFD20, 0x07FF)
def word(w, h, i, letters):
    px = [0] * (w * h)
    for L in range(letters):                       # letter-like blocks with a counter (hole) each
        x0 = 8 + L * 30
        for y in range(12, h - 12):
            for x in range(x0, min(x0 + 22, w - 4)):
                if not (x0 + 7 <= x < x0 + 15 and 22 <= y < h - 22): px[y * w + x] = COL[i % 3]
    return px
atlas(tmp + "/words.hca", 200, 60, [word(200, 60, i, n) for i, n in enumerate((3, 6, 4))])
atlas(tmp + "/words-13.hca", 40, 20, [[COL[i % 3]] * 800 for i in range(13)])
atlas(tmp + "/words-big.hca", 536, 81, [[0] * (536 * 81) for _ in range(11)] + [[0xFFFF] * (536 * 81)])
PY
for pair in "e2e-words:words" "e2e-words-13:words-13" "e2e-words-big:words-big"; do
    req DELETE "/assets/${pair%%:*}"
    put_asset "${pair%%:*}" "$TMP/${pair#*:}.hca"
    expect 201 "PUT /assets/${pair%%:*} (words sheet, atlas, $(wc -c <"$TMP/${pair#*:}.hca" | tr -d ' ') B)" "j['ok'] is True"
done
req GET /scenes
expect 200 "GET /scenes lists words: params {bounce [0,100]}, defaults {bounce 60}" \
    "(lambda W: W['params']=={'bounce':[0,100]} and W['defaults']=={'bounce':60} and isinstance(W['name'],str))({s['id']:s for s in j['scenes']}['words'])"
WIT='{"type":"scene","scene":"words","id":"e2e-words","params":{"bounce":60},"duration_ms":60000,"transition":"fade"}'
WQ="{\"id\":\"e2e-qw\",\"at\":$AT,\"type\":\"scene\",\"scene\":\"words\",\"asset\":\"e2e-words\",\"params\":{\"bounce\":30},\"duration_ms\":30000}"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$WIT],\"queue\":[$WQ]}"
expect 200 "PUT /playlist with a words item (id = the sheet) and a words queue entry (asset = the sheet)" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips the sheet ids" "j['items'][0]['id']=='e2e-words' and j['queue'][0]['asset']=='e2e-words' and j['items'][0]['params']=={'bounce':60}"
poll_status "j['playlist']['current']=='scene:words'" 3
expect 200 "words item playing -> playlist.current == scene:words" "j['playlist']['current']=='scene:words'"
sleep 1
req GET /screenshot
WSN=$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(sum(1 for i in range(0,len(d),2) if d[i]|d[i+1]))' "$TMP/body" 2>/dev/null || echo 0)
if [ "${LIVE:-True}" = True ]; then
    if [ "$CODE" = 200 ] && [ "$WSN" -gt 100 ]; then pass "words screenshot after ~1 s is not black ($WSN non-black pixels)"; else fail "words screenshot: HTTP $CODE, $WSN non-black pixels"; fi
else
    info "words screenshot (panel-off session): HTTP $CODE, $WSN non-black pixels"
fi
req POST /queue/test -H "$JH" -d '{"id":"e2e-qw"}'
poll_status "j['queue']['active']=='e2e-qw'" 3
expect 200 "words queue entry -> current scene:words, queue.active e2e-qw" "j['playlist']['current']=='scene:words' and j['queue']['active']=='e2e-qw'"
req POST /next
# /show: a scene body on the sheet's path; without a body, borrowed from the playlist item, then the queue entry
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":60000}]}'
expect 200 "PUT /playlist gradient only (nothing uses the sheet)" "j['ok'] is True"
poll_status "j['playlist']['current']=='gradient'" 3
req POST /show/e2e-words -H "$JH" -d '{"duration_ms":20000}'
expect 404 "POST /show/<sheet> without a body when no words item uses it -> 404 unknown_asset (an atlas is not playable)" "j['error']=='unknown_asset'"
req POST /show/e2e-words -H "$JH" -d '{"type":"scene","scene":"words","params":{"bounce":20},"duration_ms":20000}'
expect 200 "POST /show/<sheet> with a words scene body" "j['ok'] is True"
poll_status "j['playlist']['current']=='scene:words'" 3
expect 200 "shown words body -> current scene:words" "j['playlist']['current']=='scene:words'"
req POST /next
poll_status "j['playlist']['current']=='gradient'" 3
expect 200 "/next ends the shown words -> gradient" "j['playlist']['current']=='gradient'"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":60000},$WIT]}"
expect 200 "PUT /playlist gradient (60 s) + the words item" "j['ok'] is True"
poll_status "j['playlist']['current']=='gradient'" 3
req POST /show/e2e-words -H "$JH" -d '{"duration_ms":20000}'
expect 200 "POST /show/<sheet> without a body (a playlist words item uses it)" "j['ok'] is True"
poll_status "j['playlist']['current']=='scene:words'" 3
expect 200 "the sheet is shown as its playlist words scene -> current scene:words" "j['playlist']['current']=='scene:words'"
req POST /next
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":60000}],\"queue\":[$WQ]}"
expect 200 "PUT /playlist gradient + the words queue entry" "j['ok'] is True"
poll_status "j['playlist']['current']=='gradient'" 3
req POST /show/e2e-words -H "$JH" -d '{"duration_ms":20000}'
expect 200 "POST /show/<sheet> without a body (a words queue entry uses it)" "j['ok'] is True"
poll_status "j['playlist']['current']=='scene:words'" 3
expect 200 "the sheet is shown as its queue entry's words scene -> current scene:words" "j['playlist']['current']=='scene:words'"
req POST /next
for case in 'no-such-sheet|{"type":"scene","scene":"words"}|404|unknown_asset' \
            'e2e-words-13|{"type":"scene","scene":"words"}|422|invalid_item' \
            'e2e-words|{"type":"scene","scene":"words","params":{"bounce":101}}|422|invalid_item' \
            'e2e-words|{"type":"nope"}|422|invalid_item'; do
    IFS='|' read -r wid wbody wcode werr <<<"$case"
    req POST /show/$wid -H "$JH" -d "$wbody"
    expect "$wcode" "POST /show/$wid $wbody -> $wcode $werr" "j['error']=='$werr'"
done
# invalid words items -> 422
wbad() { # wbad DESC ERROR ITEM-JSON [queue]
    if [ "${4:-}" = queue ]; then req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[],\"queue\":[$3]}"
    else req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$3]}"; fi
    expect 422 "$1 -> 422 $2" "j['error']=='$2'"
}
wbad "words without a sheet id" invalid_playlist '{"type":"scene","scene":"words"}'
wbad "words sheet id not a string" invalid_playlist '{"type":"scene","scene":"words","id":5}'
wbad "words sheet id invalid" invalid_playlist '{"type":"scene","scene":"words","id":"Bad_Sheet"}'
wbad "words unknown sheet" unknown_asset '{"type":"scene","scene":"words","id":"no-such-sheet"}'
wbad "words sheet = a strip" invalid_playlist '{"type":"scene","scene":"words","id":"e2e-strip"}'
wbad "words sheet with 13 frames" invalid_playlist '{"type":"scene","scene":"words","id":"e2e-words-13"}'
wbad "words sheet 12 x 536x81 (N*w*h > 514560)" invalid_playlist '{"type":"scene","scene":"words","id":"e2e-words-big"}'
wbad "words sheet = anim12 (12 x 536x240)" invalid_playlist '{"type":"scene","scene":"words","id":"anim12"}'
wbad "words bounce 101" invalid_params '{"type":"scene","scene":"words","id":"e2e-words","params":{"bounce":101}}'
wbad "words bounce -1" invalid_params '{"type":"scene","scene":"words","id":"e2e-words","params":{"bounce":-1}}'
wbad "words bounce 50.5" invalid_params '{"type":"scene","scene":"words","id":"e2e-words","params":{"bounce":50.5}}'
wbad "words queue entry naming the sheet in id only (queue: asset)" invalid_playlist "{\"id\":\"e2e-words\",\"at\":$AT,\"type\":\"scene\",\"scene\":\"words\"}" queue
wbad "words queue entry with an unknown sheet" unknown_asset "{\"id\":\"e2e-qw\",\"at\":$AT,\"type\":\"scene\",\"scene\":\"words\",\"asset\":\"no-such-sheet\"}" queue
for ok in '{"type":"scene","scene":"words","id":"e2e-words","params":{"bounce":0}}' \
          '{"type":"scene","scene":"words","id":"e2e-words","params":{"bounce":100},"seed":7}' \
          '{"type":"scene","scene":"words","id":"gradient"}' \
          '{"type":"scene","scene":"sand","id":"no-such-sheet"}'; do
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$ok]}"
    expect 200 "accepted: $ok" "j['ok'] is True"
done
# deleting the sheet drops the words items and queue entries using it
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$WIT,{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":60000}],\"queue\":[$WQ]}"
expect 200 "PUT /playlist words item + gradient + words queue entry" "j['ok'] is True"
poll_status "j['playlist']['current']=='scene:words'" 3
expect 200 "words first -> current scene:words" "j['playlist']['current']=='scene:words'"
req DELETE /assets/e2e-words
expect 200 "DELETE /assets/e2e-words (the sheet)" "j['ok'] is True"
req GET /playlist
expect 200 "the words item and queue entry are gone from the playlist" \
    "[i.get('id') for i in j['items']]==['gradient'] and j.get('queue',[])==[]"
poll_status "j['playlist']['current']=='gradient'" 3
expect 200 "current is no longer scene:words (gradient)" "j['playlist']['current']=='gradient'"
for id in e2e-words-13 e2e-words-big; do
    req DELETE "/assets/$id"; expect 200 "DELETE /assets/$id (test sheet)" "j['ok'] is True"
done

echo "== board (PROTOCOL §5g: a list of timed rows that scrolls; its sheet, /show, queue, 422s, delete)"
# Generated here (Python RLE16, atlas flag): e2e-board: 6 frames of 400x48 (opaque coloured rows: 0 header, 1 empty,
# 2-5 rows); e2e-board-49: 49 frames 16x16 (one too many); e2e-board-15: 2 frames 100x15 (too short);
# e2e-board-big: 48 frames 536x41 (48 x 536 x 41 = 1 054 848 px > 1 048 576).
python3 - "$TMP" <<'PY'
import struct, sys
tmp = sys.argv[1]
def rle(px):
    out = bytearray(); i = 0; n = len(px)
    while i < n:
        j = i
        while j < n and j - i < 32768 and px[j] == px[i]: j += 1
        if j - i >= 3: out += struct.pack("<H", 0x8000 | (j - i - 1)) + struct.pack(">H", px[i]); i = j; continue
        k = i
        while k < n and k - i < 32768 and not (k + 2 < n and px[k] == px[k+1] == px[k+2]): k += 1
        out += struct.pack("<H", k - i - 1) + b"".join(struct.pack(">H", p) for p in px[i:k]); i = k
    return bytes(out)
def atlas(path, w, h, frames):
    data = [rle(f) for f in frames]
    off = 32 + 12 * len(frames); table = b""; body = b""
    for d in data: table += struct.pack("<IIHH", off + len(body), len(d), 0, 0); body += d
    open(path, "wb").write(b"HCA1" + struct.pack("<HHHBBHHII", w, h, len(frames), 0, 1, 0, 1, 32, off + len(body)) + bytes(8) + table + body)
COL = (0x2945, 0x4208, 0x07E0, 0xFD20, 0x001F, 0xF81F)
def row(w, h, i):                    # a coloured card with a light "time" block and a darker "title" block
    px = []
    for y in range(h):
        for x in range(w):
            if 6 <= y < h - 6 and 10 <= x < 90: px.append(0xFFFF)
            elif 14 <= y < h - 14 and 110 <= x < w - 20: px.append(0x8410)
            else: px.append(COL[i % len(COL)])
    return px
atlas(tmp + "/board.hca", 400, 48, [row(400, 48, i) for i in range(6)])
atlas(tmp + "/board-49.hca", 16, 16, [[COL[i % 6]] * 256 for i in range(49)])
atlas(tmp + "/board-15.hca", 100, 15, [[COL[i]] * 1500 for i in range(2)])
atlas(tmp + "/board-big.hca", 536, 41, [[0] * (536 * 41) for _ in range(48)])
PY
for pair in "e2e-board:board" "e2e-board-49:board-49" "e2e-board-15:board-15" "e2e-board-big:board-big"; do
    req DELETE "/assets/${pair%%:*}"
    put_asset "${pair%%:*}" "$TMP/${pair#*:}.hca"
    expect 201 "PUT /assets/${pair%%:*} (board sheet, atlas, $(wc -c <"$TMP/${pair#*:}.hca" | tr -d ' ') B)" "j['ok'] is True"
done
req GET /status
BNOW=$(jint "j['time']['epoch']") || { fail "status.time.epoch is not an integer"; BNOW=$(date +%s); }
BFUT=$(( BNOW + 3600 )); BPAST=$(( BNOW - 60 ))
BIT="{\"type\":\"board\",\"id\":\"e2e-board\",\"header\":0,\"empty\":1,\"rows\":[{\"frame\":2,\"until\":$BFUT},{\"frame\":3},{\"frame\":4,\"until\":$BPAST},{\"frame\":5,\"until\":null}],\"scroll_px_s\":16,\"duration_ms\":60000,\"transition\":\"fade\"}"
BQ="{\"id\":\"e2e-qb\",\"at\":$AT,\"type\":\"board\",\"asset\":\"e2e-board\",\"rows\":[{\"frame\":2}],\"duration_ms\":30000}"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$BIT],\"queue\":[$BQ]}"
expect 200 "PUT /playlist with a board item (id = the sheet) and a board queue entry (asset = the sheet)" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips the board" \
    "j['items'][0]['id']=='e2e-board' and j['items'][0]['header']==0 and j['items'][0]['empty']==1 and [r['frame'] for r in j['items'][0]['rows']]==[2,3,4,5] and j['items'][0]['rows'][0]['until']==int(a[0]) and j['queue'][0]['asset']=='e2e-board'" "$BFUT"
poll_status "j['playlist']['current']=='board:e2e-board'" 3
expect 200 "board item playing -> playlist.current == board:e2e-board" "j['playlist']['current']=='board:e2e-board'"
sleep 1
req GET /screenshot
BSN=$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(sum(1 for i in range(0,len(d),2) if d[i]|d[i+1]))' "$TMP/body" 2>/dev/null || echo 0)
if [ "${LIVE:-True}" = True ]; then
    if [ "$CODE" = 200 ] && [ "$BSN" -gt 1000 ]; then pass "board screenshot is not black ($BSN non-black pixels)"; else fail "board screenshot: HTTP $CODE, $BSN non-black pixels"; fi
else
    info "board screenshot (panel-off session): HTTP $CODE, $BSN non-black pixels"
fi
req POST /queue/test -H "$JH" -d '{"id":"e2e-qb"}'
poll_status "j['queue']['active']=='e2e-qb'" 3
expect 200 "board queue entry -> current board:e2e-board, queue.active e2e-qb" "j['playlist']['current']=='board:e2e-board' and j['queue']['active']=='e2e-qb'"
req POST /next
# /show: a board body on the sheet's path; without a body, borrowed from the playlist item, then the queue entry
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":60000}]}'
expect 200 "PUT /playlist gradient only (nothing uses the sheet)" "j['ok'] is True"
poll_status "j['playlist']['current']=='gradient'" 3
req POST /show/e2e-board -H "$JH" -d '{"duration_ms":20000}'
expect 404 "POST /show/<sheet> without a body when no board uses it -> 404 unknown_asset (an atlas is not playable)" "j['error']=='unknown_asset'"
req POST /show/e2e-board -H "$JH" -d '{"type":"board","rows":[{"frame":3},{"frame":2}],"header":0,"duration_ms":20000}'
expect 200 "POST /show/<sheet> with a board body" "j['ok'] is True"
poll_status "j['playlist']['current']=='board:e2e-board'" 3
expect 200 "shown board body -> current board:e2e-board" "j['playlist']['current']=='board:e2e-board'"
req POST /next
poll_status "j['playlist']['current']=='gradient'" 3
expect 200 "/next ends the shown board -> gradient" "j['playlist']['current']=='gradient'"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":60000},$BIT]}"
expect 200 "PUT /playlist gradient (60 s) + the board" "j['ok'] is True"
poll_status "j['playlist']['current']=='gradient'" 3
req POST /show/e2e-board -H "$JH" -d '{"duration_ms":20000}'
expect 200 "POST /show/<sheet> without a body (a playlist board uses it)" "j['ok'] is True"
poll_status "j['playlist']['current']=='board:e2e-board'" 3
expect 200 "the sheet is shown as its playlist board -> current board:e2e-board" "j['playlist']['current']=='board:e2e-board'"
req POST /next
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":60000}],\"queue\":[$BQ]}"
expect 200 "PUT /playlist gradient + the board queue entry" "j['ok'] is True"
poll_status "j['playlist']['current']=='gradient'" 3
req POST /show/e2e-board -H "$JH" -d '{"duration_ms":20000}'
expect 200 "POST /show/<sheet> without a body (a board queue entry uses it)" "j['ok'] is True"
poll_status "j['playlist']['current']=='board:e2e-board'" 3
expect 200 "the sheet is shown as its queue entry's board -> current board:e2e-board" "j['playlist']['current']=='board:e2e-board'"
req POST /next
for case in 'no-such-sheet|{"type":"board","rows":[{"frame":0}]}|404|unknown_asset' \
            'e2e-board-49|{"type":"board","rows":[{"frame":0}]}|422|invalid_item' \
            'e2e-board|{"type":"board","rows":[{"frame":6}]}|422|invalid_item' \
            'e2e-board|{"type":"board","rows":[]}|422|invalid_item'; do
    IFS='|' read -r bid bbody bcode berr <<<"$case"
    req POST /show/$bid -H "$JH" -d "$bbody"
    expect "$bcode" "POST /show/$bid $bbody -> $bcode $berr" "j['error']=='$berr'"
done
# invalid boards -> 422 (sheet e2e-board: 6 frames, so frames 0..5)
bbad() { # bbad DESC ERROR ITEM-JSON [queue]
    if [ "${4:-}" = queue ]; then req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[],\"queue\":[$3]}"
    else req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$3]}"; fi
    expect 422 "$1 -> 422 $2" "j['error']=='$2'"
}
BB='"type":"board","id":"e2e-board"'
BR='"rows":[{"frame":2}]'
bbad "board without a sheet id" invalid_playlist "{\"type\":\"board\",$BR}"
bbad "board sheet id not a string" invalid_playlist "{\"type\":\"board\",\"id\":5,$BR}"
bbad "board sheet id invalid" invalid_playlist "{\"type\":\"board\",\"id\":\"Bad_Sheet\",$BR}"
bbad "board unknown sheet" unknown_asset "{\"type\":\"board\",\"id\":\"no-such-sheet\",$BR}"
bbad "board sheet = a strip" invalid_playlist "{\"type\":\"board\",\"id\":\"e2e-strip\",\"rows\":[{\"frame\":0}]}"
bbad "board sheet with 49 frames" invalid_playlist "{\"type\":\"board\",\"id\":\"e2e-board-49\",\"rows\":[{\"frame\":0}]}"
bbad "board sheet 15 px tall" invalid_playlist "{\"type\":\"board\",\"id\":\"e2e-board-15\",\"rows\":[{\"frame\":0}]}"
bbad "board sheet 48 x 536x41 (N*w*h > 1048576)" invalid_playlist "{\"type\":\"board\",\"id\":\"e2e-board-big\",\"rows\":[{\"frame\":0}]}"
for kv in '"header":6' '"header":-1' '"header":1.5' '"header":"0"' '"header":true' '"empty":6' '"empty":[1]' \
          '"scroll_px_s":3' '"scroll_px_s":61' '"scroll_px_s":16.5' '"scroll_px_s":null' '"scroll_px_s":"16"'; do
    bbad "board $kv" invalid_playlist "{$BB,$BR,$kv}"
done
for rs in '' '"rows":[]' '"rows":{}' '"rows":5' '"rows":[5]' '"rows":[{}]' '"rows":[{"until":1}]' '"rows":[{"frame":6}]' \
          '"rows":[{"frame":-1}]' '"rows":[{"frame":1.5}]' '"rows":[{"frame":"2"}]' '"rows":[{"frame":2,"until":1.5}]' \
          '"rows":[{"frame":2,"until":"x"}]' '"rows":[{"frame":2,"until":-1}]' '"rows":[{"frame":2,"until":4294967296}]' \
          '"rows":[{"frame":2},{"frame":9}]'; do
    bbad "board ${rs:-without rows}" invalid_playlist "{$BB${rs:+,$rs}}"
done
B48=$(python3 -c 'print(",".join("{\"frame\":%d}" % (i % 6) for i in range(48)))')
bbad "board with 48 rows (max 47)" invalid_playlist "{$BB,\"rows\":[$B48]}"
bbad "board queue entry naming the sheet in id only (queue: asset)" invalid_playlist "{\"id\":\"e2e-board\",\"at\":$AT,\"type\":\"board\",$BR}" queue
bbad "board queue entry with an unknown sheet" unknown_asset "{\"id\":\"e2e-qb\",\"at\":$AT,\"type\":\"board\",\"asset\":\"no-such-sheet\",$BR}" queue
B47=$(python3 -c 'print(",".join("{\"frame\":%d%s}" % (i % 6, ",\"until\":%d" % (1761062400 + i) if i % 2 else "") for i in range(47)))')
for ok in "{$BB,$BR}" \
          "{$BB,\"rows\":[{\"frame\":2,\"until\":$BPAST},{\"frame\":3,\"until\":$BFUT},{\"frame\":4}],\"header\":null,\"empty\":null}" \
          "{$BB,\"rows\":[$B47],\"header\":5,\"empty\":0,\"scroll_px_s\":4}" \
          "{$BB,$BR,\"scroll_px_s\":60,\"duration_ms\":0}" \
          "{$BB,\"rows\":[{\"frame\":2,\"until\":0},{\"frame\":2,\"until\":4294967295},{\"frame\":2,\"until\":null}]}" \
          "{\"type\":\"board\",\"id\":\"gradient\",\"rows\":[{\"frame\":0}]}"; do
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$ok]}"
    expect 200 "accepted: $(printf '%s' "$ok" | head -c 140)" "j['ok'] is True"
done
# deleting the sheet drops the board items and queue entries using it
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$BIT,{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":60000}],\"queue\":[$BQ]}"
expect 200 "PUT /playlist board + gradient + board queue entry" "j['ok'] is True"
poll_status "j['playlist']['current']=='board:e2e-board'" 3
expect 200 "board first -> current board:e2e-board" "j['playlist']['current']=='board:e2e-board'"
req DELETE /assets/e2e-board
expect 200 "DELETE /assets/e2e-board (the sheet)" "j['ok'] is True"
req GET /playlist
expect 200 "the board item and queue entry are gone from the playlist" \
    "[i.get('id') for i in j['items']]==['gradient'] and j.get('queue',[])==[]"
poll_status "j['playlist']['current']=='gradient'" 3
expect 200 "current is no longer board:e2e-board (gradient)" "j['playlist']['current']=='gradient'"
for id in e2e-board-49 e2e-board-15 e2e-board-big; do
    req DELETE "/assets/$id"; expect 200 "DELETE /assets/$id (test sheet)" "j['ok'] is True"
done

echo "== orientation (PROTOCOL §4 \"Orientation\")"
# Config round trip of the three modes, invalid values, /status.orientation and /imu.flipped. On the real
# clip the forced modes turn the panel over at once (look at it); auto keeps the current orientation unless
# gravity says otherwise for 1 s, so the order flipped -> normal -> auto leaves a clip lying flat normal.
req GET /config
expect 200 "GET /config has orientation (auto|normal|flipped)" "j.get('orientation') in ('auto','normal','flipped')"
O_ORIENT=$(jenum "j['orientation']" auto normal flipped) || { fail "GET /config: orientation is not auto, normal or flipped"; O_ORIENT=auto; }
req GET /status
expect 200 "status.orientation = {mode == config ($O_ORIENT), flipped: bool}" \
    "j['orientation']['mode']==a[0] and isinstance(j['orientation']['flipped'], bool) and set(j['orientation'])=={'mode','flipped'}" "$O_ORIENT"
for m in flipped normal auto; do
    case $m in flipped) F=True ;; normal) F=False ;; *) F=any ;; esac
    req PUT /config -H "$JH" -d "{\"orientation\":\"$m\"}"
    expect 200 "PUT /config orientation $m -> full config" "j['orientation']=='$m' and 'brightness' in j"
    req GET /config
    expect 200 "GET /config orientation $m (persisted)" "j['orientation']=='$m'"
    req GET /status
    if [ "$F" = any ]; then
        expect 200 "status.orientation mode auto, flipped bool" "j['orientation']['mode']=='auto' and isinstance(j['orientation']['flipped'], bool)"
        SF=$(jbool "j['orientation']['flipped']") || SF=False
        info "auto: clip is $( [ "$SF" = True ] && echo flipped || echo normal ) now"
        req GET /imu
        expect 200 "GET /imu.flipped is a bool in auto" "isinstance(j.get('flipped'), bool)"
    else
        expect 200 "status.orientation == {mode $m, flipped $F} (applied at once)" "j['orientation']=={'mode':'$m','flipped':$F}"
        req GET /imu
        expect 200 "GET /imu.flipped == $F, g unrotated (3 floats)" "j.get('flipped') is $F and len(j['g'])==3"
    fi
done
for bad in '"orientation":"sideways"' '"orientation":"Auto"' '"orientation":180' '"orientation":null' '"orientation":true'; do
    req PUT /config -H "$JH" -d "{$bad}"
    expect 422 "PUT /config {$bad} -> 422 invalid_config" "j['error']=='invalid_config'"
done
req GET /config
expect 200 "invalid orientation left the config alone (auto)" "j['orientation']=='auto'"
req PUT /config -H "$JH" -d "{\"orientation\":\"$O_ORIENT\"}"
expect 200 "orientation restored ($O_ORIENT)" "j['orientation']==a[0]" "$O_ORIENT"

echo "== imu"
req GET /imu
expect 200 "GET /imu" "j['ok'] is True and isinstance(j['present'],bool) and len(j['g'])==3 and isinstance(j['samples'],int) and isinstance(j['shake'],(int,float))"
if [ "$(jget "j['present']")" = "True" ]; then
    expect 200 "IMU sampling, |g| ~ 1 g at rest" "j['samples']>0 and 0.7<=sum(x*x for x in j['g'])**0.5<=1.3"
    info "g = $(jget "j['g']") (upright clip: ~[0,1,0]; face up: ~[0,0,-1]; see README 'IMU bench check'), raw = $(jget "j.get('raw')"), addr $(jget "j.get('addr')")"
else
    info "IMU not present: scenes run with fixed downward gravity"
fi
IMU_PRESENT=$(jbool "j['present']") || IMU_PRESENT=False
expect 200 "GET /imu reports calibrated + axis_map (3x3 signed permutation)" \
    "isinstance(j['calibrated'],bool) and len(j['axis_map'])==3 and all(sorted(abs(x) for x in r)==[0,0,1] for r in j['axis_map'])"
info "axis map: $(jget "j['axis_map']") ($( [ "$(jget "j['calibrated']")" = True ] && echo 'bench calibration stored in NVS' || echo 'compiled map + Kconfig flips'))"
req POST /imu/calibrate -H "$JH" -d '{"step":"sideways"}'
expect 422 "POST /imu/calibrate with an unknown step -> 422 invalid_step" "j['error']=='invalid_step'"
req POST /imu/calibrate -H "$JH" -d '{}'
expect 400 "POST /imu/calibrate without a step -> 400" "j['ok'] is False"
case "$CLIP" in *127.0.0.1*|*localhost*) CALIB=auto ;; *) CALIB=$([ -n "${E2E_CALIB:-}" ] && echo interactive || echo skip) ;; esac
if [ "$CALIB" != skip ] && [ "$IMU_PRESENT" = True ]; then
    echo "== imu calibration ($CALIB)"
    [ "$CALIB" = interactive ] && read -r -p "  >>  Hold the clip UPRIGHT (landscape, image readable, vertical) and still, then press Enter " _
    req POST /imu/calibrate -H "$JH" -d '{"step":"upright"}'
    expect 200 "calibrate step upright (still reading captured)" "j['step']=='upright' and len(j['raw'])==3 and j['next']=='faceup'"
    [ "$CALIB" = interactive ] && read -r -p "  >>  Lay the clip FACE UP (glass toward the ceiling) and still, then press Enter " _
    req POST /imu/calibrate -H "$JH" -d '{"step":"faceup"}'
    expect 200 "calibrate step faceup -> axis map computed, applied and stored" "j['calibrated'] is True and len(j['axis_map'])==3"
    info "calibrated axis map: $(jget "j.get('axis_map')")"
    req GET /imu
    expect 200 "GET /imu: calibrated, face up reads g[2] ~ -1" "j['calibrated'] is True and j['g'][2] < -0.7"
    if [ "$CALIB" = auto ]; then
        req POST /imu/calibrate -H "$JH" -d '{"step":"reset"}'
        expect 200 "calibrate reset -> back to the compiled map" "j['calibrated'] is False"
        req GET /imu
        expect 200 "GET /imu: not calibrated after reset" "j['calibrated'] is False"
    fi
else
    info "IMU calibration flow skipped (E2E_CALIB=1 runs it interactively on the clip)"
fi

echo "== reader (PROTOCOL §5c: texts, fonts, reader items, POST/GET /reader)"
# Generated here: a small text (title line, two paragraphs, accents, ASCII words only so that a plain
# whitespace split gives the device's word count) and a reader font pair (normal 24x40 + compact 16x28,
# white + accent glyph atlases, geometric glyphs) with its font document.
for id in e2e-text e2e-text-bad; do req DELETE "/texts/$id"; done
req DELETE /fonts/e2e-font
python3 - "$TMP" <<'PY'
import json, struct, sys
tmp = sys.argv[1]
words = ("Le chat dort au soleil pendant que la ville s'éveille doucement. "
         "Elle lit un livre de poche, une page après l'autre, sans se presser.").split()
text = "Lecture rapide e2e\n\n" + " ".join(words[:12]) + "\n\n" + " ".join(words[12:]) + "\n"
open(tmp + "/reader.txt", "w", encoding="utf-8").write(text)
open(tmp + "/reader.words", "w").write(str(len(text.split())))
open(tmp + "/reader-bad-utf8.txt", "wb").write(b"Titre\nun \xff mot\n")
open(tmp + "/reader-nul.txt", "wb").write(b"Titre\nun\x00mot\n")
open(tmp + "/reader-blank.txt", "wb").write(b" \n\t \n")
open(tmp + "/reader-big.txt", "wb").write(b"a " * (512 * 1024) + b"b")      # 1 MiB + 1 byte
def be(v): return struct.pack(">H", v)
def rle(px):
    out = bytearray(); i = 0; n = len(px)
    while i < n:
        j = i
        while j < n and j - i < 32768 and px[j] == px[i]: j += 1
        if j - i >= 3:
            out += struct.pack("<H", 0x8000 | (j - i - 1)) + be(px[i]); i = j; continue
        k = i
        while k < n and k - i < 32768 and not (k + 2 < n and px[k] == px[k+1] == px[k+2]): k += 1
        out += struct.pack("<H", k - i - 1) + b"".join(be(p) for p in px[i:k]); i = k
    return bytes(out)
def hca(w, h, frames, flags):
    data = [rle(f) for f in frames]
    off = 32 + 12 * len(frames); table = b""; body = b""
    for d in data:
        table += struct.pack("<IIHH", off + len(body), len(d), 0, 0); body += d
    return b"HCA1" + struct.pack("<HHHBBHHII", w, h, len(frames), 0, 1, 0, flags, 32, off + len(body)) + bytes(8) + table + body
glyphs = [chr(c) for c in range(0x20, 0x7F)] + ["é", "è", "à", "·", "⏸"]
def face(cw, ch, base, color, adv):
    frames = []
    for i, g in enumerate(glyphs):
        px = [0] * (cw * ch)
        if g != " ":
            w = adv - 2
            for y in range(base - ch // 2, base):
                for x in range(1, w):
                    if (x + y + i) % 5: px[y * cw + x] = color
        frames.append(px)
    return hca(cw, ch, frames, 1)
for name, cw, ch, base, color, adv in (("w", 24, 40, 32, 0xFFFF, 20), ("a", 24, 40, 32, 0xC51F, 20),
                                       ("cw", 16, 28, 22, 0xFFFF, 13), ("ca", 16, 28, 22, 0xC51F, 13),
                                       ("lw", 31, 52, 42, 0xFFFF, 26), ("la", 31, 52, 42, 0xC51F, 26)):
    open(tmp + "/font-%s.hca" % name, "wb").write(face(cw, ch, base, color, adv))
def doc(cw, ch, base, adv, white, accent):
    return {"glyphs": "".join(glyphs), "advance": [adv] * len(glyphs), "cell_w": cw, "cell_h": ch, "baseline": base,
            "atlas_white": white, "atlas_accent": accent}
font = doc(24, 40, 32, 20, "e2e-font-w", "e2e-font-a")
font["compact"] = doc(16, 28, 22, 13, "e2e-font-cw", "e2e-font-ca")
json.dump(font, open(tmp + "/font.json", "w"), ensure_ascii=False)
bad = dict(font); bad["advance"] = [20] * (len(glyphs) - 1)
json.dump(bad, open(tmp + "/font-badadv.json", "w"), ensure_ascii=False)
bad = dict(font); bad["atlas_white"] = "e2e-no-such-atlas"
json.dump(bad, open(tmp + "/font-noatlas.json", "w"), ensure_ascii=False)
bad = dict(font); bad["atlas_white"] = "e2e-font-cw"                      # 16x28 atlas for 24x40 cells
json.dump(bad, open(tmp + "/font-geometry.json", "w"), ensure_ascii=False)
# §5f.11 the optional "large" face (1.3 x the normal cell; the oracle's text screens) and broken variants
large = doc(31, 52, 42, 26, "e2e-font-lw", "e2e-font-la")
json.dump(dict(font, large=large), open(tmp + "/font-large.json", "w"), ensure_ascii=False)
json.dump(dict(font, large=None), open(tmp + "/font-large-null.json", "w"), ensure_ascii=False)
json.dump(dict(font, large={k: v for k, v in large.items() if k != "advance"}), open(tmp + "/font-large-noadv.json", "w"), ensure_ascii=False)
json.dump(dict(font, large=5), open(tmp + "/font-large-5.json", "w"), ensure_ascii=False)
json.dump(dict(font, large=dict(large, atlas_white="e2e-no-such-atlas")), open(tmp + "/font-large-noatlas.json", "w"), ensure_ascii=False)
json.dump(dict(font, large=dict(large, atlas_accent="e2e-font-a")), open(tmp + "/font-large-geometry.json", "w"), ensure_ascii=False)
PY
RW=$(cat "$TMP/reader.words")
for a in w a cw ca; do
    put_asset "e2e-font-$a" "$TMP/font-$a.hca"
    expect 201 "PUT /assets/e2e-font-$a (reader glyph atlas)" "j['ok'] is True"
done
req PUT /fonts/e2e-font -H "$JH" --data-binary "@$TMP/font.json"
expect 201 "PUT /fonts/e2e-font (normal + compact, white + accent atlases)" "j['ok'] is True and j['id']=='e2e-font'"
req GET /fonts/e2e-font
expect 200 "GET /fonts/e2e-font round-trips the document" "j['ok'] is True and j['glyphs'].endswith('·⏸') and j['compact']['cell_w']==16 and len(j['advance'])==len(j['glyphs'])"
req GET /fonts
expect 200 "GET /fonts lists it" "'e2e-font' in [f['id'] for f in j['fonts']]"
req PUT /fonts/e2e-font -H "$JH" --data-binary "@$TMP/font-badadv.json"
expect 422 "font with one advance missing -> 422 malformed" "j['error']=='malformed'"
req PUT /fonts/e2e-font -H "$JH" --data-binary "@$TMP/font-noatlas.json"
expect 422 "font naming an atlas that is not uploaded -> 422 unknown_asset" "j['error']=='unknown_asset'"
req PUT /fonts/e2e-font -H "$JH" --data-binary "@$TMP/font-geometry.json"
expect 422 "font whose atlas has the wrong cell size -> 422 malformed" "j['error']=='malformed'"
req PUT /fonts/e2e-font -H "$JH" -d 'not json'
expect 422 "font document that is not JSON -> 422 malformed" "j['error']=='malformed'"
req PUT /fonts/Bad_Font -H "$JH" --data-binary "@$TMP/font.json"
expect 400 "invalid font id -> 400" "j['error']=='invalid_id'"
RSZ=$(wc -c <"$TMP/reader.txt" | tr -d ' ')
req PUT /texts/e2e-text -H "X-Content-SHA256: $(sha "$TMP/reader.txt")" -H 'Content-Type: text/plain; charset=utf-8' --data-binary "@$TMP/reader.txt"
expect 201 "PUT /texts/e2e-text ($RSZ B, $RW words)" "j['ok'] is True and j['id']=='e2e-text' and j['words']==$RW and j['bytes']==$RSZ and j['title']=='Lecture rapide e2e'"
req PUT /texts/e2e-text -H "X-Content-SHA256: $(sha "$TMP/reader.txt")" --data-binary "@$TMP/reader.txt"
expect 409 "re-upload identical text -> 409" "j['ok'] is False and j['error']=='exists'"
req PUT /texts/e2e-text-bad -H "X-Content-SHA256: 0000000000000000000000000000000000000000000000000000000000000000" --data-binary "@$TMP/reader.txt"
expect 422 "text with a wrong X-Content-SHA256 -> 422" "j['error']=='sha256_mismatch'"
for bad in bad-utf8 nul blank; do
    req PUT /texts/e2e-text-bad -H "X-Content-SHA256: $(sha "$TMP/reader-$bad.txt")" --data-binary "@$TMP/reader-$bad.txt"
    expect 422 "text $bad -> 422 malformed" "j['error']=='malformed'"
done
req PUT /texts/e2e-text-bad -H "X-Content-SHA256: $(sha "$TMP/reader-big.txt")" --data-binary "@$TMP/reader-big.txt"
expect 413 "text of 1 MiB + 1 byte -> 413" "j['ok'] is False"
req PUT /texts/e2e-text-bad --data-binary "@$TMP/reader.txt"
expect 400 "text without X-Content-SHA256 -> 400" "j['error']=='missing_sha256'"
req PUT /texts/Bad_Text -H "X-Content-SHA256: $(sha "$TMP/reader.txt")" --data-binary "@$TMP/reader.txt"
expect 400 "invalid text id -> 400" "j['error']=='invalid_id'"
req GET /texts
expect 200 "GET /texts: id, bytes, words, title, progress_word (0)" \
    "(lambda T: T['e2e-text']['words']==$RW and T['e2e-text']['bytes']==$RSZ and T['e2e-text']['progress_word']==0 and T['e2e-text']['title']=='Lecture rapide e2e' and 'e2e-text-bad' not in T)({t['id']:t for t in j['texts']})"
req GET /texts/e2e-text
if [ "$CODE" = 200 ] && [ "$(sha "$TMP/body")" = "$(sha "$TMP/reader.txt")" ]; then pass "GET /texts/e2e-text round-trips byte-exact"; else fail "GET /texts/e2e-text: HTTP $CODE, hash differs"; fi
RPL='{"version":1,"items":[{"type":"reader","text":"e2e-text","font":"e2e-font","wpm":300,"from_word":0,"loop":false,"duration_ms":0},{"type":"asset","id":"gradient","duration_ms":5000}]}'
req PUT /playlist -H "$JH" -d "$RPL"
expect 200 "PUT /playlist with a reader item" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips the reader item" "j['items'][0]=={'type':'reader','text':'e2e-text','font':'e2e-font','wpm':300,'from_word':0,'loop':False,'duration_ms':0}"
sleep 1
req GET /status
expect 200 "reader item playing -> playlist.current == reader:e2e-text" "j['playlist']['current']=='reader:e2e-text'"
req GET /reader
expect 200 "GET /reader: text, word, words, paused, wpm" \
    "j['ok'] is True and j['active'] is True and j['text']=='e2e-text' and j['words']==$RW and 0<=j['word']<$RW and j['paused'] is False and j['wpm']==300"
req GET /screenshot
RDN=$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(sum(1 for i in range(0,len(d),2) if d[i]|d[i+1]))' "$TMP/body" 2>/dev/null || echo 0)
if [ "$CODE" = 200 ] && [ "$RDN" -gt 50 ]; then pass "reader screenshot has a word on it ($RDN non-black pixels)"; else fail "reader screenshot: HTTP $CODE, $RDN non-black pixels"; fi
req POST /reader -H "$JH" -d '{"action":"pause"}'
expect 200 "POST /reader pause" "j['ok'] is True and j['paused'] is True and j['text']=='e2e-text'"
req GET /reader
expect 200 "GET /reader reports paused" "j['paused'] is True"
req POST /reader -H "$JH" -d '{"action":"seek","word":5}'
expect 200 "POST /reader seek 5 (while paused)" "j['word']==5 and j['paused'] is True"
req GET /texts
expect 200 "seek persisted: GET /texts progress_word == 5" "{t['id']:t for t in j['texts']}['e2e-text']['progress_word']==5"
req POST /reader -H "$JH" -d '{"action":"resume"}'
expect 200 "POST /reader resume" "j['paused'] is False and j['word']>=5"
req POST /reader -H "$JH" -d "{\"action\":\"seek\",\"word\":$RW}"
expect 422 "seek beyond the last word -> 422 invalid_word" "j['error']=='invalid_word'"
req POST /reader -H "$JH" -d '{"action":"seek","word":-1}'
expect 422 "seek to -1 -> 422 invalid_word" "j['error']=='invalid_word'"
req POST /reader -H "$JH" -d '{"action":"seek"}'
expect 422 "seek without a word -> 422 invalid_word" "j['error']=='invalid_word'"
req POST /reader -H "$JH" -d '{"action":"jump"}'
expect 422 "unknown action -> 422 invalid_action" "j['error']=='invalid_action'"
req POST /reader -H "$JH" -d '{}'
expect 400 "POST /reader without an action -> 400" "j['ok'] is False"
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"reader","text":"e2e-text","font":"e2e-font","wpm":450,"from_word":7,"loop":true}]}'
expect 200 "PUT /playlist with from_word 7, 450 wpm, loop" "j['ok'] is True"
sleep 1
req GET /reader
expect 200 "from_word overrides the saved progress -> word 7 (or just after it), 450 wpm" "7<=j['word']<$RW and j['wpm']==450"
for bad in '"text":"no-such-text","font":"e2e-font"' '"text":"e2e-text","font":"no-such-font"'; do
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"reader\",$bad}]}"
    case "$bad" in *no-such-text*) want=unknown_text ;; *) want=unknown_font ;; esac
    expect 422 "reader item naming a missing ${want#unknown_} -> 422 $want" "j['error']=='$want'"
done
for bad in '"wpm":10' '"wpm":300.5' '"wpm":"fast"' '"loop":"yes"' '"from_word":-1' '"from_word":1.5'; do
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"reader\",\"text\":\"e2e-text\",\"font\":\"e2e-font\",$bad}]}"
    expect 422 "reader item $bad -> 422 invalid_playlist" "j['error']=='invalid_playlist'"
done
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"reader","font":"e2e-font"}]}'
expect 422 "reader item without a text -> 422 invalid_playlist" "j['error']=='invalid_playlist'"
RQ=$(( $(date +%s) + 7200 ))
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000}],\"queue\":[{\"id\":\"e2e-qr\",\"at\":$RQ,\"type\":\"reader\",\"text\":\"e2e-text\",\"font\":\"e2e-font\",\"wpm\":250,\"duration_ms\":30000}]}"
expect 200 "queue entry with a reader item" "j['ok'] is True"
req POST /reader -H "$JH" -d '{"action":"pause"}'
expect 409 "POST /reader with no reader on screen -> 409 no_reader" "j['error']=='no_reader'"
req POST /queue/test -H "$JH" -d '{"id":"e2e-qr"}'
sleep 1
req GET /status
expect 200 "reader queue entry on screen -> current reader:e2e-text, queue.active e2e-qr" "j['playlist']['current']=='reader:e2e-text' and j['queue']['active']=='e2e-qr'"
req GET /reader
expect 200 "GET /reader during the queue entry (250 wpm)" "j['active'] is True and j['wpm']==250"
req POST /next
req PUT /playlist -H "$JH" -d "$RPL"
expect 200 "reader playlist again" "j['ok'] is True"
req DELETE /texts/e2e-text
expect 200 "DELETE /texts/e2e-text" "j['ok'] is True"
req GET /playlist
expect 200 "deleting the text removed its reader item from the playlist" "all(i.get('type')!='reader' for i in j['items']) and len(j['items'])==1"
sleep 1
req GET /reader
expect 200 "GET /reader with no reader item -> active false, text null" "j['active'] is False and j['text'] is None"
req DELETE /texts/e2e-text
expect 404 "DELETE /texts/e2e-text again -> 404" "j['ok'] is False"
req DELETE /fonts/e2e-font
expect 200 "DELETE /fonts/e2e-font" "j['ok'] is True"
req GET /fonts/e2e-font
expect 404 "GET /fonts/e2e-font after delete -> 404 unknown_font" "j['error']=='unknown_font'"
for a in w a cw ca; do req DELETE "/assets/e2e-font-$a"; done
expect 200 "test atlases deleted" "j['ok'] is True"

echo "== oracle (PROTOCOL §5f-§5f.7: one three-card reading, the lean draw: three, lean screens, details, hold; POST /oracle/draw|turn|back, /status.oracle)"
# Generated here as PNGs and encoded with tools/hcaenc (built into build/core/tools; a Python RLE16 encoder is the
# fallback): a 4-card deck D (108x206 atlas, 5 frames), keys K (160x34 atlas, 4), notes N (536x72 atlas, 4), 3-frame
# keys / notes for a 3-card item (with the 4-frame deck), a 112x214 deck and a 160x26 keys atlas that do not fit. The text comes from
# the reader bundle (§5f.2, the item's id): core/fixtures/tarot/reader-en.txt under a texts id unique per run, drawn
# with the reader section's generated font (body + big).
HCAENC="$REPO/build/core/tools/hcaenc"
if [ ! -x "$HCAENC" ] && command -v cmake >/dev/null 2>&1; then
    cmake -S "$REPO/core" -B "$REPO/build/core" >/dev/null 2>&1 && cmake --build "$REPO/build/core" --target hcaenc >/dev/null 2>&1
fi
[ -x "$HCAENC" ] || HCAENC=""
ORBUN="$REPO/core/fixtures/tarot/reader-en.txt"
python3 - "$TMP" "$HCAENC" "$ORBUN" <<'PY'
import struct, sys, zlib, subprocess, os
tmp, enc, bun = sys.argv[1], sys.argv[2], sys.argv[3]
def png(path, w, h, px):            # px: list of (r,g,b) rows
    raw = b"".join(b"\x00" + bytes(c for p in row for c in p) for row in px)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                           chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
COL = [(230, 60, 60), (60, 200, 90), (70, 110, 240), (240, 200, 40), (200, 80, 220)]
def frame(w, h, f):                 # f(x, y) -> rgb
    return [[f(x, y) for x in range(w)] for y in range(h)]
def card(i):                        # the back (i = -1) or card i
    c = COL[i % 5] if i >= 0 else (90, 40, 120)
    return frame(108, 206, lambda x, y: (250, 240, 220) if (x < 3 or x > 104 or y < 3 or y > 202) else c)
def old_card(i):                    # a 112x214 card: another size, does not fit
    return frame(112, 214, lambda x, y: COL[i % 5] if i >= 0 else (90, 40, 120))
def tile(w, h, i): return frame(w, h, lambda x, y: COL[i] if 10 <= y < h - 6 and 20 <= x < 20 + 20 * (i + 1) else (0, 0, 0))
def be(r, g, b): return struct.pack(">H", ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
def rle(px):
    out = bytearray(); i = 0; n = len(px)
    while i < n:
        j = i
        while j < n and j - i < 32768 and px[j] == px[i]: j += 1
        if j - i >= 3: out += struct.pack("<H", 0x8000 | (j - i - 1)) + px[i]; i = j; continue
        k = i
        while k < n and k - i < 32768 and not (k + 2 < n and px[k] == px[k+1] == px[k+2]): k += 1
        out += struct.pack("<H", k - i - 1) + b"".join(px[i:k]); i = k
    return bytes(out)
def py_hca(path, frames, atlas):
    w, h = len(frames[0][0]), len(frames[0])
    data = [rle([be(*p) for row in f for p in row]) for f in frames]
    off = 32 + 12 * len(frames); table = b""; body = b""
    for d in data: table += struct.pack("<IIHH", off + len(body), len(d), 0, 0); body += d
    open(path, "wb").write(b"HCA1" + struct.pack("<HHHBBHHII", w, h, len(frames), 0, 1, 0, 1 if atlas else 0, 32, off + len(body)) + bytes(8) + table + body)
def hca(name, frames, atlas):
    path = f"{tmp}/{name}.hca"
    if enc:
        pngs = []
        for k, f in enumerate(frames):
            pngs.append(f"{tmp}/{name}-{k}.png"); png(pngs[-1], len(f[0]), len(f), f)
        subprocess.run([enc, path, "-q", "--no-dither"] + (["--atlas"] if atlas else []) + pngs, check=True)
    else:
        py_hca(path, frames, atlas)
N = 4
hca("or-deck", [card(-1)] + [card(i) for i in range(N)], True)
hca("or-keys", [tile(160, 34, i) for i in range(N)], True)
hca("or-deck-old", [old_card(-1)] + [old_card(i) for i in range(N)], True)
hca("or-notes", [tile(536, 72, i) for i in range(N)], True)
hca("or-deck-4f", [card(-1)] + [card(i) for i in range(N - 1)], True)
hca("or-keys-26", [tile(160, 26, i) for i in range(N)], True)
hca("or-keys-3", [tile(160, 34, i) for i in range(N - 1)], True)
hca("or-notes-3", [tile(536, 72, i) for i in range(N - 1)], True)
# broken bundles (§5f.2): without the [prompt] section, without card.2.reading, and one over 96 KB
lines = open(bun, "rb").read().split(b"\n")
def without(header):
    k = lines.index(header)
    return b"\n".join(lines[:k] + lines[k + 2:])
open(tmp + "/orb-noprompt.txt", "wb").write(without(b"[prompt]"))
open(tmp + "/orb-nocard2.txt", "wb").write(without(b"[card.2.reading]"))
big = open(bun, "rb").read()
while len(big) <= 96 * 1024: big += b"\n[e2e.padding]\n" + b"padding line for the size limit " * 12
open(tmp + "/orb-big.txt", "wb").write(big)
# no card.<i>.brief lines (§5f.7): no detail screens
out, skip = [], False
for l in lines:
    if skip: skip = False; continue
    if l.startswith(b"[card.") and l.rstrip(b"\r").endswith(b".brief]"): skip = True; continue
    out.append(l)
open(tmp + "/orb-nobrief.txt", "wb").write(b"\n".join(out))
print("hcaenc" if enc else "python RLE16")
PY
info "oracle test assets encoded with $([ -n "$HCAENC" ] && echo hcaenc || echo 'the Python RLE16 fallback (no hcaenc)')"
for pair in "e2e-ord:or-deck" "e2e-ork:or-keys" "e2e-orn:or-notes" "e2e-ord-4f:or-deck-4f" "e2e-ork-26:or-keys-26" "e2e-ork-3:or-keys-3" "e2e-orn-3:or-notes-3" "e2e-ord-old:or-deck-old"; do
    put_asset "${pair%%:*}" "$TMP/${pair#*:}.hca"
    expect 201 "PUT /assets/${pair%%:*} ($(wc -c <"$TMP/${pair#*:}.hca" | tr -d ' ') B)" "j['ok'] is True"
done
req GET /assets
expect 200 "GET /assets: deck / keys / notes are atlases of 108x206 / 160x34 (§5f.12) / 536x72" \
    "(lambda A: A.get('e2e-ord')==(108,206,5,True) and A.get('e2e-ord-old')==(112,214,5,True) and A.get('e2e-ork')==(160,34,4,True) and A.get('e2e-ork-26')==(160,26,4,True) and A.get('e2e-ork-3')==(160,34,3,True) and A.get('e2e-orn')==(536,72,4,True))({a['id']:(a['width'],a['height'],a['frames'],a['atlas']) for a in j['assets']})"
# fonts (the reader section's generated faces, uploaded again: body font e2e-orf with a "large" face (§5f.11), big
# font e2e-orfb with "large": null) and bundles
req DELETE /fonts/e2e-orf; req DELETE /fonts/e2e-orfb
for a in w a cw ca lw la; do
    put_asset "e2e-font-$a" "$TMP/font-$a.hca"
    expect 201 "PUT /assets/e2e-font-$a (reader font atlas for the oracle)" "j['ok'] is True"
done
for bad in "noadv:422:malformed:a large face without advance" "5:422:malformed:large = 5 (not an object)" \
           "noatlas:422:unknown_asset:a large atlas that is not uploaded" "geometry:422:malformed:a large atlas of the wrong cell size (24x40 for 31x52)"; do
    IFS=: read -r bf bc be bd <<<"$bad"
    req PUT /fonts/e2e-orf -H "$JH" --data-binary "@$TMP/font-large-$bf.json"
    expect "$bc" "PUT /fonts with $bd -> $bc $be" "j['error']=='$be'"
done
req PUT /fonts/e2e-orf -H "$JH" --data-binary "@$TMP/font-large.json"
expect 201 "PUT /fonts/e2e-orf (the oracle's body font: normal + compact + large)" "j['ok'] is True and j['id']=='e2e-orf'"
req PUT /fonts/e2e-orfb -H "$JH" --data-binary "@$TMP/font-large-null.json"
expect 201 "PUT /fonts/e2e-orfb (the oracle's big font; \"large\": null = no large face)" "j['ok'] is True and j['id']=='e2e-orfb'"
req GET /fonts
expect 200 "GET /fonts: e2e-orf large true (compact true), e2e-orfb large false" \
    "(lambda F: F['e2e-orf']['large'] is True and F['e2e-orf']['compact'] is True and F['e2e-orfb']['large'] is False)({f['id']: f for f in j['fonts']})"
req GET /fonts/e2e-orf
expect 200 "GET /fonts/e2e-orf round-trips the large face" "j['large']['cell_w']==31 and j['large']['atlas_white']=='e2e-font-lw'"
ORB="e2e-orb-$$"
put_text() { # put_text ID FILE
    req PUT "/texts/$1" -H "X-Content-SHA256: $(sha "$2")" -H 'Content-Type: text/plain; charset=utf-8' --data-binary "@$2"
}
for pair in "$ORB:$ORBUN" "e2e-orb-nop:$TMP/orb-noprompt.txt" "e2e-orb-noc2:$TMP/orb-nocard2.txt" "e2e-orb-big:$TMP/orb-big.txt" "e2e-orb-nobr:$TMP/orb-nobrief.txt"; do
    req DELETE "/texts/${pair%%:*}"
    put_text "${pair%%:*}" "${pair#*:}"
    expect 201 "PUT /texts/${pair%%:*} (bundle $(basename "${pair#*:}"), $(wc -c <"${pair#*:}" | tr -d ' ') B)" "j['ok'] is True"
done
ORA="\"deck\":\"e2e-ord\",\"keys\":\"e2e-ork\",\"cards\":4,\"font\":\"e2e-orf\""   # keys again (§5f.12), no "notes" (§5f.7)
# "mode" and "daily" are accepted and ignored (§5f.6: one reading only)
ORIT="{\"type\":\"oracle\",\"id\":\"$ORB\",$ORA,\"notes\":\"e2e-orn\",\"font_big\":\"e2e-orfb\",\"mode\":\"day\",\"daily\":true,\"face_ms\":0,\"page_ms\":0,\"hold_ms\":0,\"transition\":\"fade\"}"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$ORIT]}"
expect 200 "PUT /playlist with an oracle item (id = the bundle, font + font_big; keys; mode / daily / notes ignored)" "j['ok'] is True"
req GET /playlist
expect 200 "GET /playlist round-trips the oracle item" \
    "j['items'][0]['id']=='$ORB' and j['items'][0]['deck']=='e2e-ord' and j['items'][0]['keys']=='e2e-ork' and j['items'][0]['notes']=='e2e-orn' and j['items'][0]['font']=='e2e-orf' and j['items'][0]['font_big']=='e2e-orfb' and j['items'][0]['cards']==4"
poll_status "j['playlist']['current']=='oracle:$ORB'" 3
expect 200 "oracle item playing -> playlist.current == oracle:<bundle id>" "j['playlist']['current']=='oracle:$ORB'"
expect 200 "status.oracle at rest: {cards 4, waits, -1s, reading ''}; no mode / question / daily_card keys (§5f.6)" \
    "j['oracle']=={'cards':4,'state':'waits','cards_drawn':[-1,-1,-1],'card':-1,'page':-1,'reading':''}"
# Screens (§5f.6, §5f.7, the lean draw): three, lean 0..4 (by card, by position, by the numbers, together, and; one page
# each, a screen without text skipped), detail A · B · C (card.<i>.brief; only for cards that have one), hold; POST
# /oracle/turn = next, POST /oracle/back = previous. The walks keep every response's oracle fields, one JSON line each.
# or_fw START-JSON: turn from the current screen until hold (bounded) -> $TMP/orfw.jsonl (START first)
or_fields="{k: j[k] for k in ('state','cards_drawn','card','page','reading')}"
or_fw() {
    printf '%s\n' "$1" > "$TMP/orfw.jsonl"; local n=0
    while [ $n -lt 20 ]; do
        req POST /oracle/turn; n=$((n + 1))
        [ "$CODE" = 200 ] || return 1
        jjson "$or_fields" >> "$TMP/orfw.jsonl"
        [ "$(jget "j['state']")" = hold ] && return 0
    done
    return 1
}
# or_bw: back from the current screen until waits, then once more (the floor) -> $TMP/orbw.jsonl
or_bw() {
    : > "$TMP/orbw.jsonl"; local n=0
    while [ $n -lt 20 ]; do
        req POST /oracle/back; n=$((n + 1))
        [ "$CODE" = 200 ] || return 1
        jjson "$or_fields" >> "$TMP/orbw.jsonl"
        if [ "$(jget "j['state']")" = waits ]; then
            req POST /oracle/back
            [ "$CODE" = 200 ] && jjson "$or_fields" >> "$TMP/orbw.jsonl"
            return 0
        fi
    done
    return 1
}
case "$CLIP" in *127.0.0.1*|*localhost*) ORMOCK=1 ;; *) ORMOCK=0 ;; esac
# or_walk ROW BUNDLE-FILE -> "True|False <summary>": the forward walk is the lean list for ROW (three and hold carry
# the paragraph; lean screens in increasing order, each with a text of <= 600 B; a detail screen per card of the row
# in order, card = that card, reading = its card.<i>.brief from BUNDLE-FILE, present exactly for the cards that have a
# brief; the mock: all 5 lean screens), and the backward walk retraces it exactly, then waits twice
or_walk() {
    python3 - "$TMP/orfw.jsonl" "$TMP/orbw.jsonl" "$1" "$2" "$ORMOCK" <<'PY' 2>/dev/null | clean 400 | grep . || echo "False (walk check crashed)"
import json, sys
F = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
B = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
row, mock = json.loads(sys.argv[3]), sys.argv[5] == "1"
brief, sec = {}, None
for l in open(sys.argv[4], encoding="utf-8").read().split("\n"):
    l = l.rstrip("\r")
    if l.startswith("[") and l.endswith("]"): sec = l[1:-1]; continue
    if sec and sec.startswith("card.") and sec.endswith(".brief") and l.strip() and len(l.encode()) <= 512:
        brief.setdefault(int(sec.split(".")[1]), l)
why = []
def need(c, m):
    if not c: why.append(m)
key = lambda d: (d["state"], d["card"], d["page"], d["reading"])
para = F[0]["reading"] if F else ""
need(F and F[0]["state"] == "three" and F[0]["card"] == -1 and F[0]["page"] == -1, "start: three")
need(0 < len(para.encode()) <= 900, "three carries the paragraph (<= 900 B)")
need(all(d["cards_drawn"] == row for d in F), "cards_drawn == the row throughout")
i, lean = 1, []
while i < len(F) and F[i]["state"] == "lean":
    d = F[i]
    need(0 <= d["page"] <= 4 and (not lean or d["page"] > lean[-1]) and d["card"] == -1 and 0 < len(d["reading"].encode()) <= 600,
         "lean screens in increasing order, card -1, a text <= 600 B")
    lean.append(d["page"]); i += 1
need(lean, "at least one lean screen")
if mock: need(lean == [0, 1, 2, 3, 4], "mock: all five lean screens")
det = []
while i < len(F) and F[i]["state"] == "detail":
    d = F[i]; s = d["page"]
    need(0 <= s <= 2 and (not det or s > det[-1]) and d["card"] == row[s] and d["reading"] == brief.get(row[s]),
         "detail %d: card %d and its brief" % (s, row[s] if 0 <= s <= 2 else -1))
    det.append(s); i += 1
need(det == [s for s in range(3) if row[s] in brief], "a detail screen exactly for the cards with a brief")
need(i == len(F) - 1 and key(F[i]) == ("hold", -1, -1, para), "hold at the end, with the paragraph")
need([key(d) for d in B] == [key(d) for d in reversed(F[:-1])] + [("waits", -1, -1, "")] * 2, "backward walk = exact reverse, then waits twice")
need(all(d["cards_drawn"] == [-1, -1, -1] for d in B[-2:]), "waits: cards_drawn -1s")
print(("True" if not why else "False") + " lean " + ",".join(map(str, lean)) + "; detail " + (",".join("%d(card %d)" % (s, row[s]) for s in det) or "none") +
      "; paragraph %d B" % len(para.encode()) + ("" if not why else "; FAILED: " + "; ".join(why)))
PY
}
ORREAD="isinstance(j['oracle']['reading'],str) and 0<len(j['oracle']['reading'].encode('utf-8'))<=900"
if [ "${LIVE:-True}" = True ]; then
    req POST /oracle/back
    expect 200 "POST /oracle/back in waits: nothing happens (the floor)" "j['ok'] is True and j['state']=='waits' and j['cards_drawn']==[-1,-1,-1] and j['reading']==''"
    req POST /oracle/draw
    expect 200 "POST /oracle/draw (no body) -> shuffle" "j['ok'] is True and j['state'] in ('shuffle','three')"
    req POST /oracle/back
    expect 200 "POST /oracle/back during the shuffle: nothing changes" "j['ok'] is True and j['state'] in ('shuffle','three')"
    poll_status "j['oracle']['state']=='three'" 5
    expect 200 "three: three distinct cards of 0..3, card -1, page -1, reading = the paragraph" \
        "len(set(j['oracle']['cards_drawn']))==3 and all(0<=c<4 for c in j['oracle']['cards_drawn']) and j['oracle']['card']==-1 and j['oracle']['page']==-1 and $ORREAD"
    req POST /oracle/back
    expect 200 "back in three -> waits" "j['state']=='waits' and j['cards_drawn']==[-1,-1,-1] and j['reading']==''"
    req POST /oracle/draw -H "$JH" -d '{"cards":[2,0,3]}'
    expect 200 "POST /oracle/draw {cards:[2,0,3]} forces the row" "j['ok'] is True and j['state'] in ('shuffle','three')"
    poll_status "j['oracle']['state']=='three'" 5
    expect 200 "forced row: cards_drawn == [2,0,3]" "j['oracle']['cards_drawn']==[2,0,3]"
    or_fw "$(jjson "j['oracle']")"
    expect 200 "forward walk with turns: three, lean screens, details 2 · 0 · 3, hold (the three, the paragraph)" \
        "j['state']=='hold' and j['cards_drawn']==[2,0,3] and j['card']==-1 and j['page']==-1 and len(j['reading'])>0"
    info "paragraph on three / hold: $(jget "len(j['reading'].encode('utf-8'))") B: $(jget "j['reading']" | head -c 140)..."
    or_bw
    ORW=$(or_walk "[2,0,3]" "$ORBUN")
    ORB1=$(python3 -c 'import json,sys; F=[json.loads(l) for l in open(sys.argv[1])]; B=[json.loads(l) for l in open(sys.argv[2])]; print(B[0]["state"]=="detail" and B[0]["page"]==2 and B[0]["card"]==3 and B[0]==F[-2])' "$TMP/orfw.jsonl" "$TMP/orbw.jsonl" 2>/dev/null || echo False)
    expect 200 "back from hold -> detail C (card 3, its brief)" "a[0]=='True'" "$ORB1"
    expect 200 "walks: ${ORW#* }" "a[0].split(' ')[0]=='True'" "$ORW"
    expect 200 "backward walk ends on waits; back on waits stays waits" "j['state']=='waits' and j['cards_drawn']==[-1,-1,-1]"
    req GET /status
    expect 200 "/status.oracle has exactly cards, state, cards_drawn, card, page, reading" \
        "sorted(j['oracle'])==['card','cards','cards_drawn','page','reading','state']"
    # arming (§5f.8): a tap on waits arms, back disarms, a second tap deals
    req POST /oracle/turn
    expect 200 "turn in waits -> armed (no draw yet: cards_drawn -1s, card -1, page -1, reading '')" \
        "j['state']=='armed' and j['cards_drawn']==[-1,-1,-1] and j['card']==-1 and j['page']==-1 and j['reading']==''"
    req GET /status
    expect 200 "status.oracle armed" "j['oracle']=={'cards':4,'state':'armed','cards_drawn':[-1,-1,-1],'card':-1,'page':-1,'reading':''}"
    req POST /oracle/back
    expect 200 "back in armed -> waits (disarmed)" "j['state']=='waits' and j['cards_drawn']==[-1,-1,-1] and j['reading']==''"
    req POST /oracle/turn
    expect 200 "turn in waits -> armed again" "j['state']=='armed'"
    req POST /oracle/turn
    expect 200 "turn in armed deals (shuffle)" "j['state'] in ('shuffle','three')"
    poll_status "j['oracle']['state']=='three'" 5
    expect 200 "dealt from armed: three distinct cards, the paragraph" "len(set(j['oracle']['cards_drawn']))==3 and $ORREAD"
    req POST /oracle/turn
    req POST /oracle/back
    req POST /oracle/back
    expect 200 "lean -> back -> three -> back -> waits" "j['state']=='waits'"
    req POST /oracle/turn
    expect 200 "turn -> armed" "j['state']=='armed'"
    req POST /oracle/draw -H "$JH" -d '{"cards":[3,0,1]}'
    expect 200 "POST /oracle/draw from armed deals the forced row" "j['state'] in ('shuffle','three')"
    poll_status "j['oracle']['state']=='three'" 5
    expect 200 "drawn from armed: cards_drawn [3,0,1]" "j['oracle']['cards_drawn']==[3,0,1]"
    # random draws in a row never repeat the previous set
    ORSETS=""
    for _ in $(seq 1 10); do
        req POST /oracle/draw
        poll_status "j['oracle']['state']=='three'" 5
        ORSETS="$ORSETS $(jget "'-'.join(map(str, sorted(j['oracle']['cards_drawn'])))")"
    done
    ORREP=$(python3 -c 'import sys; s=sys.argv[1].split(); print(sum(1 for a, b in zip(s, s[1:]) if a == b) if len(s) == 10 and all(len(x.split("-")) == 3 for x in s) else -1)' "$ORSETS")
    expect 200 "10 random draws in a row: never the previous draw's set ($ORSETS)" "a[0]=='0'" "$ORREP"
    # a draw on a detail screen restarts from the draw
    for _ in $(seq 1 20); do
        req POST /oracle/turn
        [ "$(jget "j['state']")" = detail ] && break
    done
    expect 200 "turns from three reach detail A" "j['state']=='detail' and j['page']==0 and j['card']==j['cards_drawn'][0] and len(j['reading'])>0"
    req POST /oracle/draw -H "$JH" -d '{"cards":[1,2,3]}'
    expect 200 "POST /oracle/draw on a detail screen restarts from the draw" "j['state'] in ('shuffle','three') and j['card']==-1"
    poll_status "j['oracle']['state']=='three'" 5
    expect 200 "restarted: the forced row [1,2,3], the paragraph again" "j['oracle']['cards_drawn']==[1,2,3] and $ORREAD"
    req POST /oracle/turn
    expect 200 "turn in three -> lean screen (state lean, page = screen, its text, card -1)" \
        "j['state']=='lean' and 0<=j['page']<=4 and ($ORMOCK==0 or j['page']==0) and 0<len(j['reading'].encode('utf-8'))<=600 and j['card']==-1"
    for body in '{"cards":null}' '{"card":2,"question":true}'; do
        req POST /oracle/draw -H "$JH" -d "$body"
        expect 200 "POST /oracle/draw $body -> a random draw (other keys ignored)" "j['ok'] is True and j['state'] in ('shuffle','three')"
    done
    poll_status "j['oracle']['state']=='three'" 5
    req GET /screenshot
    ORPX=$(python3 -c 'import sys,struct; d=open(sys.argv[1],"rb").read(); print(hex(struct.unpack_from(">H", d, (100*536+268)*2)[0]) if len(d)==257280 else "none")' "$TMP/body" 2>/dev/null || echo none)
    info "screenshot inside the centre card on the three: $ORPX"
else
    req POST /oracle/draw
    expect 409 "panel-off session: POST /oracle/draw -> 409 not_showing" "j['error']=='not_showing'"
    req POST /oracle/turn
    expect 409 "panel-off session: POST /oracle/turn -> 409 not_showing" "j['error']=='not_showing'"
    req POST /oracle/back
    expect 409 "panel-off session: POST /oracle/back -> 409 not_showing" "j['error']=='not_showing'"
fi
for bad in '{"cards":[0,1]}' '{"cards":[0,1,2,3]}' '{"cards":[0,0,1]}' '{"cards":[0,1,78]}' '{"cards":[0,1,-1]}' '{"cards":[0,1,1.5]}' \
           '{"cards":[0,1,"2"]}' '{"cards":[0,1,true]}' '{"cards":"0,1,2"}' '{"cards":2}' '{"cards":[0,1,4]}'; do
    req POST /oracle/draw -H "$JH" -d "$bad"
    if [ "${LIVE:-True}" = True ] || [ "$bad" != '{"cards":[0,1,4]}' ]; then
        expect 422 "POST /oracle/draw $bad -> 422 invalid_cards" "j['error']=='invalid_cards'"
    else
        expect 409 "panel-off: POST /oracle/draw $bad (index >= cards) -> 409" "j['error']=='not_showing'"
    fi
done
if [ "${LIVE:-True}" = True ]; then
    # a bundle without brief lines: no detail screens (three, lean screens, hold)
    req POST /show/e2e-orb-nobr -H "$JH" -d "{\"type\":\"oracle\",$ORA,\"hold_ms\":0,\"duration_ms\":120000}"
    expect 200 "POST /show/e2e-orb-nobr (a bundle without card.<i>.brief lines)" "j['ok'] is True"
    poll_status "j['playlist']['current']=='oracle:e2e-orb-nobr' and j['oracle']['state']=='waits'" 3
    req POST /oracle/draw -H "$JH" -d '{"cards":[3,1,0]}'
    poll_status "j['oracle']['state']=='three'" 5
    or_fw "$(jjson "j['oracle']")"
    or_bw
    ORW=$(or_walk "[3,1,0]" "$TMP/orb-nobrief.txt")
    expect 200 "no briefs: no detail screens; walks: ${ORW#* }" "a[0].split(' ')[0]=='True' and 'detail none' in a[0]" "$ORW"
    # cards 3: the only set there is, every time
    req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",\"deck\":\"e2e-ord-4f\",\"keys\":\"e2e-ork-3\",\"cards\":3,\"font\":\"e2e-orf\",\"hold_ms\":0,\"duration_ms\":120000}"
    expect 200 "POST /show/<bundle> with a 3-card oracle body (cards 3: the minimum; no notes)" "j['ok'] is True"
    poll_status "j['oracle']['cards']==3 and j['oracle']['state']=='waits'" 3
    for _ in 1 2; do
        req POST /oracle/draw
        poll_status "j['oracle']['state']=='three'" 5
        expect 200 "cards 3: every draw is {0,1,2}" "sorted(j['oracle']['cards_drawn'])==[0,1,2]"
    done
    req POST /oracle/draw -H "$JH" -d '{"cards":[0,1,3]}'
    expect 422 "cards 3: POST /oracle/draw {cards:[0,1,3]} -> 422 invalid_cards" "j['error']=='invalid_cards'"
    # idle timeout (hold_ms): no input for hold_ms -> waits from any screen, counted from the last input
    req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",$ORA,\"hold_ms\":2500,\"duration_ms\":120000}"
    expect 200 "POST /show/<bundle>: oracle with hold_ms 2500 (the idle timeout)" "j['ok'] is True"
    poll_status "j['oracle']['cards']==4 and j['oracle']['state']=='waits'" 3
    req POST /oracle/draw -H "$JH" -d '{"cards":[0,1,2]}'
    poll_status "j['oracle']['state']=='three'" 5
    expect 200 "idle timeout: on the three" "j['oracle']['state']=='three'"
    poll_status "j['oracle']['state']=='waits'" 4
    expect 200 "idle timeout: no input for hold_ms 2500 -> back to waits by itself" "j['oracle']['state']=='waits' and j['oracle']['cards_drawn']==[-1,-1,-1]"
    req POST /oracle/draw -H "$JH" -d '{"cards":[0,1,2]}'
    poll_status "j['oracle']['state']=='three'" 5
    req POST /oracle/turn
    expect 200 "idle timeout: turn from three -> a lean screen (an input: the timer restarts)" "j['state']=='lean'"
    sleep 1.5
    req POST /oracle/back
    expect 200 "idle timeout: 1.5 s later a back -> three (the timer restarts again)" "j['state']=='three'"
    sleep 1.5
    req GET /status
    expect 200 "idle timeout: 3 s after the turn, 1.5 s after the back: still three (counted from the last input)" "j['oracle']['state']=='three'"
    poll_status "j['oracle']['state']=='waits'" 4
    expect 200 "idle timeout: then waits, hold_ms after the back" "j['oracle']['state']=='waits'"
    # arming times out like every screen: armed -> waits after hold_ms (the item above: hold_ms 2500)
    req POST /oracle/turn
    expect 200 "hold_ms 2500: turn on waits -> armed" "j['state']=='armed'"
    poll_status "j['oracle']['state']=='waits'" 4
    expect 200 "hold_ms 2500: armed times out to waits" "j['oracle']['state']=='waits'"
    # shakes (§5f.8): only on armed they deal; on waits and from shuffle through hold they are ignored. The shake is
    # injected with POST /bench/shake, a mock-only route (a real clip answers 404: shake it by hand there)
    req POST /bench/shake -H "$JH" -d '{"g":1.5}'
    if [ "$CODE" = 404 ]; then
        info "no POST /bench/shake on this clip: shake checks skipped (by hand: waits ignores a shake, armed deals)"
    else
        expect 200 "shake on waits: nothing happens" "j['state']=='waits' and j['cards_drawn']==[-1,-1,-1]"
        req POST /oracle/turn
        req POST /bench/shake -H "$JH" -d '{"g":0.5}'
        expect 200 "armed + a shake below shake_g (0.5 < 0.9): still armed" "j['state']=='armed'"
        req POST /bench/shake -H "$JH" -d '{"g":1.5}'
        expect 200 "armed + shake -> deals (shuffle)" "j['state']=='shuffle'"
        poll_status "j['oracle']['state']=='three'" 5
        for step in three lean detail hold; do
            if [ "$step" != three ]; then
                for _ in $(seq 1 12); do
                    req POST /oracle/turn
                    [ "$(jget "j['state']")" = "$step" ] && break
                done
            fi
            req GET /status
            ORSKB=$(jjson "[j['oracle']['state'], j['oracle']['page'], j['oracle']['card'], j['oracle']['cards_drawn'], j['oracle']['reading']]")
            req POST /bench/shake -H "$JH" -d '{"g":2.0}'
            expect 200 "shake on $step: ignored (state, page, card, cards_drawn, reading unchanged)" \
                "j['state']==a[0] and [j['state'], j['page'], j['card'], j['cards_drawn'], j['reading']]==json.loads(a[1])" "$step" "$ORSKB"
        done
        req POST /oracle/turn
        expect 200 "turn in hold -> waits" "j['state']=='waits'"
    fi
    # no interruptions while a draw is in progress (§5f.8): the item's end (duration_ms) waits for waits
    req POST /next
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"oracle\",\"id\":\"$ORB\",$ORA,\"hold_ms\":0,\"duration_ms\":3000},{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":3000}]}"
    expect 200 "PUT /playlist: oracle (duration_ms 3000) + gradient (3000) rotating" "j['ok'] is True"
    poll_status "j['playlist']['current']=='oracle:$ORB'" 3
    req POST /oracle/draw -H "$JH" -d '{"cards":[0,1,2]}'
    expect 200 "draw at once on the rotating oracle" "j['ok'] is True"
    poll_status "j['oracle']['state']=='three'" 5
    req POST /oracle/turn
    expect 200 "on a lean screen" "j['state']=='lean'"
    sleep 4
    req GET /status
    expect 200 "past its duration_ms during the draw: still the oracle, still on the lean screen" \
        "j['playlist']['current']=='oracle:$ORB' and j['oracle']['state']=='lean'"
    req POST /oracle/back
    req POST /oracle/back
    expect 200 "back to waits (lean -> three -> waits)" "j['state']=='waits'"
    poll_status "j['playlist']['current']=='gradient'" 3
    expect 200 "back at waits: the deferred end fires at once -> the rotation moves on to gradient" "j['playlist']['current']=='gradient'"
    # a queue entry due mid-draw waits for waits, then starts
    req GET /status
    ORQAT=$(jint "j['time']['epoch']") || { fail "status.time.epoch is not an integer"; ORQAT=$(date +%s); }
    ORQAT=$(( ORQAT + 3 ))
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"oracle\",\"id\":\"$ORB\",$ORA,\"hold_ms\":0}],\"queue\":[{\"id\":\"e2e-qdef\",\"at\":$ORQAT,\"type\":\"asset\",\"asset\":\"gradient\",\"duration_ms\":5000}]}"
    expect 200 "PUT /playlist: a lone oracle + a queue entry due in 3 s (clip clock)" "j['ok'] is True"
    poll_status "j['playlist']['current']=='oracle:$ORB'" 3
    req POST /oracle/draw -H "$JH" -d '{"cards":[2,3,0]}'
    poll_status "j['oracle']['state']=='three'" 5
    expect 200 "a draw in progress (three)" "j['oracle']['state']=='three'"
    sleep 4
    req GET /status
    expect 200 "the queue entry came due during the draw: not started (current oracle, queue.active null, 1 pending)" \
        "j['playlist']['current']=='oracle:$ORB' and j['queue']['active'] is None and j['queue']['pending']==1 and j['oracle']['state']=='three'"
    req POST /oracle/back
    expect 200 "back in three -> waits" "j['state']=='waits'"
    poll_status "j['queue']['active']=='e2e-qdef'" 3
    expect 200 "back at waits: the deferred queue entry starts at once (current gradient, queue.active e2e-qdef)" \
        "j['queue']['active']=='e2e-qdef' and j['playlist']['current']=='gradient' and j['queue']['pending']==0"
    req POST /next
    # defaults (§5f.3): face_ms / page_ms 0 -> nothing advances by itself
    req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",$ORA,\"duration_ms\":120000}"
    expect 200 "POST /show/<bundle>: oracle with the default timers" "j['ok'] is True"
    poll_status "j['oracle']['state']=='waits'" 3
    req POST /oracle/draw -H "$JH" -d '{"cards":[3,2,1]}'
    poll_status "j['oracle']['state']=='three'" 5
    sleep 2
    req GET /status
    expect 200 "default face_ms 0: still on the three 2 s later (no auto-advance)" "j['oracle']['state']=='three' and j['oracle']['cards_drawn']==[3,2,1]"
    # a non-zero face_ms still advances by itself
    req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",$ORA,\"face_ms\":800,\"hold_ms\":0,\"duration_ms\":120000}"
    expect 200 "POST /show/<bundle>: oracle with face_ms 800" "j['ok'] is True"
    poll_status "j['oracle']['state']=='waits'" 3
    req POST /oracle/draw -H "$JH" -d '{"cards":[2,1,0]}'
    poll_status "j['oracle']['state']=='lean'" 5
    expect 200 "face_ms 800: the three turns to lean screen 0 by itself (page_ms 0: it stays there)" \
        "j['oracle']['state']=='lean' and ($ORMOCK==0 or j['oracle']['page']==0) and 0<len(j['oracle']['reading'].encode('utf-8'))<=600 and j['oracle']['card']==-1"
fi
req POST /next
# /show of the bundle without a body borrows its playlist item; a text no oracle uses is not showable
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000},{\"type\":\"oracle\",\"id\":\"$ORB\",$ORA,\"duration_ms\":8000}]}"
expect 200 "PUT /playlist gradient + oracle (timers at their defaults)" "j['ok'] is True"
req POST /show/$ORB -H "$JH" -d '{"duration_ms":20000}'
expect 200 "POST /show/<bundle> without a body" "j['ok'] is True"
poll_status "j['playlist']['current']=='oracle:$ORB'" 3
expect 200 "shown bundle borrows its playlist item -> current oracle:<bundle id>, 4 cards" \
    "j['playlist']['current']=='oracle:$ORB' and j['oracle']['cards']==4"
req POST /next
req POST /show/e2e-orb-nop -H "$JH" -d '{"duration_ms":20000}'
expect 404 "POST /show/<a text no oracle uses> without a body -> 404 unknown_asset" "j['error']=='unknown_asset'"
# not showing
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":8000}]}'
expect 200 "PUT /playlist back to gradient only" "j['ok'] is True"
poll_status "j['playlist']['current']=='gradient'" 3
req POST /oracle/draw
expect 409 "no oracle on screen: POST /oracle/draw -> 409 not_showing" "j['error']=='not_showing'"
req POST /oracle/turn
expect 409 "no oracle on screen: POST /oracle/turn -> 409 not_showing" "j['error']=='not_showing'"
req POST /oracle/back
expect 409 "no oracle on screen: POST /oracle/back -> 409 not_showing" "j['error']=='not_showing'"
req POST /show/$ORB -H "$JH" -d '{"duration_ms":20000}'
expect 404 "POST /show/<bundle> without a body once no oracle uses it -> 404 unknown_asset" "j['error']=='unknown_asset'"
req GET /status
expect 200 "status.oracle without an oracle: cards 0, waits, -1s, reading ''" \
    "j['oracle']=={'cards':0,'state':'waits','cards_drawn':[-1,-1,-1],'card':-1,'page':-1,'reading':''}"
# queue entry ("asset" names the bundle)
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000}],\"queue\":[{\"id\":\"e2e-qor\",\"at\":$AT,\"type\":\"oracle\",\"asset\":\"$ORB\",$ORA,\"duration_ms\":30000}]}"
expect 200 "PUT /playlist with an oracle queue entry" "j['ok'] is True"
req POST /queue/test -H "$JH" -d '{"id":"e2e-qor"}'
poll_status "j['playlist']['current']=='oracle:$ORB'" 3
expect 200 "oracle queue entry -> current oracle:<bundle id>" "j['playlist']['current']=='oracle:$ORB' and j['queue']['active']=='e2e-qor'"
req POST /next
# invalid items -> 422
orbad() { # orbad DESC ERROR ITEM-JSON
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[$3]}"
    expect 422 "$1 -> 422 $2" "j['error']=='$2'"
}
OB="\"type\":\"oracle\",\"id\":\"$ORB\""
ORF="\"font\":\"e2e-orf\""
orbad "oracle id not a valid id" invalid_playlist "{\"type\":\"oracle\",\"id\":\"Bad_Bundle\",$ORA}"
orbad "oracle without an id" invalid_playlist "{\"type\":\"oracle\",$ORA}"
orbad "oracle without a deck" invalid_playlist "{$OB,\"keys\":\"e2e-ork\",\"notes\":\"e2e-orn\",\"cards\":4,$ORF}"
orbad "oracle unknown deck" unknown_asset "{$OB,\"deck\":\"no-such-deck\",\"keys\":\"e2e-ork\",\"notes\":\"e2e-orn\",\"cards\":4,$ORF}"
orbad "oracle deck with 4 frames (cards 4 needs 5)" invalid_playlist "{$OB,\"deck\":\"e2e-ord-4f\",\"keys\":\"e2e-ork\",\"notes\":\"e2e-orn\",\"cards\":4,$ORF}"
orbad "oracle deck 112x214 (§5f.12: 108x206)" invalid_playlist "{$OB,\"deck\":\"e2e-ord-old\",\"cards\":4,$ORF}"
orbad "oracle deck = the keys atlas (160x34)" invalid_playlist "{$OB,\"deck\":\"e2e-ork\",\"cards\":4,$ORF}"
ORKN="\"keys\":\"e2e-ork\",\"notes\":\"e2e-orn\""
orbad "oracle deck = gradient (not an atlas)" invalid_playlist "{$OB,\"deck\":\"gradient\",$ORKN,\"cards\":4,$ORF}"
orbad "oracle cards 3 with 4-card atlases (frame counts)" invalid_playlist "{$OB,\"deck\":\"e2e-ord\",$ORKN,\"cards\":3,$ORF}"
orbad "oracle cards 2 (three distinct cards are drawn)" invalid_playlist "{$OB,\"deck\":\"e2e-ord\",$ORKN,\"cards\":2,$ORF}"
orbad "oracle cards 0" invalid_playlist "{$OB,\"deck\":\"e2e-ord\",$ORKN,\"cards\":0,$ORF}"
orbad "oracle cards 79" invalid_playlist "{$OB,\"deck\":\"e2e-ord\",$ORKN,\"cards\":79,$ORF}"
orbad "oracle cards 3.5" invalid_playlist "{$OB,\"deck\":\"e2e-ord\",$ORKN,\"cards\":3.5,$ORF}"
orbad "oracle without cards" invalid_playlist "{$OB,\"deck\":\"e2e-ord\",$ORKN,$ORF}"
for ign in '"mode":"day"' '"mode":"bogus"' '"mode":5' '"daily":false' '"daily":"yes"' '"pages":0'; do
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{$OB,$ORA,$ign}]}"
    expect 200 "oracle with $ign: accepted and ignored (§5f.6)" "j['ok'] is True"
done
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{$OB,\"deck\":\"e2e-ord-4f\",\"keys\":\"e2e-ork-3\",\"notes\":\"e2e-orn-3\",\"cards\":3,$ORF}]}"
expect 200 "oracle with cards 3 (deck 4 frames, keys 3): accepted" "j['ok'] is True"
# "keys" (§5f.12): optional; when present a 160x34 atlas with exactly `cards` frames (160x26 -> 422)
OAD="\"deck\":\"e2e-ord\",\"cards\":4,$ORF"
for kb in ':200:' '"e2e-ork":200:' '"e2e-ork-26":422:invalid_playlist' '"e2e-ork-3":422:invalid_playlist' '"e2e-ord":422:invalid_playlist' \
          '"no-such-keys":422:unknown_asset' '"Bad_Id!":422:invalid_playlist' '5:422:invalid_playlist' 'null:422:invalid_playlist'; do
    IFS=: read -r kv kc ke <<<"$kb"
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{$OB,$OAD${kv:+,\"keys\":$kv}}]}"
    if [ "$kc" = 200 ]; then expect 200 "oracle with keys ${kv:-absent}: accepted" "j['ok'] is True"
    else expect 422 "oracle with keys $kv -> 422 $ke" "j['error']=='$ke'"; fi
done
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{$OB,\"deck\":\"e2e-ord\",\"cards\":4,\"mode\":\"day\",$ORF}]}"
expect 200 "oracle with only deck, cards, font (and an ignored mode): accepted" "j['ok'] is True"
# "notes" (§5f.7): accepted and ignored: not required, not validated, not checked
for nb in '' ',"notes":"e2e-orn"' ',"notes":"e2e-ork-26"' ',"notes":"no-such-notes"' ',"notes":"Bad_Id!"' ',"notes":5' ',"notes":null'; do
    req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{$OB,$ORA$nb}]}"
    expect 200 "oracle with notes ${nb:-absent}: accepted and ignored" "j['ok'] is True"
done
orbad "oracle shake_g 0.3" invalid_playlist "{$OB,$ORA,\"shake_g\":0.3}"
orbad "oracle shake_g 2.1" invalid_playlist "{$OB,$ORA,\"shake_g\":2.1}"
orbad "oracle face_ms -1" invalid_playlist "{$OB,$ORA,\"face_ms\":-1}"
orbad "oracle page_ms 1.5" invalid_playlist "{$OB,$ORA,\"page_ms\":1.5}"
orbad "oracle hold_ms 86400001" invalid_playlist "{$OB,$ORA,\"hold_ms\":86400001}"
# §5f.2: fonts, reader, bundle
OAK="\"deck\":\"e2e-ord\",\"keys\":\"e2e-ork\",\"notes\":\"e2e-orn\",\"cards\":4"
orbad "oracle without a font" invalid_playlist "{$OB,$OAK}"
orbad "oracle font not a string" invalid_playlist "{$OB,$OAK,\"font\":5}"
orbad "oracle font id invalid" invalid_playlist "{$OB,$OAK,\"font\":\"Bad_Font\"}"
orbad "oracle font_big id invalid" invalid_playlist "{$OB,$ORA,\"font_big\":\"Bad_Font\"}"
orbad "oracle font_big null" invalid_playlist "{$OB,$ORA,\"font_big\":null}"
orbad "oracle unknown font" unknown_font "{$OB,$OAK,\"font\":\"no-such-font\"}"
orbad "oracle unknown font_big" unknown_font "{$OB,$ORA,\"font_big\":\"no-such-font\"}"
orbad "oracle reader != id" invalid_playlist "{$OB,$ORA,\"reader\":\"e2e-orb-nop\"}"
orbad "oracle reader not a string" invalid_playlist "{$OB,$ORA,\"reader\":5}"
orbad "oracle unknown bundle" unknown_text "{\"type\":\"oracle\",\"id\":\"no-such-bundle\",$ORA}"
orbad "oracle bundle without a [prompt] line" invalid_playlist "{\"type\":\"oracle\",\"id\":\"e2e-orb-nop\",$ORA}"
orbad "oracle bundle without card.2.reading (cards 4)" invalid_playlist "{\"type\":\"oracle\",\"id\":\"e2e-orb-noc2\",$ORA}"
orbad "oracle bundle over 96 KB" invalid_playlist "{\"type\":\"oracle\",\"id\":\"e2e-orb-big\",$ORA}"
orbad "oracle order: a missing font before an unknown bundle" invalid_playlist "{\"type\":\"oracle\",\"id\":\"no-such-bundle\",$OAK}"
orbad "oracle order: unknown bundle before unknown font and deck" unknown_text "{\"type\":\"oracle\",\"id\":\"no-such-bundle\",\"deck\":\"no-such-deck\",$ORKN,\"cards\":4,\"font\":\"no-such-font\"}"
orbad "oracle order: unknown font before unknown deck" unknown_font "{$OB,\"deck\":\"no-such-deck\",$ORKN,\"cards\":4,\"font\":\"no-such-font\"}"
orbad "oracle order: unknown deck before a broken bundle" unknown_asset "{\"type\":\"oracle\",\"id\":\"e2e-orb-nop\",\"deck\":\"no-such-deck\",$ORKN,\"cards\":4,$ORF}"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{$OB,$ORA,\"reader\":\"$ORB\",\"pages\":7}]}"
expect 200 "oracle with reader == id and an ignored \"pages\" (even out of range): accepted" "j['ok'] is True"
req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",\"deck\":\"e2e-ord-4f\",$ORKN,\"cards\":4,$ORF}"
expect 422 "POST /show with an oracle body whose deck does not fit -> 422 invalid_item" "j['error']=='invalid_item'"
req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",\"deck\":\"no-such-deck\",$ORKN,\"cards\":4,$ORF}"
expect 404 "POST /show with an oracle body naming an unknown deck -> 404 unknown_asset" "j['error']=='unknown_asset'"
req POST /show/no-such-bundle -H "$JH" -d "{\"type\":\"oracle\",$ORA}"
expect 422 "POST /show/<unknown bundle> with an oracle body -> 422 invalid_item" "j['error']=='invalid_item'"
req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",\"deck\":\"e2e-ord\",$ORKN,\"cards\":4}"
expect 422 "POST /show with an oracle body without a font -> 422 invalid_item" "j['error']=='invalid_item'"
req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",\"deck\":\"e2e-ord-old\",\"cards\":4,$ORF}"
expect 422 "POST /show with an oracle body whose deck is 112x214 -> 422 invalid_item" "j['error']=='invalid_item'"
req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",\"deck\":\"e2e-ord\",\"cards\":4,$ORF,\"duration_ms\":5000}"
expect 200 "POST /show with an oracle body without keys / notes (keys optional, §5f.12): accepted" "j['ok'] is True"
req POST /next
req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",\"deck\":\"e2e-ord\",\"keys\":\"no-such-keys\",\"cards\":4,$ORF}"
expect 404 "POST /show with an oracle body naming unknown keys -> 404 unknown_asset" "j['error']=='unknown_asset'"
req POST /show/$ORB -H "$JH" -d "{\"type\":\"oracle\",\"deck\":\"e2e-ord\",\"keys\":\"e2e-ork-26\",\"cards\":4,$ORF}"
expect 422 "POST /show with an oracle body whose keys are 160x26 (the old size) -> 422 invalid_item" "j['error']=='invalid_item'"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{$OB,$ORA,\"shake_g\":2.0,\"face_ms\":0,\"page_ms\":86400000,\"hold_ms\":0}]}"
expect 200 "oracle with shake_g 2.0 and timers at their bounds: accepted" "j['ok'] is True"
# deletes: the big font and the (ignored) notes asset keep the item; the body font, the bundle, the deck and the keys
# remove it
ORDEL="{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000},{$OB,$ORA}],\"queue\":[{\"id\":\"e2e-qor\",\"at\":$AT,\"type\":\"oracle\",\"asset\":\"$ORB\",$ORA}]}"
ORDELB="{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000},{$OB,$ORA,\"font_big\":\"e2e-orfb\"}],\"queue\":[{\"id\":\"e2e-qor\",\"at\":$AT,\"type\":\"oracle\",\"asset\":\"$ORB\",$ORA}]}"
NOORC="not [i for i in j['items'] if i.get('type')=='oracle'] and not [e for e in j.get('queue',[]) if e.get('type')=='oracle'] and j['items'][0]['id']=='gradient'"
req PUT /playlist -H "$JH" -d "$ORDELB"
expect 200 "PUT /playlist gradient + oracle (font_big) + oracle queue entry" "j['ok'] is True"
req DELETE /fonts/e2e-orfb
expect 200 "DELETE /fonts/e2e-orfb (the big font)" "j['ok'] is True"
req GET /playlist
expect 200 "deleting font_big keeps the oracle item and queue entry" \
    "[i['id'] for i in j['items'] if i.get('type')=='oracle']==['$ORB'] and [e['id'] for e in j['queue']]==['e2e-qor']"
req DELETE /fonts/e2e-orf
expect 200 "DELETE /fonts/e2e-orf (the body font)" "j['ok'] is True"
req GET /playlist
expect 200 "deleting the body font removed the oracle item and queue entry" "$NOORC"
req PUT /fonts/e2e-orf -H "$JH" --data-binary "@$TMP/font-large.json"
expect 201 "PUT /fonts/e2e-orf again" "j['ok'] is True"
req PUT /playlist -H "$JH" -d "$ORDEL"
expect 200 "PUT /playlist gradient + oracle + oracle queue entry again" "j['ok'] is True"
req DELETE /texts/$ORB
expect 200 "DELETE /texts/<bundle>" "j['ok'] is True"
req GET /playlist
expect 200 "deleting the bundle removed the oracle item and queue entry" "$NOORC"
put_text "$ORB" "$ORBUN"
expect 201 "PUT /texts/<bundle> again" "j['ok'] is True"
ORDELN="{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000},{$OB,$ORA,\"notes\":\"e2e-orn\"}],\"queue\":[{\"id\":\"e2e-qor\",\"at\":$AT,\"type\":\"oracle\",\"asset\":\"$ORB\",$ORA,\"notes\":\"e2e-orn\"}]}"
req PUT /playlist -H "$JH" -d "$ORDELN"
expect 200 "PUT /playlist gradient + oracle naming notes e2e-orn + oracle queue entry" "j['ok'] is True"
for a in e2e-orn:notes:§5f.7; do
    req DELETE "/assets/${a%%:*}"
    expect 200 "DELETE /assets/${a%%:*} (the ignored $(echo "$a" | cut -d: -f2) asset)" "j['ok'] is True"
    req GET /playlist
    expect 200 "deleting the $(echo "$a" | cut -d: -f2) asset keeps the oracle item and queue entry ($(echo "$a" | cut -d: -f3))" \
        "[i['id'] for i in j['items'] if i.get('type')=='oracle']==['$ORB'] and [e['id'] for e in j['queue']]==['e2e-qor']"
done
for a in e2e-ord e2e-ork; do
    req PUT /playlist -H "$JH" -d "$ORDEL"
    req DELETE "/assets/$a"
    expect 200 "DELETE /assets/$a (oracle test asset)" "j['ok'] is True"
    req GET /playlist
    expect 200 "deleting $a removed the oracle item and queue entry using it" "$NOORC"
    [ $a = e2e-ord ] && { put_asset e2e-ord "$TMP/or-deck.hca"; expect 201 "PUT /assets/e2e-ord again" "j['ok'] is True"; }
    [ $a = e2e-ork ] && { put_asset e2e-ork "$TMP/or-keys.hca"; expect 201 "PUT /assets/e2e-ork again" "j['ok'] is True"; }
done
# cleanup
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"asset","id":"gradient","duration_ms":8000}]}'
expect 200 "PUT /playlist back to gradient only (oracle done)" "j['ok'] is True"
for id in e2e-ord e2e-ork e2e-ord-4f e2e-ork-26 e2e-ork-3 e2e-orn-3 e2e-ord-old; do
    req DELETE "/assets/$id"; expect 200 "DELETE /assets/$id (oracle test asset)" "j['ok'] is True"
done
for id in "$ORB" e2e-orb-nop e2e-orb-noc2 e2e-orb-big e2e-orb-nobr; do
    req DELETE "/texts/$id"; expect 200 "DELETE /texts/$id (oracle bundle)" "j['ok'] is True"
done
req DELETE /fonts/e2e-orf
expect 200 "DELETE /fonts/e2e-orf" "j['ok'] is True"
for a in w a cw ca lw la; do req DELETE "/assets/e2e-font-$a"; done
expect 200 "oracle font atlases deleted" "j['ok'] is True"

echo "== playlist restored"
req PUT /playlist -H "$JH" -d "$PL"
expect 200 "PUT /playlist back to gradient + anim12 + sand" "j['ok'] is True"
for id in e2e-strip e2e-strip-raw; do
    req DELETE "/assets/$id"; expect 200 "DELETE /assets/$id (test strip)" "j['ok'] is True"
done

echo "== firmware update permission (GET /ota, POST /ota/ask, 403 press_button)"
# PROTOCOL §4 "Firmware update": an image is only taken after a short press on the clip while it asks. The refusal
# below starts the asking window on a real clip too ("Update?" on its screen for 60 s; the session end clears it).
case "$CLIP" in *127.0.0.1*|*localhost*) OTAMOCK=1 ;; *) OTAMOCK=0 ;; esac
OTA_KEYS="set(j)=={'ok','allowed','asking','seconds_left'} and all(isinstance(j[k],bool) for k in ('ok','allowed','asking')) and isinstance(j['seconds_left'],int) and not isinstance(j['seconds_left'],bool)"
req GET /ota
expect 200 "GET /ota: ok / allowed / asking / seconds_left" "$OTA_KEYS and not (j['allowed'] and j['asking']) and (j['seconds_left']==0)==(not j['allowed'] and not j['asking'])"
OTA_WAS_ALLOWED=$(jbool "j['allowed']") || OTA_WAS_ALLOWED=False
printf 'not a firmware image\n' >"$TMP/fake.bin"
FAKE_SHA=$(sha "$TMP/fake.bin")
req POST /ota -H 'Content-Type: application/octet-stream' --data-binary "@$TMP/fake.bin"
expect 400 "POST /ota without X-Content-SHA256 -> 400 missing_sha256 (checked before the permission)" "j['error']=='missing_sha256'"
req POST /ota -H "X-Content-SHA256: $FAKE_SHA" -H 'Content-Type: application/octet-stream' --data-binary ''
expect 411 "POST /ota with an empty body -> 411 empty_body (checked before the permission)" "j['error']=='empty_body'"
if [ "$OTA_WAS_ALLOWED" = True ]; then
    info "updates are already allowed on this clip (someone pressed the button): the refusal checks are skipped"
else
    req POST /ota -H "X-Content-SHA256: $FAKE_SHA" -H 'Content-Type: application/octet-stream' --data-binary "@$TMP/fake.bin"
    expect 403 "POST /ota without the button -> 403 press_button" "j['ok'] is False and j['error']=='press_button' and isinstance(j.get('message'),str)"
    req GET /ota
    expect 200 "the refused POST /ota started the asking window" "$OTA_KEYS and j['asking'] is True and j['allowed'] is False and 50<=j['seconds_left']<=60"
fi
req POST /ota/ask
expect 200 "POST /ota/ask: asking (or still allowed), same keys as GET /ota" \
    "$OTA_KEYS and (j['asking'] or j['allowed']) and (j['allowed'] or 58<=j['seconds_left']<=60)"
if [ "$OTAMOCK" = 1 ]; then
    # The button, through the mock-only POST /bench/button (the clip has no such route: 404 there).
    req POST /bench/button
    expect 200 "mock button press while asking: used, allowed for 120 s" "j['used'] is True and j['allowed'] is True and j['asking'] is False and 115<=j['seconds_left']<=120"
    req POST /bench/button
    expect 200 "a second press while allowed is not used (keeps its normal meaning)" "j['used'] is False and j['allowed'] is True"
    req POST /ota/ask
    expect 200 "POST /ota/ask while allowed changes nothing" "j['allowed'] is True and j['asking'] is False and 110<=j['seconds_left']<=120"
    req POST /ota -H "X-Content-SHA256: $(printf '0%.0s' $(seq 1 64))" -H 'Content-Type: application/octet-stream' --data-binary "@$TMP/fake.bin"
    expect 422 "allowed, wrong hash -> 422 sha256_mismatch" "j['error']=='sha256_mismatch'"
    req GET /ota
    expect 200 "a failed upload keeps the permission" "j['allowed'] is True"
    printf '\351mock image for the e2e\n' >"$TMP/fake-img.bin"
    req POST /ota -H "X-Content-SHA256: $(sha "$TMP/fake-img.bin")" -H 'Content-Type: application/octet-stream' --data-binary "@$TMP/fake-img.bin"
    expect 200 "allowed, a valid image -> 200 (the mock installs nothing)" "j['ok'] is True"
    req GET /ota
    expect 200 "an accepted image ends the permission" "j['allowed'] is False and j['asking'] is False and j['seconds_left']==0"
    req POST /bench/button
    expect 200 "a press while idle is not used" "j['used'] is False and j['allowed'] is False"
    req POST /ota/ask; req POST /bench/button
    expect 200 "ask, press: allowed again" "j['allowed'] is True"
    req POST /session/end
    expect 200 "POST /session/end" "j['ok'] is True"
    req GET /ota
    expect 200 "the session end ends the permission" "j['allowed'] is False and j['asking'] is False"
else
    info "real clip: the press itself is checked with E2E_OTA=1 (you press the button when asked)"
fi

echo "== errors"
req GET /no-such-endpoint
expect 404 "unknown path -> 404 JSON" "j['ok'] is False and j['error']=='not_found'"
# the Magic 8 Ball is gone (PROTOCOL §5e): its item type, route and status key
req PUT /playlist -H "$JH" -d '{"version":1,"items":[{"type":"eightball","id":"gradient","window":{"x":268,"y":40,"w":200,"h":180}}]}'
expect 422 "eightball playlist item (removed) -> 422 invalid_playlist" "j['error']=='invalid_playlist'"
req PUT /playlist -H "$JH" -d "{\"version\":1,\"items\":[{\"type\":\"asset\",\"id\":\"gradient\",\"duration_ms\":8000}],\"queue\":[{\"id\":\"e2e-qeb\",\"at\":$AT,\"type\":\"eightball\",\"asset\":\"gradient\",\"window\":{\"x\":268,\"y\":40,\"w\":200,\"h\":180}}]}"
expect 422 "eightball queue entry (removed) -> 422 invalid_playlist" "j['error']=='invalid_playlist'"
req POST /show/gradient -H "$JH" -d '{"type":"eightball","window":{"x":268,"y":40,"w":200,"h":180}}'
expect 422 "POST /show with an eightball body (removed) -> 422 invalid_item" "j['error']=='invalid_item'"
req POST /eightball/shake -H "$JH" -d '{}'
expect 404 "POST /eightball/shake (removed) -> 404 not_found" "j['ok'] is False and j['error']=='not_found'"
req GET /status
expect 200 "/status has no eightball key, playlist.current is not eightball:" \
    "'eightball' not in j and not str(j['playlist']['current']).startswith('eightball:')"

if [ -n "${E2E_OTA:-}" ]; then
    echo "== OTA (clip reboots afterwards)"
    BIN="$FW/build/pixelclip.bin"
    # The update needs a short press on the clip while it asks (PROTOCOL §4 "Firmware update").
    req POST /ota/ask
    expect 200 "POST /ota/ask" "j['ok'] is True"
    [ "$OTAMOCK" = 1 ] && req POST /bench/button   # the mock's stand-in for the press
    req GET /ota
    if [ "$(jbool "j['allowed']")" != True ]; then
        echo "   >>> The clip shows \"Update?\": press its button once (a short press). Waiting up to 60 s..."
        end=$(( $(date +%s) + 62 ))
        while [ "$(date +%s)" -lt "$end" ]; do
            sleep 1
            req GET /ota
            [ "$CODE" = 200 ] && [ "$(jbool "j['allowed']")" = True ] && break
        done
    fi
    if expect 200 "GET /ota: updates allowed by the button" "j['allowed'] is True"; then
        req POST /ota -H "X-Content-SHA256: $(sha "$BIN")" -H 'Content-Type: application/octet-stream' --data-binary "@$BIN"
        expect 200 "POST /ota $(wc -c <"$BIN" | tr -d ' ') B" "j['ok'] is True"
    else
        info "no press within 60 s: the update was not sent"
    fi
    KEEP_SESSION=1
fi

if [ -z "${KEEP_SESSION:-}" ]; then
    echo "== session end"
    req POST /session/end
    expect 200 "POST /session/end" "j['ok'] is True"
    if [ "${O_AON:-False}" = True ]; then
        info "wifi_always_on is set on this clip: /session/end keeps the hotspot up (long press to end it)"
        SKIP_GONE=1
    fi
    gone=0
    for _ in $(seq 1 10); do
        sleep 1
        if ! curl -s -m 2 -o /dev/null "$CLIP/status"; then gone=1; break; fi
    done
    if [ -n "${SKIP_WIFI:-}" ]; then info "SKIP_WIFI: not checking that the AP went away"
    elif [ -n "${SKIP_GONE:-}" ]; then info "always-on: not checking that the AP went away"
    elif [ "$gone" = 1 ]; then pass "AP gone after /session/end (connection dot gone; panel-off sessions show 'Done', then the playlist)"
    else fail "clip still answers 10 s after /session/end"; fi
fi

echo
echo "RESULT: $([ "$FAILS" -eq 0 ] && echo PASS || echo FAIL) ($PASSES passed, $FAILS failed)"
[ "$FAILS" -eq 0 ]
