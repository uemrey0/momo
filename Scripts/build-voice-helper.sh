#!/usr/bin/env bash
#
# Builds momo-voice, the on-device live voice helper in Helpers/momo-voice, with xcodebuild.
# xcodebuild (unlike `swift build`) compiles MLX's Metal shaders into mlx-swift_Cmlx.bundle.
# The helper needs macOS 15 and Apple Silicon, so it is built for arm64 only.
#
# Products land in .build/voice-helper/Build/Products/$CONFIGURATION: the momo-voice binary
# and the resource bundles it needs (*.bundle).
#
# Environment variables:
#   CONFIGURATION   Debug or Release (default: Release)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="$ROOT/.build/voice-helper"

echo "==> Building momo-voice ($CONFIGURATION)"
cd "$ROOT/Helpers/momo-voice"
xcodebuild \
    -scheme momo-voice \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    ARCHS=arm64 \
    -quiet \
    build

echo "==> Built $DERIVED_DATA/Build/Products/$CONFIGURATION/momo-voice"
