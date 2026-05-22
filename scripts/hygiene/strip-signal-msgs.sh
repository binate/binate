#!/bin/sh
# Smoke-test scripts/lib/strip-signal-msgs.sh against the patterns
# it's expected to filter (Linux shell signal messages, qemu-user
# `uncaught target signal` lines, GNU timeout's dumped-core
# postscript) and the things it must NOT filter (real program
# output that happens to look adjacent).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

. "$BINATE_DIR/scripts/lib/strip-signal-msgs.sh"

fails=0
check() {
    label="$1"
    input="$2"
    expected="$3"
    actual="$(strip_signal_msgs "$input")"
    if [ "$actual" = "$expected" ]; then
        return 0
    fi
    fails=$((fails + 1))
    echo "FAIL: $label" >&2
    echo "  input:    $(printf '%s' "$input" | sed 's/^/    /')" >&2
    echo "  expected: $(printf '%s' "$expected" | sed 's/^/    /')" >&2
    echo "  actual:   $(printf '%s' "$actual" | sed 's/^/    /')" >&2
}

# --- shell-emitted signal messages ---
check "shell SIGSEGV" \
    "before
Segmentation fault" \
    "before"
check "shell SIGSEGV core" \
    "before
Segmentation fault (core dumped)" \
    "before"
check "shell SIGABRT" \
    "before
Aborted (core dumped)" \
    "before"
check "shell SIGKILL" \
    "before
Killed" \
    "before"

# --- qemu-user diagnostics ---
check "qemu-arm uncaught" \
    "before
qemu: uncaught target signal 11 (Segmentation fault) - core dumped" \
    "before"
check "qemu-aarch64-static variant" \
    "before
qemu-aarch64-static: uncaught target signal 6 (Aborted) - core dumped" \
    "before"

# --- GNU timeout postscript ---
check "timeout dumped core" \
    "before
timeout: the monitored command dumped core" \
    "before"

# --- combined (qemu + timeout, the arm32-linux SEGV shape) ---
check "qemu + timeout combo" \
    "before
qemu: uncaught target signal 11 (Segmentation fault) - core dumped
timeout: the monitored command dumped core" \
    "before"

# --- pass-through: real program output that mentions signals
# but isn't an out-of-band diagnostic.  These look superficially
# similar but don't match the anchored patterns (Segmentation fault
# must be the WHOLE line; "qemu:" must be at start-of-line; etc.).
check "user mentions Segmentation fault mid-line" \
    "Reason: Segmentation fault was here" \
    "Reason: Segmentation fault was here"
check "user emits qemu prefix with extra text" \
    "qemu: something else entirely" \
    "qemu: something else entirely"
check "empty input" "" ""
check "no-op single line" "hello world" "hello world"

if [ "$fails" -gt 0 ]; then
    echo "" >&2
    echo "strip-signal-msgs smoke: $fails case(s) failed" >&2
    exit 1
fi

echo "PASS: strip-signal-msgs smoke"
