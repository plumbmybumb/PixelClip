#!/usr/bin/env bash
# flash.sh [port] — build, flash, capture 25 s of boot log to firmware/last_boot.log, PASS/FAIL summary.
#
#   scripts/flash.sh                    # autodetect /dev/cu.usbmodem*
#   scripts/flash.sh /dev/cu.usbmodem101
#   NOFLASH=1 scripts/flash.sh          # skip build+flash: RESET the board (deliberately) and capture its boot
#   SECONDS_CAPTURE=40 scripts/flash.sh # longer capture (default 25)
#   ERASE=1 scripts/flash.sh            # erase the whole flash first (wipes assets/NVS)
#   BENCH=1 scripts/flash.sh            # light-sleep soak build (sdkconfig.defaults + sdkconfig.bench, in
#                                       # build-bench/ with its own sdkconfig), then run scripts/sleep_soak.sh
#   LCDRACE=1 scripts/flash.sh          # display bus stress build (sdkconfig.defaults + sdkconfig.lcdrace, in
#                                       # build-lcdrace/): tiny flushes as fast as possible from the other core
#   STRESS=1 scripts/flash.sh           # stress-session build (sdkconfig.defaults + sdkconfig.stress, in build-stress/):
#                                       # session + water scene + 200 KB atlas every 30 s, /bench/crash + /bench/wedge
#
# The generated sdkconfig only picks up sdkconfig.defaults when it is created: if a value in the defaults
# differs from the generated file and the defaults are newer, the file is regenerated (old copy kept as
# sdkconfig.old). KEEP_SDKCONFIG=1 skips that.
#
# Exit status: 0 = all checks passed, 1 = a check failed, 2 = setup problem (no IDF / no port).
set -uo pipefail

FW="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$FW/last_boot.log"
CAPTURE_S="${SECONDS_CAPTURE:-25}"

if [ -z "${IDF_PATH:-}" ] || ! command -v idf.py >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "$HOME/esp/esp-idf/export.sh" >/dev/null 2>&1 || { echo "ERROR: cannot source ~/esp/esp-idf/export.sh"; exit 2; }
fi

PORT="${1:-}"
if [ -z "$PORT" ]; then
    # shellcheck disable=SC2012
    PORTS=$(ls /dev/cu.usbmodem* 2>/dev/null || true)
    PORT=$(echo "$PORTS" | head -n1)
    if [ -z "$PORT" ]; then
        cat <<'MSG'
ERROR: no /dev/cu.usbmodem* port.
  - Use a USB-C *data* cable; the board has no UART bridge (native USB Serial/JTAG on GPIO19/20).
  - If it still does not enumerate: hold BOOT, tap RESET, release BOOT (ROM download mode), rerun,
    then press RESET after flashing.
MSG
        exit 2
    fi
    if [ "$(echo "$PORTS" | wc -l | tr -d ' ')" -gt 1 ]; then
        echo "note: several ports found, using $PORT:"; echo "$PORTS" | sed 's/^/    /'
    fi
fi
echo "== port $PORT"

cd "$FW" || exit 2
if [ -n "${STRESS:-}" ]; then
    BUILD_DIR="$FW/build-stress"
    SDKCFG="$BUILD_DIR/sdkconfig"
    DEFAULTS="$FW/sdkconfig.defaults;$FW/sdkconfig.stress"
    BUILD_LOG="$FW/build-stress.log"
    mkdir -p "$BUILD_DIR"
    echo "== STRESS build (session + water scene + atlas uploads, bench fault routes): NOT for the clip"
elif [ -n "${LCDRACE:-}" ]; then
    BUILD_DIR="$FW/build-lcdrace"
    SDKCFG="$BUILD_DIR/sdkconfig"
    DEFAULTS="$FW/sdkconfig.defaults;$FW/sdkconfig.lcdrace"
    BUILD_LOG="$FW/build-lcdrace.log"
    mkdir -p "$BUILD_DIR"
    echo "== LCD RACE build (display bus hand-over stress): NOT for the clip"
