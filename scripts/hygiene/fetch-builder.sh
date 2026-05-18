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

echo "PASS: fetch-builder smoke ($BUILDER_VERSION)"
