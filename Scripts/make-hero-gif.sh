#!/usr/bin/env bash
#
# Renders the animated README hero (docs/images/hero.gif) from the character engine.
# Needs ffmpeg (brew install ffmpeg).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT
command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }

swift build --package-path "$ROOT" --product Momo >/dev/null
"$ROOT/.build/debug/Momo" --render-hero-frames "$FRAMES"

# A palette made from the frames' differences keeps the character crisp, and diff_mode
# re-encodes only the parts that change, which keeps the file small.
ffmpeg -loglevel error -y -framerate 20 -i "$FRAMES/%04d.png" \
    -vf "palettegen=max_colors=192:stats_mode=diff" "$FRAMES/palette.png"
ffmpeg -loglevel error -y -framerate 20 -i "$FRAMES/%04d.png" -i "$FRAMES/palette.png" \
    -lavfi "paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" -loop 0 \
    "$ROOT/docs/images/hero.gif"
echo "Wrote docs/images/hero.gif ($(du -h "$ROOT/docs/images/hero.gif" | cut -f1))"
