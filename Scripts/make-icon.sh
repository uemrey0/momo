#!/usr/bin/env bash
#
# Regenerates Scripts/AppIcon.icns from the character renderer, so the icon always matches
# how Momo is drawn. Run after changing the character's look.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
trap 'rm -rf "$WORK"' EXIT

swift build --package-path "$ROOT" --product Momo >/dev/null
"$ROOT/.build/debug/Momo" --render-icon "$WORK/icon-1024.png"

mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$ROOT/Scripts/AppIcon.icns"
echo "Wrote Scripts/AppIcon.icns"
