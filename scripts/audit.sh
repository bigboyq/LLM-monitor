#!/usr/bin/env bash
# Reproducible local audit gate for the project.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

AUDIT_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-monitor-audit.XXXXXX")"
cleanup() {
    rm -rf "$AUDIT_TMP_DIR"
}
trap cleanup EXIT
export LLM_MONITOR_LOG_PATH="$AUDIT_TMP_DIR/log.txt"

echo "==> Validating shell scripts"
for script in scripts/*.sh; do
    bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
    echo "==> Running shellcheck"
    shellcheck -x scripts/*.sh
fi

echo "==> Validating Package.swift"
swift package dump-package >/dev/null

echo "==> Running tests"
swift test

echo "==> Building release"
swift build -c release

echo "==> Building release (arm64) with arch gate"
swift build -c release --arch arm64
# SwiftPM 的实际 products 目录会随 toolchain / build system 改变（例如
# `.build/arm64-apple-macosx/release` 或 `.build/out/Products/Release`）。必须问
# SwiftPM 本次构建的真实目录，不能按历史路径优先级猜测——猜测链会静默拾上一步
# 普通 `swift build -c release` 留下的 universal 产物，架构门禁形同虚设。
SWIFT_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
RELEASE_BIN="$SWIFT_BIN_DIR/LLM-monitor"
if [ ! -f "$RELEASE_BIN" ]; then
    echo "ERROR: release binary not found in SwiftPM bin path: $RELEASE_BIN" >&2
    exit 1
fi
RELEASE_ARCHS=$(lipo -archs "$RELEASE_BIN" 2>/dev/null || true)
echo "    Architectures: ${RELEASE_ARCHS:-<unknown>}"
echo "$RELEASE_ARCHS" | grep -qw arm64
if echo "$RELEASE_ARCHS" | grep -qw x86_64; then
    echo "ERROR: release binary must be arm64-only, got: '$RELEASE_ARCHS'" >&2
    exit 1
fi

echo "==> Building with Swift 6 language mode"
swift build -Xswiftc -swift-version -Xswiftc 6

echo "==> Building release with Swift 6 language mode"
swift build -c release -Xswiftc -swift-version -Xswiftc 6

echo "✓ Audit gates passed"