elif [ -n "${BENCH:-}" ]; then
    BUILD_DIR="$FW/build-bench"
    SDKCFG="$BUILD_DIR/sdkconfig"
    DEFAULTS="$FW/sdkconfig.defaults;$FW/sdkconfig.bench"
    BUILD_LOG="$FW/build-bench.log"
    mkdir -p "$BUILD_DIR"
    echo "== BENCH build (light sleep on USB, session cycling, heartbeat dot): NOT for the clip"
else
    BUILD_DIR="$FW/build"
    SDKCFG="$FW/sdkconfig"
    DEFAULTS="$FW/sdkconfig.defaults"
    BUILD_LOG="$FW/build.log"
fi
IDF=(idf.py -B "$BUILD_DIR" -D SDKCONFIG="$SDKCFG" -D SDKCONFIG_DEFAULTS="$DEFAULTS")

# Regenerate a stale sdkconfig (a defaults value it does not have, defaults newer than it).
if [ -f "$SDKCFG" ] && [ -z "${KEEP_SDKCONFIG:-}" ]; then
    STALE=$(python3 - "$SDKCFG" "$DEFAULTS" <<'PY'
import os, re, sys
cfg_path, defaults = sys.argv[1], sys.argv[2].split(";")
cfg = {}
for line in open(cfg_path):
    m = re.match(r"(CONFIG_\w+)=(.*)", line.strip()) or re.match(r"# (CONFIG_\w+) is not set", line.strip())
    if m: cfg[m.group(1)] = m.group(2) if m.lastindex == 2 else "n"
newest = max(os.path.getmtime(d) for d in defaults)
want = {}
for d in defaults:   # later files override earlier ones, as in the build
    for line in open(d):
        m = re.match(r"(CONFIG_\w+)=(.*)", line.strip())
        if m: want[m.group(1)] = m.group(2)
bad = ["%s=%s (have %s)" % (k, v, cfg.get(k, "unset")) for k, v in want.items() if cfg.get(k, "n") != v]
if bad and newest > os.path.getmtime(cfg_path):
    print("; ".join(bad))
PY
)
    if [ -n "$STALE" ]; then
        echo "== sdkconfig is older than the defaults and differs: $STALE"
        echo "   regenerating it from the defaults (previous copy: ${SDKCFG}.old)"
        mv "$SDKCFG" "${SDKCFG}.old"
    fi
fi

if [ -z "${NOFLASH:-}" ]; then
    echo "== build"
    if ! "${IDF[@]}" build >"$BUILD_LOG" 2>&1; then
        tail -40 "$BUILD_LOG"; echo "FAIL build (full log: ${BUILD_LOG#"$FW"/})"; exit 1
    fi
    WARN=$(grep -c "warning:" "$BUILD_LOG" || true)
    echo "   build ok ($WARN warning lines in this incremental build)"
    # The app must leave >= 25 % of the 3 MB OTA slot free (room for future features + splash).
    FREE_PCT=$(grep -E 'pixelclip.bin binary size' "$BUILD_LOG" | grep -Eo '\(([0-9]+)%\) free' | grep -Eo '[0-9]+' | head -n1)
    if [ -n "$FREE_PCT" ] && [ "$FREE_PCT" -lt 25 ]; then
        echo "FAIL app image leaves only ${FREE_PCT}% of the OTA slot free (want >= 25%)"; exit 1
    fi
    [ -n "$FREE_PCT" ] && echo "   OTA slot headroom ${FREE_PCT}%"
    if [ -n "${ERASE:-}" ]; then
        echo "== erase flash"
        "${IDF[@]}" -p "$PORT" erase-flash || { echo "FAIL erase"; exit 1; }
    fi
    echo "== flash"
    if ! "${IDF[@]}" -p "$PORT" flash; then
        echo "FAIL flash. Try ROM download mode (hold BOOT, tap RESET, release BOOT) and rerun."
        exit 1
    fi
    sleep 0.3
    RESET_FLAG="--expect-boot"   # esptool already hard-reset the chip after flashing
else
    # NOFLASH: this path RESETS the chip on purpose (the capture is meant to start with a fresh boot: reset
    # reason, breadcrumbs of the previous run, core dump line). serial_capture.py only resets with --reset;
    # opening / reopening the port never does. To watch a running clip without resetting it, call
    # scripts/serial_capture.py PORT SECONDS FILE directly (no --reset).
    echo "== NOFLASH: resetting the chip (RTS pulse over USB-Serial-JTAG) for a fresh boot capture"
    RESET_FLAG="--reset"
