#!/usr/bin/env bash
# scripts/archive-source.sh
# Creates a clean source code ZIP snapshot using git archive
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
ZIP_PATH="$BUILD_DIR/LLM-monitor-src.zip"
TEMP_ZIP=""

cleanup() {
    if [[ -n "$TEMP_ZIP" ]]; then
        rm -f -- "$TEMP_ZIP"
    fi
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR"
TEMP_ZIP="$(mktemp "$BUILD_DIR/.LLM-monitor-src.zip.XXXXXX")"

echo "==> Creating clean source code archive from committed HEAD..."
# Intentionally archive committed HEAD: uncommitted working-tree changes are excluded.
# `-C` makes this independent of the caller's current working directory.
git -C "$ROOT_DIR" archive --format=zip -o "$TEMP_ZIP" HEAD
chmod 0644 "$TEMP_ZIP"

# The temporary file is in BUILD_DIR, so replacement is an atomic same-filesystem rename.
# A failed archive/chmod leaves any previously successful ZIP untouched.
mv -f -- "$TEMP_ZIP" "$ZIP_PATH"
TEMP_ZIP=""

echo "✓ Successfully created source archive at: $ZIP_PATH"
echo "  Snapshot: committed HEAD (working-tree changes are not included)."
echo "  This archive excludes git history, build caches, binaries, and local config.json keys."
