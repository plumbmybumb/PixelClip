#!/usr/bin/env bash
# sleep_soak.sh [MINUTES] [PORT] — light-sleep soak of the bench build (README "Light sleep on battery").
#
# Flashes nothing. Flash the bench build first (BENCH=1 scripts/flash.sh), leave the board on USB, then:
#
#   scripts/sleep_soak.sh 60                       # 60 minutes, port autodetected (/dev/cu.usbmodem*)
#   scripts/sleep_soak.sh 120 /dev/cu.usbmodem101
#   ANALYZE=firmware/sleep_soak.log scripts/sleep_soak.sh   # re-analyse an existing capture only
#
# The bench build light-sleeps on USB, so the USB-Serial-JTAG port drops while the chip sleeps and comes
# back in its 30 s "console windows"; scripts/serial_capture.py reconnects (re-resolving the port glob).
# Lines printed while the port is gone are lost: the analysis relies on lines that are repeated (the bench
# status line carries the boot number and that boot's reset reason).
#
# Output: firmware/sleep_soak.log + a summary. Exit 0 = no reboot and the clip stayed alive; 1 = a reboot
# (RTCWDT = a hang caught by the RTC watchdog), a panic / accounting error, or the status lines stopped;
# 2 = setup problem.
set -uo pipefail

FW="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${ANALYZE:-$FW/sleep_soak.log}"
MIN="${1:-30}"
PORT="${2:-/dev/cu.usbmodem*}"

if [ -z "${ANALYZE:-}" ]; then
    if [ -z "${IDF_PATH:-}" ] || ! command -v idf.py >/dev/null 2>&1; then
        # shellcheck disable=SC1090
        . "$HOME/esp/esp-idf/export.sh" >/dev/null 2>&1 || { echo "ERROR: cannot source ~/esp/esp-idf/export.sh"; exit 2; }
    fi
    # shellcheck disable=SC2086
    if ! ls $PORT >/dev/null 2>&1; then
        echo "note: no port matches $PORT yet (the chip may be asleep); capturing anyway, it reconnects"
    fi
    SECS=$((MIN * 60))
    echo "== capturing $MIN min of console from $PORT into ${LOG#"$FW"/} (reconnects across light sleep)"
    echo "   watch the panel: the bottom-left dot must blink every second; sessions every 2 min"
    python "$FW/scripts/serial_capture.py" "$PORT" "$SECS" "$LOG" --quiet &
    CAP=$!
    trap 'kill $CAP 2>/dev/null; exit 130' INT TERM
    START=$(date +%s)
    while kill -0 "$CAP" 2>/dev/null; do
        sleep 60
        NOW=$(date +%s)
        LAST=$(grep -Eo 'bench: boot #[0-9]+ reset [A-Z_0-9]+ up [0-9]+ s' "$LOG" 2>/dev/null | tail -n1)
        printf '   %3d min: %s lines, %s\n' $(((NOW - START) / 60)) "$(wc -l <"$LOG" 2>/dev/null | tr -d ' ')" \
            "${LAST:-no bench status line yet}"
    done
    wait "$CAP"
    trap - INT TERM
fi

[ -f "$LOG" ] || { echo "ERROR: no log $LOG"; exit 2; }

python3 - "$LOG" <<'PY'
import re, sys
log = open(sys.argv[1], "rb").read().decode("utf-8", "replace").splitlines()

def t(line):
    m = re.match(r"\[\s*([0-9.]+)\]", line)
    return float(m.group(1)) if m else None

