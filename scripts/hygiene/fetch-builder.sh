#!/bin/sh
# Smoke-test scripts/fetch-builder.sh: fetch the builder, confirm the
# resolved binary exists and runs against a trivial conformance test.
# Skips silently if the prerequisites for the configured
# BUILDER_VERSION aren't met (e.g. bootstrap repo missing) — the
# hygiene check is about catching fetcher regressions, not about
# enforcing dev-environment setup.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILDER_VERSION="$(tr -d '[:space:]' < "$BINATE_DIR/BUILDER_VERSION" 2>/dev/null || true)"
if [ -z "$BUILDER_VERSION" ]; then
    echo "fetch-builder smoke: BUILDER_VERSION not set — skipping"
    exit 0
fi

case "$BUILDER_VERSION" in
    bootstrap-*)
        if [ ! -d "$BINATE_DIR/../bootstrap" ]; then
            echo "fetch-builder smoke: ../bootstrap missing — skipping"
            exit 0
        fi
        ;;
esac

BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
if [ ! -x "$BUILDER" ]; then
    echo "fetch-builder smoke: resolved path is not executable: $BUILDER" >&2
    exit 1
fi

# Run it against the simplest conformance test as an end-to-end check.
output="$("$BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/conformance/001_hello.bn" 2>&1)"
expected="$(cat "$BINATE_DIR/conformance/001_hello.expected")"
if [ "$output" != "$expected" ]; then
    echo "fetch-builder smoke: 001_hello output mismatch" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $output" >&2
    exit 1
fi

# --lib mode: must print a non-empty path.  For bootstrap-* this is
# $BINATE_DIR; for bnc-* this is the bundle's lib/.  Either way the
# fetcher must not return empty or fail.
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
if [ -z "$BUILDER_LIB" ]; then
    echo "fetch-builder smoke: --lib returned empty path" >&2
    exit 1
fi
if [ ! -d "$BUILDER_LIB" ]; then
    echo "fetch-builder smoke: --lib path is not a directory: $BUILDER_LIB" >&2
    exit 1
fi

# --tool with an unknown name: must exit non-zero with a diagnostic.
# Catches a regression where the validation switch silently accepts
# typos and produces a bogus binary path.
if "$BINATE_DIR/scripts/fetch-builder.sh" --tool bogus_tool >/dev/null 2>&1; then
    echo "fetch-builder smoke: --tool bogus_tool should have failed" >&2
    exit 1
fi

# --tool with a name that's invalid for bootstrap-* (e.g. bni): must
# fail for bootstrap-* (single Go binary, no toolchain bundle) but
# succeed for bnc-* (bundle ships all four).
case "$BUILDER_VERSION" in
    bootstrap-*)
        if "$BINATE_DIR/scripts/fetch-builder.sh" --tool bni >/dev/null 2>&1; then
            echo "fetch-builder smoke: --tool bni should have failed under $BUILDER_VERSION" >&2
            exit 1
        fi
        ;;
esac

echo "PASS: fetch-builder smoke ($BUILDER_VERSION)"