fi

echo "== capturing ${CAPTURE_S}s of console to firmware/last_boot.log"
python "$FW/scripts/serial_capture.py" "$PORT" "$CAPTURE_S" "$LOG" $RESET_FLAG >/dev/null
echo "   $(wc -l <"$LOG" | tr -d ' ') lines captured"
echo

# ---------------------------------------------------------------- checks
FAILS=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf '  ....  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
has()  { grep -Eq "$1" "$LOG"; }
first(){ grep -Eo "$1" "$LOG" | head -n1; }

echo "== boot checks"
has "WARNING: port open caused a reset" && warn "serial_capture.py: opening the port reset the chip (see scripts/serial_capture.py, Modem lines)"
if has "boot complete in [0-9]+ ms"; then
    pass "boot complete ($(first 'boot complete in [0-9]+ ms'))"
elif has "app: summary: boot [0-9]+ ms"; then
    pass "boot complete (from summary: $(first 'summary: boot [0-9]+ ms'))"
else
    fail "no 'boot complete' / summary line (crash or boot loop? see last_boot.log)"
fi

FLUSH=$(first 'full flush [0-9]+ us' | grep -Eo '[0-9]+' | head -n1)
if [ -z "$FLUSH" ]; then
    fail "display: no full-flush timing line"
elif [ "$FLUSH" -eq 0 ]; then
    fail "display: full flush 0 us (panel bring-up failed, running headless)"
elif [ "$FLUSH" -gt 60000 ]; then
    fail "display: full flush ${FLUSH} us (expected ~13-20 ms at 40 MHz QSPI)"
else
    pass "display: full-frame flush ${FLUSH} us"
fi
has "AMOLED 536x240 up" && info "$(grep -Eo 'AMOLED 536x240 up.*' "$LOG" | head -n1)"

if has "LittleFS mounted:"; then
    pass "LittleFS: $(grep -Eo 'LittleFS mounted:.*' "$LOG" | head -n1 | sed 's/LittleFS mounted: //')"
elif has "littlefs mounted"; then
    pass "LittleFS: $(first 'littlefs mounted [0-9/]+ KB \([0-9]+ assets\)')"
else
    fail "LittleFS not mounted"
fi

MV=$(grep -Eo 'battery [0-9]+ mV' "$LOG" | tail -n1 | grep -Eo '[0-9]+')
if [ -z "$MV" ]; then
    fail "battery: no 'battery N mV' line"
elif [ "$MV" -lt 2500 ] || [ "$MV" -gt 4500 ]; then
    fail "battery: ${MV} mV is implausible (GPIO1 divider / ADC calibration?)"
else
    pass "battery: ${MV} mV$(has 'battery [0-9]+ mV.*(usb|USB present)' && echo ' (USB present: BAT node may read charger voltage, not SoC)')"
fi

if has "imu: QMI8658C at 0x"; then
    pass "IMU: $(grep -Eo 'QMI8658C at 0x[0-9A-F]{2} \(rev 0x[0-9A-F]{2}\)' "$LOG" | head -n1) (bench-check axes with GET /imu)"
elif has "imu: disabled in menuconfig"; then
    info "IMU disabled in menuconfig (scenes use fixed gravity)"
else
    fail "IMU: QMI8658C not detected (scenes fall back to fixed gravity; see README 'IMU bench check')"
fi
has "splash: [0-9]+ frame" && info "boot splash: $(grep -Eo 'splash: [0-9]+ frame.*' "$LOG" | head -n1)"

SSID=$(first 'SSID PixelClip-[0-9A-F]{4}' | awk '{print $2}')
[ -n "$SSID" ] && info "SoftAP SSID will be $SSID (e2e.sh picks it up from this log)"

if has "ble: advertising PixelClip-"; then
    pass "BLE doorbell: $(grep -Eo 'advertising PixelClip-[0-9A-F]{4}.*every [0-9.]+-[0-9.]+ ms' "$LOG" | head -n1)"
    has "expected average current added by BLE" && info "$(grep -Eo 'expected average current added by BLE: ~[0-9.]+ mA' "$LOG" | head -n1) (estimate)"
