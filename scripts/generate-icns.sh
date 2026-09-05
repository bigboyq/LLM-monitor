#!/usr/bin/env bash
# scripts/generate-icns.sh
# Convert a raw image (PNG/JPG) to AppIcon.icns
#
# 每个像素尺寸只生成一张图层（16/32/64/128/256/512/1024），避免旧流程里
# icon_128x128@2x==icon_256x256、icon_256x256@2x==icon_512x512 这类逐字节重复图层。
# 进入 iconset 的 1024px 主图副本（以及其他 >200KB 的图层副本）会用 pngquant
# 有损压缩；pngquant 缺失或质量目标不达标时跳过压缩并告警，脚本不因此失败。
# 注意：源图本身不会被修改，压缩只作用于 iconset 内的副本。
set -euo pipefail

if [ "$#" -eq 1 ]; then
    # 不传源图时默认用仓库内 1024px 主图源资产（由旧 icns 解出并存档）。
    SRC_IMAGE="${ROOT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/Assets/icon-master.png"
    OUT_DIR="${1}"
elif [ "$#" -eq 2 ]; then
    SRC_IMAGE="${1}"
    OUT_DIR="${2}"
else
    echo "Usage: $0 [source_image_path] <output_directory>"
    echo "  source_image_path defaults to Assets/icon-master.png"
    exit 1
fi

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
# 一个像素尺寸一张图层：icp4(16) / ic11(32) / ic12(64) / ic07(128) / ic13(256) / ic14(512) / ic10(1024)
sips -s format png -z 16 16     "$SRC_IMAGE" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
sips -s format png -z 32 32     "$SRC_IMAGE" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -s format png -z 64 64     "$SRC_IMAGE" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -s format png -z 128 128   "$SRC_IMAGE" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
sips -s format png -z 256 256   "$SRC_IMAGE" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -s format png -z 512 512   "$SRC_IMAGE" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -s format png -z 1024 1024 "$SRC_IMAGE" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

echo "==> Compressing icon layers..."
if command -v pngquant > /dev/null 2>&1; then
    for png in "$ICONSET_DIR"/*.png; do
        name="$(basename "$png")"
        size=$(wc -c < "$png" | tr -d ' ')
        # 1024px 主图必有损压缩；其余图层超过 200KB 时也顺手压。
        is_master=0
        [ "$name" = "icon_512x512@2x.png" ] && is_master=1
        if [ "$is_master" -eq 1 ] || [ "$size" -gt 200000 ]; then
            quantized="$TEMP_DIR/pngquant-out.png"
            rm -f "$quantized"
            # 质量不达标或压缩后更大时 pngquant 不会写出输出：保留原图，不视为失败。
            pngquant --quality 60-90 --skip-if-larger --force --output "$quantized" -- "$png" > /dev/null 2>&1 || true
            if [ -s "$quantized" ]; then
                before="$size"
                after=$(wc -c < "$quantized" | tr -d ' ')
                mv "$quantized" "$png"
                echo "    $name: $before -> $after bytes (pngquant)"
            else
                echo "    $name: pngquant 未产出更小结果，保留原图"
            fi
        fi
    done
else
    echo "    WARNING: pngquant 未安装，跳过有损压缩（可运行: brew install pngquant）" >&2
fi

echo "==> Creating icns file..."
mkdir -p "$OUT_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_DIR/AppIcon.icns"

echo "✓ Successfully generated $OUT_DIR/AppIcon.icns"
