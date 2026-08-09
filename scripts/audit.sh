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

echo "==> Building with Swift 6 language mode"
swift build -Xswiftc -swift-version -Xswiftc 6

echo "==> Building release with Swift 6 language mode"
swift build -c release -Xswiftc -swift-version -Xswiftc 6

echo "✓ Audit gates passed"
