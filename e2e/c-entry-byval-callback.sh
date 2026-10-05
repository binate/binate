#!/bin/sh
# e2e/c-entry-byval-callback.sh — End-to-end test that a Binate callback taking a
# >16-byte struct BY VALUE, handed to C via `__c_entry`, receives the struct
# correctly from a real C caller.
#
# `__c_entry(f)` yields a C-callable pointer to a Binate function.  Binate passes a
# >16-byte aggregate exactly as the platform C ABI does — SysV-AMD64 in memory (bytes
# on the outgoing stack), AAPCS32 by value split across r0-r3 + stack, AAPCS64 as a
# pointer to a copy — so the pointer is f's mangled entry itself, with no adapting
# thunk, and a C caller's by-value struct must arrive intact.
#
# The C caller constructs a Big{a,b,c} = {1,2,3} and calls the callback with it BY
# VALUE.  The callback returns a*100 + b*10 + c = 123 iff all three fields survived
# the call; a mis-ABI'd struct (the entry reading the struct from the wrong place)
# yields some other value.
#
# Both backends are checked — LLVM and native (--backend native) — and a build
# failure on either is a FAIL.
#
# Uses a gen1 bnc built from current source.  Auto-discovered by
# .github/workflows/e2e-tests.yml on Linux + macOS; skips if no C compiler.
#
# Exit 0 on pass; non-zero with diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || command -v cc || echo cc)}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_centry_byval.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSES=0
FAILS=0
SKIPS=0
FAIL_NAMES=""
pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }
fail() {
    echo "FAIL: $1"
    FAIL_NAMES="$FAIL_NAMES ${1%% *}"
    shift
    for line in "$@"; do echo "  $line"; done
    FAILS=$((FAILS + 1))
}

summary() {
    echo ""
    echo "=== Summary: $PASSES passed, $FAILS failed, $SKIPS skipped ==="
    if [ "$FAILS" -ne 0 ]; then
        echo "Failed:$FAIL_NAMES"
        exit 1
    fi
    exit 0
}

# cb returns a*100 + b*10 + c = 123 iff it saw the whole {1,2,3} struct.
WANT="123"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-entry-byval-callback (no C compiler '$CLANG' available)"
    summary
fi

# --- the C caller: pass a >16-byte struct BY VALUE to the Binate callback -----
cat > "$TMP/ccall.c" <<'EOF'
/* A 24-byte (three int64) struct — >16 bytes, so the platform C ABI passes it in
 * memory (SysV MEMORY class), split across r0-r3 + stack (AAPCS32) or as a pointer
 * to a copy (AAPCS64) — the same way Binate passes it. */
struct Big { long long a, b, c; };

/* Construct a known struct and hand it to the Binate callback BY VALUE. */
int call_big_cb(int (*cb)(struct Big)) {
    struct Big s;
    s.a = 1;
    s.b = 2;
    s.c = 3;
    return cb(s);
}
EOF

# --- the Binate program: hand cb to C via __c_entry, check the struct fields --
cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

// A callback taking a >16-byte struct BY VALUE.  It reads all three fields, which a
// mis-ABI'd by-value parameter (the entry reading the struct from the wrong place)
// corrupts.
type Big struct { a int64; b int64; c int64 }

func cb(s Big) int32 {
	return cast(int32, s.a * 100 + s.b * 10 + s.c)
}

func main() {
	// C constructs Big{1,2,3} and passes it to cb BY VALUE; cb returns 123 iff all
	// three fields arrived intact.
	var r int32 = __c_call("call_big_cb", int32, __c_entry(cb))
	testing.Println(cast(int, r))
}
EOF

# --- build gen1 bnc from current source ---------------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    fail "gen1 bnc build failed" "$(echo "$gen1_log" | tail -5)"
    summary
fi

IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# check_backend <label> <extra-bnc-flags>
#   Compile the C caller for the HOST arch, compile+link the Binate program against
#   it with the given backend, run, and check the output.
#   A build failure is a FAIL on either backend: bnc has a native backend for
#   every host architecture it runs on, so a native build failure is a defect.
check_backend() {
    label="$1"; extra="$2"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$CLANG" -c -O2 -o "$work/ccall.o" "$TMP/ccall.c" 2>"$work/cc.err"; then
        fail "$label: C caller compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra \
            --link-after-objs "$work/ccall.o" --build-dir "$work" \
            -o "$work/run" "$TMP/main.bn" >"$work/comp.log" 2>&1 \
            || [ ! -x "$work/run" ]; then
        fail "$label: compile/link of the Binate program failed" \
             "$(tail -5 "$work/comp.log")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT" ]; then
        pass "$label: byval-struct __c_entry callback saw all fields ('$got')"
    else
        fail "$label: byval-struct __c_entry callback field mismatch" \
             "got:  $got" \
             "want: $WANT (a value != 123 => the by-value struct was mis-marshaled)"
    fi
}

check_backend "llvm" "-O2"
check_backend "native" "--backend native -O2"

summary
