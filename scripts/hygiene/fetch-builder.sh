#!/bin/sh
# Smoke-test scripts/fetch-builder.sh: fetch the builder, confirm the
# resolved binary exists and runs against a trivial conformance test.
# Skips silently if BUILDER_VERSION is unset — the hygiene check is
# about catching fetcher regressions, not about enforcing
# dev-environment setup.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILDER_VERSION="$(tr -d '[:space:]' < "$BINATE_DIR/BUILDER_VERSION" 2>/dev/null || true)"
if [ -z "$BUILDER_VERSION" ]; then
    echo "fetch-builder smoke: BUILDER_VERSION not set — skipping"
    exit 0
fi

BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
if [ ! -x "$BUILDER" ]; then
    echo "fetch-builder smoke: resolved path is not executable: $BUILDER" >&2
    exit 1
fi
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"

# End-to-end check: compile + run a self-contained minimal program through the
# resolved BUILDER — proving the fetched bnc actually compiles, links, and runs.
# The canary source is written HERE, not read from the conformance suite, so the
# conformance tests stay free to evolve without breaking this smoke check.  It
# exercises stdlib fmt + the runtime, both shipped in the pinned BUILDER bundle.
TMP="$(mktemp -d -t binate-fetch-builder-smoke.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/canary.bn"
BIN="$TMP/canary"
cat > "$SRC" <<'CANARY'
package "main"

import "pkg/stdx/fmt"

func main() {
	fmt.Println("hello, binate")
}
CANARY
expected="hello, binate"
build_log="$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB")" \
    --build-dir "$TMP" -o "$BIN" \
    "$SRC" 2>&1)" || true
if [ ! -x "$BIN" ]; then
    echo "fetch-builder smoke: canary compile failed under $BUILDER_VERSION" >&2
    echo "$build_log" >&2
    exit 1
fi
output="$("$BIN" 2>&1)"
if [ "$output" != "$expected" ]; then
    echo "fetch-builder smoke: canary output mismatch" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $output" >&2
    exit 1
fi

# --lib already resolved above for the compile.  Sanity-check the
# value: must be a non-empty existing directory (the bundle's lib/).
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

# --tool bni must resolve to a bundled binary: a bnc-* bundle ships all
# four tools, so a non-default tool name should return an executable.
bni_path="$("$BINATE_DIR/scripts/fetch-builder.sh" --tool bni 2>/dev/null || true)"
if [ -z "$bni_path" ] || [ ! -x "$bni_path" ]; then
    echo "fetch-builder smoke: --tool bni did not resolve to a binary" >&2
    exit 1
fi

echo "PASS: fetch-builder smoke ($BUILDER_VERSION)"
