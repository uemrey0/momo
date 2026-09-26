#!/usr/bin/env bash
#
# Builds dist/Momo.app with xcodebuild, which (unlike `swift build`) compiles String Catalogs.
#
# Environment variables:
#   CONFIGURATION   Debug or Release (default: Release)
#   SIGN_IDENTITY   Code signing identity (default: "-" for an ad-hoc signature)
#   VERSION         Marketing version (default: the value in Scripts/Info.plist)
#   VOICE_HELPER    auto, 1 or 0: bundle the momo-voice live voice helper (default: auto, which
#                   bundles it when it builds and warns otherwise; 1 makes a failure fatal)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DERIVED_DATA="$ROOT/.build/xcode"
PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP="$ROOT/dist/Momo.app"
LOCALIZATIONS=(en tr)
VOICE_HELPER="${VOICE_HELPER:-auto}"
VOICE_PRODUCTS="$ROOT/.build/voice-helper/Build/Products/$CONFIGURATION"

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

# The live voice helper is a separate package (macOS 15, Apple Silicon, MLX). Momo works
# without it, so by default a failed helper build only costs the on-device live voice.
HAS_VOICE_HELPER=0
if [[ "$VOICE_HELPER" != "0" ]]; then
    if CONFIGURATION="$CONFIGURATION" "$ROOT/Scripts/build-voice-helper.sh"; then
        HAS_VOICE_HELPER=1
    elif [[ "$VOICE_HELPER" == "1" ]]; then
        echo "error: the momo-voice helper failed to build" >&2
        exit 1
    else
        echo "warning: the momo-voice helper failed to build; Momo.app will not include it" >&2
    fi
fi

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

if [[ "$HAS_VOICE_HELPER" == "1" ]]; then
    # Next to momo-mcp; Momo launches it as a child process. Its resource bundles (MLX's
    # Metal shaders, Kokoro's dictionaries) go to Contents/Resources, where SwiftPM's
    # Bundle.module and MLX look for them, since the helper's main bundle is Momo.app.
    cp "$VOICE_PRODUCTS/momo-voice" "$APP/Contents/MacOS/momo-voice"
    for bundle in "$VOICE_PRODUCTS"/*.bundle; do
        name="$(basename "$bundle")"
        [[ -e "$APP/Contents/Resources/$name" ]] || cp -R "$bundle" "$APP/Contents/Resources/"
    done
fi

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
# Nested executables are signed first, each with its own entitlements (--deep would give them
# the app's), then the app seals them.
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/momo-mcp"
if [[ "$HAS_VOICE_HELPER" == "1" ]]; then
    codesign --force --options runtime --entitlements "$ROOT/Scripts/momo-voice.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/momo-voice"
fi
codesign --force --options runtime --entitlements "$ROOT/Scripts/Momo.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> Done: $APP"
