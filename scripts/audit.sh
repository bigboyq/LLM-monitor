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
RELEASE_BIN="$ROOT_DIR/.build/apple/Products/Release/LLM-monitor"
[ -f "$RELEASE_BIN" ] || RELEASE_BIN="$ROOT_DIR/.build/release/LLM-monitor"
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
