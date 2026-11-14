#!/usr/bin/env bash
#
# PixelClip — the one build command.
#   ./build.sh              regenerate project + build for the simulator
#   ./build.sh run          …then install + launch on the simulator (virtual clip is on by default there)
#   ./build.sh test         PixelClipKit tests: swift test on macOS (includes C-decoder parity) + xcodebuild test on the simulator
#   DEVICE_ID=<udid> ./build.sh device           Debug build + install + launch on your iPhone (USB or same Wi-Fi).
#   DEVICE_ID=<udid> ./build.sh device-release   The same with a Release build: what to wear. No Debug menu, no
#                           virtual clip, no launch arguments, no console prints.
#                           Both need your team and bundle id prefix in Local.xcconfig (copy Local.xcconfig.example);
#                           `xcrun devicectl list devices` shows the id.
#
# The simulator is the newest available iOS 26+ one named $SIM_NAME (default "iPhone 17"); SIM_UDID picks one directly.
#
# Only actionable errors/warnings are printed; the full log is build/last-build.log.
set -uo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SIM_NAME="${SIM_NAME:-iPhone 17}"
SCHEME="PixelClip"
PROJECT="PixelClip.xcodeproj"
DERIVED="build/DerivedData"
LOG="build/last-build.log"

cd "$(dirname "$0")"
mkdir -p build

# The bundle id of a built app (it comes from Config.xcconfig / your Local.xcconfig, so it is read, not repeated here).
bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Info.plist"; }

case "${1:-}" in device|device-release) ON_DEVICE=1 ;; *) ON_DEVICE=0 ;; esac

if [ -z "${SIM_UDID:-}" ] && [ "$ON_DEVICE" = 0 ]; then
  SIM_UDID=$(xcrun simctl list devices available -j | SIM_NAME="$SIM_NAME" python3 -c '
import json, os, re, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m or int(m.group(1)) < 26:
        continue
    for d in devices:
        if d["name"] == os.environ["SIM_NAME"] and (best is None or (int(m.group(1)), int(m.group(2))) > best[0]):
            best = ((int(m.group(1)), int(m.group(2))), d["udid"])
print(best[1] if best else "")
')
  [ -n "$SIM_UDID" ] || { echo "❌ No iOS 26+ simulator named “$SIM_NAME” — set SIM_NAME or SIM_UDID (xcrun simctl list devices)"; exit 1; }
fi

filter() {
  grep -E "error:|warning:|fatal error|ld: |Undefined symbol|The following build commands failed|\*\* (BUILD|ARCHIVE|EXPORT|TEST) (SUCCEEDED|FAILED)|Executed [0-9]+ tests" "$1" \
    | grep -vE "appintentsmetadataprocessor|Metadata extraction skipped" \
    | sed -E 's#'"$PWD"'/##g' | sort -u || true
}

xcodegen generate --quiet || { echo "❌ xcodegen failed — check project.yml"; exit 1; }

if [ "${1:-}" = "test" ]; then
  # The C tools give the parity tests something to compare against (skipped if absent).
  if [ ! -x ../build/core/tools/hcainfo ] && command -v cmake >/dev/null; then
    (cmake -S ../core -B ../build/core -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build ../build/core >/dev/null) || true
  fi
  echo "→ swift test (macOS)…"
  (cd PixelClipKit && swift test) > "$LOG" 2>&1
  S1=$?
  grep -E "Executed [0-9]+ tests|error:|HCA_TIMING" "$LOG" | tail -3
  echo "→ xcodebuild test (simulator)…"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "platform=iOS Simulator,id=${SIM_UDID}" \
    -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO test >> "$LOG" 2>&1
  S2=$?
  filter "$LOG" | grep -E "error|TEST|Executed" | tail -5
  [ $S1 -eq 0 ] && [ $S2 -eq 0 ] && echo "✅ TESTS PASSED" || { echo "❌ TESTS FAILED — full log: $LOG"; exit 1; }
  exit 0
fi

if [ "$ON_DEVICE" = 1 ]; then
  [ -n "${DEVICE_ID:-}" ] || { echo "❌ Set DEVICE_ID to your iPhone's id (xcrun devicectl list devices)"; exit 1; }
  [ -f Local.xcconfig ] || echo "ℹ︎ No Local.xcconfig: signing uses the placeholders (copy Local.xcconfig.example and set your team and bundle id prefix)."
  [ "$1" = "device-release" ] && CONFIG=Release || CONFIG=Debug
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" -destination "id=$DEVICE_ID" \
    -derivedDataPath build/DeviceData -allowProvisioningUpdates build > "$LOG" 2>&1
  [ $? -eq 0 ] || { filter "$LOG"; echo "❌ BUILD FAILED — full log: $LOG"; exit 1; }
  APP="build/DeviceData/Build/Products/$CONFIG-iphoneos/PixelClip.app"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null \
    || { echo "❌ Install failed — is the iPhone connected and trusted?"; exit 1; }
  echo "✅ Installed on your iPhone ($CONFIG build)"
  if xcrun devicectl device process launch --device "$DEVICE_ID" "$(bundle_id "$APP")" >/dev/null 2>&1; then
    echo "▶︎ Launched"
  else
    echo "ℹ︎ Couldn’t open it automatically (phone locked?) — unlock and tap PixelClip."
  fi
  exit 0
fi

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "platform=iOS Simulator,id=${SIM_UDID}" -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build > "$LOG" 2>&1
STATUS=$?
filter "$LOG"
[ $STATUS -eq 0 ] || { echo "❌ BUILD FAILED — full log: $LOG"; exit $STATUS; }
echo "✅ BUILD SUCCEEDED"

if [ "${1:-}" = "run" ]; then
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/PixelClip.app"
  xcrun simctl boot "${SIM_UDID}" 2>/dev/null || true
  shift
  xcrun simctl install "${SIM_UDID}" "$APP" && xcrun simctl launch "${SIM_UDID}" "$(bundle_id "$APP")" "$@" >/dev/null && echo "▶︎ Launched on simulator"
fi