boots = {}          # boot number -> reset reason
order = []
status_times = []
fails = []
booting_lines = 0
sessions_up = sessions_off = 0
drops = 0
coredumps = []      # "health: coredump: ..." boot lines (a dump persists until DELETE /coredump)
for line in log:
    m = re.search(r"health: (coredump: .*)", line)
    if m:
        coredumps.append(m.group(1).strip())
    m = re.search(r"PixelClip firmware booting \(wake cause \d+, reset reason ([A-Z_0-9]+) \(esp \d+\), boot #(\d+)\)", line)
    if m:
        booting_lines += 1
        b = int(m.group(2)); boots.setdefault(b, m.group(1)); order.append(b) if b not in order else None
    m = re.search(r"bench: boot #(\d+) reset ([A-Z_0-9]+) up (\d+) s", line)
    if m:
        b = int(m.group(1)); boots.setdefault(b, m.group(2)); order.append(b) if b not in order else None
        if t(line) is not None:
            status_times.append(t(line))
    if "upload mode: http://" in line:
        sessions_up += 1
    if "upload mode off" in line:
        sessions_off += 1
    if "port lost" in line:
        drops += 1
    for pat in ("Guru Meditation", "abort() was called", "assert failed", "PM LOCK ACCOUNTING", "Task watchdog got triggered",
                "stack overflow", "Brownout", "NOT feeding the RTC watchdog", "previous run (boot #"):
        if pat in line:
            fails.append(line.strip())

nboots = len(boots)
rtcwdt = sum(1 for b in sorted(boots)[1:] if boots[b].startswith("RTCWDT"))
reboots = max(0, nboots - 1)
# NVS counters from the status lines (survive lost boot lines): delta between the first and last line.
cnt = [tuple(map(int, m.groups())) for m in
       (re.search(r"resets wdt (\d+) rtc_wdt (\d+) brownout (\d+) panic (\d+)", l) for l in log) if m]
delta = tuple(b - a for a, b in zip(cnt[0], cnt[-1])) if len(cnt) > 1 else None
gaps = [b - a for a, b in zip(status_times, status_times[1:])]
max_gap = max(gaps) if gaps else None
span = (status_times[-1] - status_times[0]) if len(status_times) > 1 else 0

print("== sleep soak summary (%s)" % sys.argv[1])
print("  boots seen         : %d (%s)" % (nboots, ", ".join("#%d %s" % (b, boots[b]) for b in sorted(boots)) or "none"))
if delta:
    print("  NVS reset counters : +%d watchdog (+%d RTC watchdog), +%d brownout, +%d panic during the capture" % delta)
    if delta[1] > rtcwdt:
        rtcwdt = delta[1]
    if delta[0] + delta[2] + delta[3] > reboots:   # rtc_wdt is a subset of wdt
        reboots = delta[0] + delta[2] + delta[3]
if boots and sorted(boots) and boots[sorted(boots)[0]].startswith("RTCWDT"):
    print("  NOTE: the first boot in the capture was already an RTCWDT reset (a hang before the capture started)")
print("  reboots            : %d, of which RTCWDT (hang caught by the RTC watchdog): %d" % (reboots, rtcwdt))
print("  bench status lines : %d over %.0f s, largest gap %s s (expected ~30 s)" %
      (len(status_times), span, "%.0f" % max_gap if max_gap is not None else "n/a"))
print("  sessions seen      : %d up / %d off (lines only seen when the console was connected)" % (sessions_up, sessions_off))
print("  port drops         : %d (expected: the chip light-sleeps on USB in this build)" % drops)
last = [l for l in log if "bench: boot #" in l][-1:] or ["(none)"]
print("  last status        : %s" % re.sub(r"^\[\s*[0-9.]+\]\s*", "", last[0])[:400])
print("  core dump lines    : %d%s" % (len(coredumps), " (stored until DELETE /coredump: may predate this capture)" if coredumps else ""))
for c in sorted(set(coredumps))[:3]:
    print("    " + c[:400])
if fails:
    print("  PROBLEMS (%d):" % len(fails))
    for f in fails[:15]:
        print("    " + f[:300])
bad = reboots > 0 or bool(fails) or len(status_times) < 2 or (max_gap is not None and max_gap > 120)
print("RESULT: %s" % ("FAIL" if bad else "PASS"))
sys.exit(1 if bad else 0)
PY
