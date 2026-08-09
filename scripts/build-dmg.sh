#!/usr/bin/env bash
# Build LLM-monitor.dmg from .app bundle
#
# 用法：
#   ./scripts/build-dmg.sh           # 默认用最新 build/ 下的 .app
#   NOTARIZE=1 NOTARY_PROFILE="llm-monitor" ./scripts/build-dmg.sh
#
# 输出：
#   build/LLM-monitor-<version>.dmg
set -euo pipefail

NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ "$NOTARIZE" != "0" && "$NOTARIZE" != "1" ]]; then
    echo "ERROR: NOTARIZE 只能是 0 或 1" >&2
    exit 1
fi
if [[ "$NOTARIZE" == "1" && -z "$NOTARY_PROFILE" ]]; then
    echo "ERROR: NOTARIZE=1 时必须设置已保存凭据的 NOTARY_PROFILE" >&2
    echo '       例如：NOTARY_PROFILE="llm-monitor" ./scripts/build-dmg.sh' >&2
    exit 1
fi
if [[ "$NOTARIZE" == "1" && ( -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ) ]]; then
    echo "ERROR: notarization requires a Developer ID CODESIGN_IDENTITY" >&2
    echo '       例如：CODESIGN_IDENTITY="Developer ID Application: ..."' >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="LLM-monitor"

APP="$BUILD_DIR/$APP_NAME.app"
if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP 不存在，先跑 ./scripts/build-app.sh"
    exit 1
fi

INFO_PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "ERROR: app 缺少 Info.plist: $INFO_PLIST" >&2
    exit 1
fi
if ! /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null; then
    echo "ERROR: Info.plist 格式无效: $INFO_PLIST" >&2
    exit 1
fi

STAGING=""
VERSION_FILE=""
cleanup() {
    if [[ -n "$STAGING" ]]; then
        rm -rf -- "$STAGING"
    fi
    if [[ -n "$VERSION_FILE" ]]; then
        rm -f -- "$VERSION_FILE"
    fi
}
trap cleanup EXIT

# 用文件接收 raw 值，避免命令替换吞掉尾部换行后误接受损坏版本字符串。
VERSION_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-monitor-version.XXXXXX")"
if ! /usr/bin/plutil \
    -extract CFBundleShortVersionString raw \
    -expect string \
    -n \
    -o "$VERSION_FILE" \
    "$INFO_PLIST"
then
    echo "ERROR: 无法读取字符串类型的 CFBundleShortVersionString" >&2
    exit 1
fi
if /usr/bin/od -An -tx1 "$VERSION_FILE" \
    | /usr/bin/grep -Eq '(^|[[:space:]])(0a|0d)([[:space:]]|$)'
then
    echo "ERROR: CFBundleShortVersionString 不得包含换行" >&2
    exit 1
fi
VERSION="$(<"$VERSION_FILE")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: CFBundleShortVersionString 必须是三段非负整数（例如 1.3.0）" >&2
    exit 1
fi
rm -f -- "$VERSION_FILE"
VERSION_FILE=""

DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
echo "==> Packaging $APP → $DMG_PATH"

# ── 临时 staging：拖一个 Applications 链接进去（标准 dmg 布局） ──
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/llm-monitor-dmg.XXXXXX")"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# ── 创建 dmg ──────────────────────────────────────────────────────
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [[ -n "$CODESIGN_IDENTITY" && "$CODESIGN_IDENTITY" != "-" ]]; then
    echo
    echo "==> Signing DMG with $CODESIGN_IDENTITY"
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
fi

if [[ "$NOTARIZE" == "1" ]]; then
    echo
    echo "==> Submitting DMG for notarization"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    echo "  ✓ notarization ticket stapled and validated"
fi

echo
echo "✓ Done: $DMG_PATH"
ls -lh "$DMG_PATH"

# ── 简单校验 ────────────────────────────────────────────────────
echo
echo "Verification:"
hdiutil verify "$DMG_PATH" && echo "  ✓ dmg image OK"
