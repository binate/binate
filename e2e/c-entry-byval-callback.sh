#!/bin/sh
# e2e/c-entry-byval-callback.sh — End-to-end test that a Binate callback taking a
# >16-byte struct BY VALUE, handed to C via `__c_entry`, receives the struct
# correctly across the ABI boundary — EXERCISING the `__centry.<mangled>` by-value
# parameter adaptation thunk with a real C caller.
#
# `__c_entry(f)` yields a C-callable pointer to a Binate function.  When f takes a
# >16-byte aggregate BY VALUE, the platform C ABI passes it in a form that differs
# from Binate's internal single-pointer convention: SysV-AMD64 passes it MEMORY
# class (bytes on the outgoing stack) and AAPCS32 by value (split r0-r3 + stack),
# whereas the mangled entry expects a POINTER to the struct.  So a C caller of the
# raw mangled entry would hand over the struct bytes while the entry reads a pointer
# — a silent mis-ABI.  The backend therefore hands `__c_entry(f)` a weak
# `__centry.<mangled f>` thunk that gathers the by-value struct into a contiguous
# slot and passes the mangled entry a pointer.  (AAPCS64 passes a >16-byte aggregate
# indirectly BOTH ways, so no thunk is needed there — on an aarch64 host this test is
# a parity check that confirms the two backends agree; on an x86-64 host it exercises
# the byval adaptation thunk directly.)
#
# The C caller constructs a Big{a,b,c} = {1,2,3} and calls the callback with it BY
# VALUE.  The callback returns a*100 + b*10 + c = 123 iff all three fields survived
# the marshaling; a mis-ABI'd struct (the entry reading a stray pointer as the
# struct) yields some other value.  Verified while writing: with the pre-fix bnc
# (which referenced the raw mangled entry) the arm32/x86-64 --emit-llvm output
# carried NO __centry thunk, so a C caller mis-passed the struct; with the fix it
# emits the thunk and the callback reads {1,2,3}.
#
# Both backends are checked: LLVM (always) and native (--backend native, which on
# the aa64/x64 CI hosts emits + links this program; self-skips if the host's native
# backend can't build it).
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
/* A 24-byte (three int64) struct — >16 bytes, so the platform C ABI passes it BY
 * VALUE (SysV MEMORY class / AAPCS32 split), a form that diverges from Binate's
 * internal single-pointer convention.  The __c_entry adaptation thunk gathers the
 * by-value struct into a pointer before calling the mangled entry. */
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

// A callback taking a >16-byte struct BY VALUE.  It reads all three fields — the
// case a mis-ABI'd by-value parameter (the entry reading a stray pointer as the
// struct) corrupts if the C entry does not re-marshal the by-value struct into the
// pointer the mangled entry expects (the __c_entry adaptation thunk's job).
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

# check_backend <label> <extra-bnc-flags> <required>
#   Compile the C caller for the HOST arch, compile+link the Binate program against
#   it with the given backend, run, and check the output.  required=1 -> a compile
#   failure is a hard FAIL (LLVM); required=0 -> a native backend that can't build
#   this program on this host SKIPs.
check_backend() {
    label="$1"; extra="$2"; required="$3"
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
        if [ "$required" -eq 1 ]; then
            fail "$label: compile/link of the Binate program failed" \
                 "$(tail -5 "$work/comp.log")"
        else
            skip "$label: native backend cannot build this program on this host"
        fi
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

check_backend "llvm" "-O2" 1
check_backend "native" "--backend native -O2" 0

summary
