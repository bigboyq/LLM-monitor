#!/usr/bin/env bash
# scripts/generate-icns.sh
# Convert a raw image (PNG/JPG) to AppIcon.icns
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source_image_path> <output_directory>"
    exit 1
fi

SRC_IMAGE="${1}"
OUT_DIR="${2}"

if [ ! -f "$SRC_IMAGE" ]; then
    echo "ERROR: source image does not exist: $SRC_IMAGE" >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-monitor-icon.XXXXXX")"
ICONSET_DIR="$TEMP_DIR/AppIcon.iconset"
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
mkdir -p "$ICONSET_DIR"

echo "==> Resizing images..."
sips -s format png -z 16 16     "$SRC_IMAGE" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
sips -s format png -z 32 32     "$SRC_IMAGE" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -s format png -z 32 32     "$SRC_IMAGE" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
sips -s format png -z 64 64     "$SRC_IMAGE" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -s format png -z 128 128   "$SRC_IMAGE" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
sips -s format png -z 256 256   "$SRC_IMAGE" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -s format png -z 256 256   "$SRC_IMAGE" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
sips -s format png -z 512 512   "$SRC_IMAGE" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -s format png -z 512 512   "$SRC_IMAGE" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
sips -s format png -z 1024 1024 "$SRC_IMAGE" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

echo "==> Creating icns file..."
mkdir -p "$OUT_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_DIR/AppIcon.icns"

echo "✓ Successfully generated $OUT_DIR/AppIcon.icns"
