#!/usr/bin/env bash
# Build the distributable app, DMG, and SHA-256 checksum deterministically.
#
# Usage:
#   ./scripts/build-release.sh [version] [build-number]
#
# Signing/notarization variables are forwarded to build-app.sh/build-dmg.sh:
#   CODESIGN_IDENTITY="Developer ID Application: ..." \
#   NOTARIZE=1 NOTARY_PROFILE="llm-monitor" \
#   ./scripts/build-release.sh 1.4.2 95
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(tr -d '\r\n ' < "$ROOT_DIR/VERSION")}"
BUILD_NUMBER="${2:-$(tr -d '\r\n ' < "$ROOT_DIR/.build_number")}"

if [ $# -gt 2 ]; then
    echo "ERROR: usage: $0 [version] [build-number]" >&2
    exit 2
fi

"$ROOT_DIR/scripts/build-app.sh" "$VERSION" "$BUILD_NUMBER"
"$ROOT_DIR/scripts/build-dmg.sh"

DMG_NAME="LLM-monitor-$VERSION.dmg"
if [ ! -f "$ROOT_DIR/build/$DMG_NAME" ]; then
    echo "ERROR: release artifact not found: $ROOT_DIR/build/$DMG_NAME" >&2
    exit 1
fi

(
    cd "$ROOT_DIR/build"
    shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt
)

echo
echo "Release artifacts:"
ls -lh "$ROOT_DIR/build/$DMG_NAME" "$ROOT_DIR/build/SHA256SUMS.txt"
