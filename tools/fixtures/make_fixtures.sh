#!/bin/sh
# Rebuild the placeholder fixtures in tools/fixtures/ (or --out DIR).
#   tools/fixtures/make_fixtures.sh [--bindir DIR] [--out DIR]
# --bindir: where hcaenc/hcainfo/mkfixtures/rsvp_preview live (default: build/core/tools, built on demand).
#
# Glyph atlases use --no-dither; the gradient and animation keep hcaenc's default dithering.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN=""
OUT="$HERE"
while [ $# -gt 0 ]; do
    case "$1" in
        --bindir) BIN="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "usage: $0 [--bindir DIR] [--out DIR]" >&2; exit 2 ;;
    esac
done
if [ -z "$BIN" ]; then
    BIN="$ROOT/build/core/tools"
    if [ ! -x "$BIN/hcaenc" ]; then
        cmake -S "$ROOT/core" -B "$ROOT/build/core" >/dev/null
        cmake --build "$ROOT/build/core" >/dev/null
    fi
fi
mkdir -p "$OUT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hca-fixtures.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

"$BIN/mkfixtures" "$TMP"
"$BIN/hcaenc" "$OUT/gradient.hca" "$TMP/gradient.png"
"$BIN/hcaenc" "$OUT/anim12.hca" --fps 12 "$TMP"/anim-*.png

for f in gradient anim12; do
    "$BIN/hcainfo" "$OUT/$f.hca" -q | grep -E 'frames total|status'
done
# Reader font (PROTOCOL §5c): dot-matrix placeholder glyphs, normal + compact, white + accent atlases.
"$BIN/hcaenc" "$OUT/rsvp-dot-w.hca" --atlas --no-dither -q "$TMP"/rsvp-w-*.png
"$BIN/hcaenc" "$OUT/rsvp-dot-a.hca" --atlas --no-dither -q "$TMP"/rsvp-a-*.png
"$BIN/hcaenc" "$OUT/rsvp-dotc-w.hca" --atlas --no-dither -q "$TMP"/rsvpc-w-*.png
"$BIN/hcaenc" "$OUT/rsvp-dotc-a.hca" --atlas --no-dither -q "$TMP"/rsvpc-a-*.png
cp "$TMP/rsvp-font.json" "$OUT/rsvp-font.json"
[ "$OUT" = "$HERE" ] || cp "$HERE/rsvp-sample.txt" "$OUT/rsvp-sample.txt"
for f in rsvp-dot-w rsvp-dot-a rsvp-dotc-w rsvp-dotc-a; do
    "$BIN/hcainfo" "$OUT/$f.hca" -q | grep -E 'frames total|status'
done
mkdir -p "$OUT/rsvp-preview"
"$BIN/rsvp_preview" "$OUT/rsvp-font.json" "$OUT" "$OUT/rsvp-sample.txt" --out "$OUT/rsvp-preview" --words 12 \
    --sheet "$OUT/rsvp-preview/sheet.png" | tail -n 3

echo "fixtures written to $OUT"
