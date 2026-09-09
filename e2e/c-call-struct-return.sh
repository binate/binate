#!/bin/sh
# e2e/c-call-struct-return.sh — End-to-end test that `__c_call` returns an
# AGGREGATE (struct) by value correctly across the ABI boundary, on both backends.
#
# `__c_call("sym", RetType, ...)` calls a C function returning RetType.  Aggregate
# returns are lowered per the platform C ABI, reusing Binate's own
# aggregate-return machinery (whose sret cutoff and register coercion are pinned to
# the C ABI): a >16-byte struct returns via a hidden sret buffer; a smaller
# struct returns register-coerced (GP `[N x iW]`; a float struct via x86-64 SSE or
# aarch64 HFA registers).  This links three C functions returning structs by value
# and checks Binate reads every field:
#   mkBig   -> {1,2,3}      (24B > 16 -> sret)          a+b+c = 6
#   mkSmall -> {10,20}      (8B       -> GP coerce)      a+b   = 30
#   mkFP    -> {1.5,2.5}    (8B float -> SSE / HFA regs) x+y   = 4
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_ccall_ret.XXXXXX")"
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

WANT="$(printf '6\n30\n4')"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-call-struct-return (no C compiler '$CLANG' available)"
    summary
fi

# --- the C side: three functions returning structs by value --------------------
cat > "$TMP/lib.c" <<'EOF'
struct Big   { long long a, b, c; };   /* 24B > 16 -> sret */
struct Small { int a, b; };            /* 8B       -> GP coerce */
struct FP    { float x, y; };          /* 8B float -> x64 SSE / aa64 HFA */
struct Big   mkBig(void)   { struct Big   s = {1, 2, 3};      return s; }
struct Small mkSmall(void) { struct Small s = {10, 20};       return s; }
struct FP    mkFP(void)    { struct FP    s = {1.5f, 2.5f};   return s; }
EOF

# --- the Binate program: __c_call each and check every field -------------------
cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

type Big struct { a int64; b int64; c int64 }
type Small struct { a int32; b int32 }
type FP struct { x float32; y float32 }

func main() {
	var big Big = __c_call("mkBig", Big)          // sret (24 bytes)
	testing.Println(cast(int, big.a + big.b + big.c))
	var sm Small = __c_call("mkSmall", Small)      // GP-coerced (8 bytes)
	testing.Println(cast(int, sm.a + sm.b))
	var fp FP = __c_call("mkFP", FP)               // SSE / HFA float struct
	testing.Println(cast(int, fp.x + fp.y))
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
check_backend() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$CLANG" -c -O2 -o "$work/lib.o" "$TMP/lib.c" 2>"$work/cc.err"; then
        fail "$label: C side compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra \
            --link-after-objs "$work/lib.o" --build-dir "$work" \
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
        pass "$label: __c_call struct returns (sret / GP / float) all read correctly"
    else
        fail "$label: __c_call struct-return field mismatch" \
             "got:  $got" \
             "want: $WANT (6=sret struct, 30=GP struct, 4=float struct)"
    fi
}

check_backend "llvm" "-O2" 1
check_backend "native" "--backend native -O2" 0

summary
