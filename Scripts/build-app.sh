#!/usr/bin/env bash
#
# Builds dist/Momo.app with xcodebuild, which (unlike `swift build`) compiles String Catalogs.
#
# Environment variables:
#   CONFIGURATION   Debug or Release (default: Release)
#   SIGN_IDENTITY   Code signing identity (default: "-" for an ad-hoc signature)
#   VERSION         Marketing version (default: the value in Scripts/Info.plist)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DERIVED_DATA="$ROOT/.build/xcode"
PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP="$ROOT/dist/Momo.app"
LOCALIZATIONS=(en tr)

for scheme in Momo momo-mcp; do
    echo "==> Building $scheme ($CONFIGURATION)"
    xcodebuild \
        -scheme "$scheme" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet \
        build
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Momo" "$APP/Contents/MacOS/Momo"
# The MCP server lives next to the app so agents can launch it by path.
cp "$PRODUCTS/momo-mcp" "$APP/Contents/MacOS/momo-mcp"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$PRODUCTS"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Localized Info.plist strings (permission prompts). They also declare the app's
# localizations, which macOS needs to pick the user's language for the resource bundles.
for language in "${LOCALIZATIONS[@]}"; do
    mkdir -p "$APP/Contents/Resources/$language.lproj"
    cp "$ROOT/Scripts/InfoPlist/$language.strings" "$APP/Contents/Resources/$language.lproj/InfoPlist.strings"
done

if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "==> Signing with identity '$SIGN_IDENTITY'"
codesign --force --deep --options runtime --entitlements "$ROOT/Scripts/Momo.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"

echo "==> Done: $APP"
