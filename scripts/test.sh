#!/usr/bin/env bash
# Run the test suite. Build numbers are only mutated when explicitly requested.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
    echo "ERROR: $*" >&2
    exit 2
}

INCREMENT_BUILD_NUMBER_VALUE="${INCREMENT_BUILD_NUMBER-0}"
case "$INCREMENT_BUILD_NUMBER_VALUE" in
    0|1) ;;
    *) fail "INCREMENT_BUILD_NUMBER 只能是 0 或 1" ;;
esac

BUILD_FILE="$ROOT_DIR/.build_number"
NEXT_BUILD_NUMBER=""
if [ "$INCREMENT_BUILD_NUMBER_VALUE" = "1" ]; then
    if [ -f "$BUILD_FILE" ]; then
        CURRENT_BUILD_NUMBER=$(<"$BUILD_FILE")
    else
        # 保持旧行为：缺失时以 1 为初始编号；测试成功后才落盘为 2。
        CURRENT_BUILD_NUMBER="1"
    fi

    # 限制到 18 位既拒绝空白、符号和算术表达式，也保证 bash 有符号整数加一不溢出。
    if [[ ! "$CURRENT_BUILD_NUMBER" =~ ^[1-9][0-9]{0,17}$ ]]; then
        fail ".build_number 必须是 1 到 18 位的正整数"
    fi
    NEXT_BUILD_NUMBER=$((10#$CURRENT_BUILD_NUMBER + 1))
fi

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-monitor-tests.XXXXXX")"
BUILD_TMP_FILE=""
cleanup() {
    rm -rf "$TEST_TMP_DIR"
    if [ -n "$BUILD_TMP_FILE" ]; then
        rm -f "$BUILD_TMP_FILE"
    fi
}
trap cleanup EXIT
export LLM_MONITOR_LOG_PATH="$TEST_TMP_DIR/log.txt"

echo "==> Running swift test..."
swift test

if [ "$INCREMENT_BUILD_NUMBER_VALUE" = "1" ]; then
    BUILD_TMP_FILE="$(mktemp "$ROOT_DIR/.build_number.tmp.XXXXXX")"
    printf '%s\n' "$NEXT_BUILD_NUMBER" > "$BUILD_TMP_FILE"
    mv "$BUILD_TMP_FILE" "$BUILD_FILE"
    BUILD_TMP_FILE=""
    echo "==> [Version Manager] Incremented build number to $NEXT_BUILD_NUMBER"
fi
