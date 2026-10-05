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
#
# Pre-release gates (all run before any build, all mismatches printed):
#   1. the working tree is clean;
#   2. the version is consistent across VERSION, the CHANGELOG's latest entry,
#      both READMEs (current-version line, DMG name, build-release example),
#      and an existing docs/releases/<version>.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(tr -d '\r\n ' < "$ROOT_DIR/VERSION")}"
BUILD_NUMBER="${2:-$(tr -d '\r\n ' < "$ROOT_DIR/.build_number")}"

if [ $# -gt 2 ]; then
    echo "ERROR: usage: $0 [version] [build-number]" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Pre-release gates. Both run before any build so a rejected release costs
# nothing; every mismatch is printed (not just the first) before exiting.
# ---------------------------------------------------------------------------

echo "==> Gate: clean working tree"
GATE_ERRORS=()

DIRTY="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)"
if [ -n "$DIRTY" ]; then
    GATE_ERRORS+=("工作区不干净：$(printf '%s' "$DIRTY" | wc -l | tr -d ' ') 个条目（先提交或 stash 再发布）")
fi

echo "==> Gate: version consistency ($VERSION)"
FILE_VERSION="$(tr -d '\r\n ' < "$ROOT_DIR/VERSION")"
if [ "$FILE_VERSION" != "$VERSION" ]; then
    GATE_ERRORS+=("VERSION 文件 = '$FILE_VERSION'，本次发布版本 = '$VERSION'")
fi

CHANGELOG_VERSION="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT_DIR/CHANGELOG.md" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [ "$CHANGELOG_VERSION" != "$VERSION" ]; then
    GATE_ERRORS+=("CHANGELOG.md 最新条目 = '${CHANGELOG_VERSION:-<none>}'，本次发布版本 = '$VERSION'")
fi

for readme in README.md README.en.md; do
    # README 里有四处版本串：当前版本、DMG 文件名、build-release 示例命令。
    while IFS= read -r found; do
        if [ "$found" != "$VERSION" ]; then
            GATE_ERRORS+=("$readme 含版本串 '$found'（应为 '$VERSION'）")
        fi
    done < <(grep -oE "LLM-monitor-[0-9]+\.[0-9]+\.[0-9]+\.dmg|build-release\.sh [0-9]+\.[0-9]+\.[0-9]+" \
        "$ROOT_DIR/$readme" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    while IFS= read -r found; do
        if [ "$found" != "$VERSION" ]; then
            GATE_ERRORS+=("$readme 的「当前版本」行 = '$found'，应为 '$VERSION'")
        fi
    done < <(grep -m1 -oE '\*\*[0-9]+\.[0-9]+\.[0-9]+\*\*' "$ROOT_DIR/$readme" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
done

if [ ! -f "$ROOT_DIR/docs/releases/$VERSION.md" ]; then
    GATE_ERRORS+=("缺少发布说明：docs/releases/$VERSION.md")
fi

if [ ${#GATE_ERRORS[@]} -gt 0 ]; then
    echo >&2
    echo "ERROR: 发布前置检查未通过，共 ${#GATE_ERRORS[@]} 项：" >&2
    for err in "${GATE_ERRORS[@]}"; do
        echo "  - $err" >&2
    done
    exit 1
fi
echo "    OK"

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
