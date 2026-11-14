#!/usr/bin/env bash
# screenshot.sh [out.png] — GET /screenshot from the clip and convert it to PNG (2x scale) and open it.
#   CLIP=http://pixelclip.local scripts/screenshot.sh       # default http://192.168.4.1
#   NO_OPEN=1 scripts/screenshot.sh shot.png
# The Mac must already be on the clip's PixelClip-XXXX network (scripts/e2e.sh, or the Wi-Fi menu).
# During an upload session the panel is off; the screenshot is the frame that will show on resume.
set -euo pipefail
FW="$(cd "$(dirname "$0")/.." && pwd)"
CLIP="${CLIP:-http://192.168.4.1}"
OUT="${1:-$FW/screenshot-$(date +%Y%m%d-%H%M%S).png}"
RAW="$(mktemp -t pixelclip-shot).raw"
trap 'rm -f "$RAW"' EXIT
code=$(curl -sS -m 30 -o "$RAW" -w '%{http_code}' "$CLIP/screenshot") || { echo "clip not reachable at $CLIP (joined its Wi-Fi?)"; exit 1; }
size=$(wc -c <"$RAW" | tr -d ' ')
if [ "$code" != 200 ] || [ "$size" != 257280 ]; then
    # What the clip sent is shown as printable ASCII only (it is data from the network, not text to trust).
    echo "unexpected reply: HTTP $code, $size bytes (want 200, 257280)"; head -c 300 "$RAW" | LC_ALL=C tr -c '\40-\176' '?'; echo; exit 1
fi
python3 "$FW/scripts/rgb565_to_png.py" "$RAW" "$OUT" --scale "${SCALE:-2}"
echo "$OUT"
if [ -z "${NO_OPEN:-}" ] && command -v open >/dev/null; then open "$OUT"; fi
