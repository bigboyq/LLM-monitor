#!/usr/bin/env bash
# Build LLM-monitor.app bundle from SPM sources
#
# 用法：
#   ./scripts/build-app.sh [version] [build-number]
# 未提供 build-number 时自动递增 .build_number；同时提供两个参数可做可重复构建。
#
# 输出：
#   build/LLM-monitor.app          (可双击运行)
set -euo pipefail

# ── 参数与版本管理 ───────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_FILE="$ROOT_DIR/.build_number"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CODESIGN_ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-}"
DISTRIBUTION_BUILD="${DISTRIBUTION_BUILD:-0}"
BUNDLE_ID="${BUNDLE_ID:-com.yaktype.llm-monitor}"
BUILD_TMP_FILE=""

cleanup() {
    if [ -n "$BUILD_TMP_FILE" ]; then
        rm -f -- "$BUILD_TMP_FILE"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 2
}

validate_version() {
    local value="$1"
    if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
        fail "version 必须是三个点分隔的非负整数（例如 1.3.0），实际值: '${value:-<empty>}'"
    fi
}

validate_build_number() {
    local value="$1"
    if [[ ! "$value" =~ ^[1-9][0-9]{0,17}$ ]]; then
        fail "build-number 必须是 1 到 18 位的正整数，实际值: '${value:-<empty>}'"
    fi
}

validate_bundle_id() {
    local value="$1"
    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]]; then
        fail "BUNDLE_ID 必须是有效的反向 DNS 标识符，实际值: '${value:-<empty>}'"
    fi
}

if [ "$DISTRIBUTION_BUILD" = "1" ] && [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "ERROR: DISTRIBUTION_BUILD=1 requires a Developer ID signing identity"
    echo "       Set CODESIGN_IDENTITY='Developer ID Application: ...'"
    exit 2
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo "1.0.1" > "$VERSION_FILE"
fi
if [ ! -f "$BUILD_FILE" ]; then
    echo "1" > "$BUILD_FILE"
fi

if [ $# -gt 2 ]; then
    fail "用法: $0 [version] [build-number]"
fi

INCREMENT_BUILD=0
if [ $# -ge 1 ]; then
    VERSION="$1"
    if [ $# -ge 2 ]; then
        BUILD_NUMBER="$2"
    else
        CURRENT_BUILD_NUMBER=$(tr -d '\n\r ' < "$BUILD_FILE")
        INCREMENT_BUILD=1
    fi
else
    VERSION=$(tr -d '\n\r ' < "$VERSION_FILE")
    CURRENT_BUILD_NUMBER=$(tr -d '\n\r ' < "$BUILD_FILE")
    INCREMENT_BUILD=1
fi

validate_version "$VERSION"
validate_bundle_id "$BUNDLE_ID"

if [ "$INCREMENT_BUILD" = "1" ]; then
    validate_build_number "$CURRENT_BUILD_NUMBER"
    BUILD_NUMBER=$((10#$CURRENT_BUILD_NUMBER + 1))
fi
validate_build_number "$BUILD_NUMBER"

if [ "$INCREMENT_BUILD" = "1" ]; then
    BUILD_TMP_FILE="$(mktemp "$ROOT_DIR/.build_number.tmp.XXXXXX")"
    printf '%s\n' "$BUILD_NUMBER" > "$BUILD_TMP_FILE"
    mv -f -- "$BUILD_TMP_FILE" "$BUILD_FILE"
    BUILD_TMP_FILE=""
fi

BUILD_DIR="$ROOT_DIR/build"
APP_NAME="LLM-monitor"
DISPLAY_NAME="LLM Monitor"
MIN_OS="14.0"

echo "==> Building $DISPLAY_NAME v$VERSION (build $BUILD_NUMBER)"
echo "    Bundle ID: $BUNDLE_ID"
echo

# ── 1. Swift release 编译 ──────────────────────────────────────
cd "$ROOT_DIR"

# SwiftPM/Clang 默认可能使用用户级缓存目录；在受限环境或权限异常时会导致
# Release 构建出现 ModuleCache warning，甚至无法加载标准库。将其固定到项目
# 的 .build 目录，保证脚本可以独立运行。
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "==> [1/4] swift build -c release"
swift build -c release --arch arm64 --arch x86_64
BINARY_PATH="$ROOT_DIR/.build/apple/Products/Release/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    # 兼容 Swift < 5.9 的路径
    BINARY_PATH="$ROOT_DIR/.build/release/$APP_NAME"
fi
if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: 找不到 release 二进制"
    exit 1
fi
echo "    Binary: $BINARY_PATH"

# ── 2. 创建 .app bundle 结构 ──────────────────────────────────────
echo "==> [2/4] Creating .app bundle"
APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY_PATH" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM 的 Bundle.module 资源必须随 .app 一起分发，否则首次加载品牌
# SVG/WebP 等资源时会因找不到 LLM-monitor_LLM-monitor.bundle 直接退出。
RESOURCE_BUNDLE="$ROOT_DIR/.build/apple/Products/Release/${APP_NAME}_${APP_NAME}.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "ERROR: 找不到 SwiftPM 资源 bundle: $RESOURCE_BUNDLE"
    exit 1
fi
echo "    Copying SwiftPM resource bundle"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

if [ -f "$ROOT_DIR/Sources/LLM-monitor/Resources/AppIcon.icns" ]; then
    echo "    Copying AppIcon.icns"
    cp "$ROOT_DIR/Sources/LLM-monitor/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# ── 3. Info.plist ────────────────────────────────────────────────
echo "==> [3/4] Writing Info.plist"
INFO_PLIST="$APP/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIconFile -string "AppIcon" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleName -string "$DISPLAY_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string "$DISPLAY_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "$MIN_OS" "$INFO_PLIST"
/usr/bin/plutil -insert LSUIElement -bool true "$INFO_PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"
/usr/bin/plutil -insert NSPrincipalClass -string "NSApplication" "$INFO_PLIST"
/usr/bin/plutil -insert NSSupportsAutomaticTermination -bool true "$INFO_PLIST"
/usr/bin/plutil -insert NSSupportsSuddenTermination -bool true "$INFO_PLIST"

echo "    Validating Info.plist"
/usr/bin/plutil -lint "$INFO_PLIST"

# ── 4. Code signing ─────────────────────────────────────────────
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "==> [4/4] Ad-hoc code signing"
    echo "    WARNING: this build is for local testing only; it is not notarizable."
else
    echo "==> [4/4] Developer ID code signing"
fi

CODESIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY")
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
fi
if [ -n "$CODESIGN_ENTITLEMENTS" ]; then
    CODESIGN_ARGS+=(--entitlements "$CODESIGN_ENTITLEMENTS")
fi

codesign "${CODESIGN_ARGS[@]}" "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo
echo "✓ Done: $APP"
echo "  Open with: open '$APP'"
