#!/bin/sh
# Render the live scenes (core/scene.h) under scripted tilts for review.
#   tools/previews-scenes/make_previews.sh [--bindir DIR] [--out DIR] [--fps N] [--seconds S] [--quick] [--keep-frames]
#
# For every scene x one to three palettes it runs scene_preview with tilt-slow.txt, plus flip.txt and
# shake.txt (and faceup.txt) for the first palette of each scene, and writes under OUT (default
# tools/previews-scenes/out/):
#   <scene>-<palette>-<script>.gif        animated preview (if python3 + Pillow are available)
#   <scene>-<palette>-<script>-sheet.png  contact sheet: 12 evenly spaced frames, always
#   <scene>-<palette>-<script>/frame_NNNN.png   frames (kept without Pillow, or with --keep-frames)
# --quick renders only tilt-slow for the first palette of each scene.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN=""
OUT="$HERE/out"
FPS=20
SECONDS_=6
QUICK=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bindir) BIN="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --fps) FPS="$2"; shift 2 ;;
        --seconds) SECONDS_="$2"; shift 2 ;;
        --quick) QUICK=1; shift ;;
        --keep-frames) KEEP=1; shift ;;
        *) echo "usage: $0 [--bindir DIR] [--out DIR] [--fps N] [--seconds S] [--quick] [--keep-frames]" >&2; exit 2 ;;
    esac
done
if [ -z "$BIN" ]; then
    BIN="$ROOT/build/core/tools"
    if [ ! -x "$BIN/scene_preview" ]; then
        cmake -S "$ROOT/core" -B "$ROOT/build/core" >/dev/null
        cmake --build "$ROOT/build/core" --target scene_preview >/dev/null
    fi
fi
PREVIEW="$BIN/scene_preview"
[ -x "$PREVIEW" ] || { echo "error: $PREVIEW not found (build core first)" >&2; exit 1; }
mkdir -p "$OUT"

HAVE_PIL=0
if python3 -c "import PIL" >/dev/null 2>&1; then HAVE_PIL=1; fi
[ $HAVE_PIL = 1 ] || echo "note: Pillow not found (python3 -c 'import PIL'); keeping PNG frames + contact sheets" >&2

# scene, palettes (the first one also gets the flip/shake/faceup scripts; "pal:k=v:k=v" adds params
# for that palette only), extra params for all of them
cat > "$OUT/.plan" <<'PLAN'
sand amber,candy
water ocean,forest
snow mono,ocean
fire classic,blue,emerald
lava ember,candy
balls candy,amber:trail=1
PLAN

to_gif() {   # $1 frames dir, $2 output gif, $3 fps
    python3 - "$1" "$2" "$3" <<'PY'
import sys, glob
from PIL import Image
frames_dir, out, fps = sys.argv[1], sys.argv[2], float(sys.argv[3])
paths = sorted(glob.glob(frames_dir + "/frame_*.png"))
if not paths:
    sys.exit("no frames in " + frames_dir)
# one shared palette from a few sample frames keeps colours stable and the file small
sample = [Image.open(p).convert("RGB") for p in paths[:: max(1, len(paths) // 8)]]
strip = Image.new("RGB", (sample[0].width, sample[0].height * len(sample)))
for i, im in enumerate(sample):
    strip.paste(im, (0, i * im.height))
pal = strip.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
frames = [Image.open(p).convert("RGB").quantize(palette=pal, dither=Image.Dither.NONE) for p in paths]
frames[0].save(out, save_all=True, append_images=frames[1:], duration=int(round(1000 / fps)), loop=0, optimize=False)
PY
}

render() {   # $1 scene $2 palette $3 script $4 extra params
    scene=$1; pal=$2; script=$3; extra=$4
    name="$scene-$pal-$script"
    dir="$OUT/$name"
    rm -rf "$dir"
    params="--param palette=$pal"
    for kv in $extra; do params="$params --param $kv"; done
    # shellcheck disable=SC2086
    "$PREVIEW" "$scene" $params --script "$HERE/$script.txt" --fps "$FPS" --seconds "$SECONDS_" \
        --out "$dir" --sheet "$OUT/$name-sheet.png" | sed "s/^/  /"
    if [ $HAVE_PIL = 1 ]; then
        to_gif "$dir" "$OUT/$name.gif" "$FPS"
        [ $KEEP = 1 ] || rm -rf "$dir"
        echo "  -> $OUT/$name.gif"
    else
        echo "  -> $dir/ ($OUT/$name-sheet.png)"
    fi
}

while read -r scene pals extra; do
    [ -n "$scene" ] || continue
    first=1
    for tok in $(echo "$pals" | tr ',' ' '); do
        pal=${tok%%:*}
        more=""
        [ "$tok" = "$pal" ] || more=$(echo "${tok#*:}" | tr ':' ' ')
        render "$scene" "$pal" tilt-slow "${extra:-} $more"
        if [ $first = 1 ] && [ $QUICK = 0 ]; then
            for script in flip shake faceup; do render "$scene" "$pal" "$script" "${extra:-} $more"; done
        fi
        first=0
        [ $QUICK = 0 ] || break
    done
done < "$OUT/.plan"
rm -f "$OUT/.plan"
echo "previews in $OUT"
