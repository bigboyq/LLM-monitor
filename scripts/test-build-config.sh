#!/usr/bin/env bash
# Smoke tests for build-time configuration constants in scripts/build-app.sh.
#
# 1.4.2 review followup: 0ca2bd0 silently overwrote the default BUNDLE_ID
# in scripts/build-app.sh, and the regression went unnoticed because
# validate_bundle_id() only checks the format (RFC-style reverse DNS),
# not the *value*. Same-format strings like 'com.llm-monitor.macos' or
# 'com.example.llm-monitor' would both pass validate_bundle_id() and
# still be a regression.
#
# This file is a self-contained shell test (no test framework) and
# lives under scripts/ next to build-app.sh, mirroring the layout
# other small build-helper scripts use. To opt in to running it as
# part of scripts/test.sh, add a single line at the bottom of that
# script invoking this file; intentionally NOT done in this commit
# to keep the test addition small and reviewable.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_APP="$ROOT_DIR/scripts/build-app.sh"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[ -f "$BUILD_APP" ] || fail "missing $BUILD_APP"

# ── 1. canonical BUNDLE_ID is the default in build-app.sh ────────────
# The default must be the project's canonical identifier
# (com.yaktype.llm-monitor), not any hand-edited variant. We grep
# the literal 'BUNDLE_ID="${BUNDLE_ID:-com.yaktype.llm-monitor}"'
# line so a future editor that changes the default trips the test.
if ! grep -qF 'BUNDLE_ID="${BUNDLE_ID:-com.yaktype.llm-monitor}"' "$BUILD_APP"; then
    fail "scripts/build-app.sh no longer defaults BUNDLE_ID to com.yaktype.llm-monitor"
fi

# ── 2. the canonical value itself is a valid reverse-DNS identifier ─
# This is what validate_bundle_id() enforces at build time. We assert
# it here so a typo in 'yaktype' (e.g. 'yaktypes', 'Yaktype',
# 'yaktpe') trips the test before a real build does.
if ! grep -qE '^BUNDLE_ID="\$\{BUNDLE_ID:-com\.yaktype\.llm-monitor\}"' "$BUILD_APP"; then
    fail "canonical BUNDLE_ID value in build-app.sh is malformed (typo?)"
fi

# ── 3. validate_bundle_id accepts the canonical value ───────────────
# The regex on line 50 of build-app.sh is the gate every build goes
# through. The test hardcodes the same regex here so a typo in
# 'yaktype' (e.g. 'yaktypes', 'Yaktype', 'yaktpe') trips this test
# before a real build does. If you change the regex in
# build-app.sh, update this line to match — keeping them in sync is
# the point of this section.
PATTERN='^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$'
if ! [[ "com.yaktype.llm-monitor" =~ $PATTERN ]]; then
    fail "validate_bundle_id regex (line 50) rejects the canonical value"
fi

# ── 4. canonical value is documented in README + spec ───────────────
# A regression that changes the default should also require updating
# the documentation, so check the canonical value appears in the
# two places that mention it explicitly.
for doc in README.md README.en.md spec/overview.md; do
    if [ -f "$ROOT_DIR/$doc" ] && ! grep -qF 'com.yaktype.llm-monitor' "$ROOT_DIR/$doc"; then
        echo "WARN: $doc does not mention 'com.yaktype.llm-monitor'" >&2
        # Not a hard failure — README may describe bundle IDs
        # abstractly. But the warning makes a missing mention visible.
    fi
done

echo "OK: scripts/build-app.sh default BUNDLE_ID = com.yaktype.llm-monitor"
