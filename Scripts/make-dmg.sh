#!/usr/bin/env bash
#
# Packs dist/Momo.app into dist/Momo-<version>.dmg with a shortcut to /Applications.
# Build the app first with `make app`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Momo.app"
[[ -d "$APP" ]] || { echo "dist/Momo.app is missing; run 'make app' first." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/Momo-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Momo $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "==> Done: $DMG"