elif has "BLE doorbell disabled"; then
    info "BLE doorbell disabled (config ble_wake false)"
else
    fail "BLE doorbell: no 'ble: advertising' line (NimBLE init failed? see last_boot.log)"
fi
has "wifi_always_on: starting the hotspot" && info "wifi_always_on: the hotspot starts at boot"
if has "reset reason [A-Z_0-9]+"; then
    REASON=$(grep -Eo 'reset reason [A-Z_0-9]+ \(esp [0-9]+\), boot #[0-9]+' "$LOG" | head -n1)
    info "${REASON:-reset reason ?}"
    has "reset reason RTCWDT" && fail "the previous run was reset by the RTC watchdog (a hang): $(grep -Eo 'previous run \(boot #[0-9]+[^)]*\).*' "$LOG" | head -n1)"
fi
has "RTC watchdog on:" && pass "RTC watchdog: $(grep -Eo 'RTC watchdog on: .*' "$LOG" | head -n1 | sed 's/RTC watchdog on: //')"
# Crash diagnostics (README "Crash diagnostics (core dump)"). A stored core dump is reported at EVERY boot until
# DELETE /coredump, so it may well be from an earlier run: a warning, not a failure (a crash in this capture
# shows up below as a panic / reboot).
if has "health: coredump: "; then
    warn "core dump in flash (curl -o core.bin \$CLIP/coredump; idf.py coredump-info -c core.bin; then DELETE /coredump):"
    grep -Eo 'health: coredump: .*' "$LOG" | head -n1 | sed 's/^health: /        /'
fi
# Previous-run breadcrumbs (health.c): after every reset that kept RTC memory, including a RESET press on a
# wedged clip. Shown as warnings: they are the post-mortem of the run before this boot.
if has "previous run \(boot #|previous run: internal heap"; then
    warn "previous run (RTC breadcrumbs):"
    grep -Eo 'previous run( \(boot #|: internal heap).*' "$LOG" | head -n2 | sed 's/^/        /'
fi
has "liveness: silent" && fail "liveness: $(grep -Eo 'liveness: silent.*' "$LOG" | head -n1)"
has "ASSERTION: [0-9]+ light sleep" && fail "$(grep -Eo 'ASSERTION: [0-9]+ light sleep.*' "$LOG" | head -n1)"
has "STRESS BUILD" && info "STRESS build running: watch 'net: heap' / 'stress: round' lines (SECONDS_CAPTURE=300 for a longer capture)"
has "LIGHT-SLEEP SOAK BUILD" && info "BENCH build running: now run scripts/sleep_soak.sh (the console drops while it light-sleeps)"

echo "== problem scan"
BAD='Guru Meditation|abort\(\) was called|assert failed|Backtrace:|BOOT STEP FAILED|flush timeout|draw_bitmap failed|Task watchdog got triggered|stack overflow|Brownout|PM LOCK ACCOUNTING|NOT feeding the RTC watchdog|E \([0-9]+\) (display|storage|power|player|ble|health)'
if has "$BAD"; then
    fail "errors in log:"
    grep -E "$BAD" "$LOG" | head -n 12 | sed 's/^/        /'
else
    pass "no panics, watchdog, failed boot steps or display/storage errors"
fi
BOOTS=$(grep -c "PixelClip firmware booting" "$LOG" || true)
if [ "${BOOTS:-0}" -gt 1 ]; then fail "rebooted $BOOTS times during the capture (boot loop)"; fi
STACKS=$(grep -Eo 'stack free \(B\):.*' "$LOG" | tail -n1)
[ -n "$STACKS" ] && info "$STACKS"
HEAP=$(grep -Eo 'heap: internal.*' "$LOG" | tail -n1)
[ -n "$HEAP" ] && info "$HEAP"

echo
if [ "$FAILS" -eq 0 ]; then
    echo "RESULT: PASS (log: firmware/last_boot.log)"
    exit 0
fi
echo "RESULT: FAIL ($FAILS check(s); log: firmware/last_boot.log)"
exit 1
