#!/bin/sh
# e2e/c-call-variadic-hfa.sh — End-to-end test that a VARIADIC Homogeneous
# Floating-point Aggregate (HFA) `__c_call` argument crosses the C ABI boundary
# correctly on aarch64, with a real C `va_arg` callee.
#
# Apple's arm64 ABI (DarwinPCS) passes EVERY variadic argument on the stack,
# composites included — unlike a FIXED HFA, which rides the SIMD arg registers
# v0..v(n-1).  The native aa64 backend used to place a variadic HFA in D
# registers anyway (it saturated only the GP cursor at the fixed/variadic
# boundary and its FP-file emit branch lacked the VariadicStackOnly guard), so
# clang's va_arg — which reads the composite from the stack — got garbage.  This
# test drives that path through a real C callee:
#
#   - a 2xfloat32 HFA (8 bytes) as the variadic arg (with a fixed scalar `n`
#     before the `...`, proving the fixed arg keeps its register while the HFA
#     stacks);
#   - a variadic double scalar followed by a variadic HFA (the FP cursor is
#     closed once for both);
#   - a 4xfloat32 HFA (16 bytes, hfaN=4) and a 2xfloat64 HFA (16 bytes, hfaW=8),
#     the wider member-count / member-width shapes.
#
# (The fixed-HFA-in-v-registers vs variadic-HFA-on-stack classification is pinned
# arch-independently by the pkg/binate/native/common walker unit tests; a fixed
# AGGREGATE param before `...` is not exercised here because it trips a separate,
# pre-existing LLVM-backend gap in the variadic call-site signature.)
#
# Every callee returns a value that sums to 42, so a wrong placement for any
# argument perturbs one number.
#
# On x86_64 the same program exercises SysV's variadic path (a small float
# aggregate rides XMM, AL carries the vector count) — a DIFFERENT code path that
# this fix does not touch; it is included as a bonus cross-check.  arm32 is
# deliberately omitted: its variadic-HFA rule (AAPCS-VFP base-standard, floats
# via GP/stack) is a separate mechanism, not the DarwinPCS stack-only rule.
#
# Both backends are checked: LLVM (always) and native (--backend native, which
# on the aa64/x64 CI hosts emits + links this program; self-skips if the host's
# native backend can't build it).  Built at -O2.
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_vhfa.XXXXXX")"
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

# Each callee's result is 42; one line per call.
WANT="42
42
42
42"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-call-variadic-hfa (no C compiler '$CLANG' available)"
    summary
fi

# --- the C callees: variadic HFAs read via va_arg -----------------------------
cat > "$TMP/vhfa.c" <<'EOF'
#include <stdarg.h>
#include <stdint.h>

struct V2 { float x, y; };          /* 2xfloat32 HFA, 8 bytes  */
struct V4 { float a, b, c, d; };    /* 4xfloat32 HFA, 16 bytes */
struct D2 { double p, q; };         /* 2xfloat64 HFA, 16 bytes */

/* n variadic V2 HFAs, summed. */
int sum_v2(int n, ...) {
    va_list ap; va_start(ap, n);
    float t = 0.0f;
    for (int i = 0; i < n; i++) { struct V2 v = va_arg(ap, struct V2); t += v.x + v.y; }
    va_end(ap);
    return (int)t;
}

/* Mixed variadic: a double scalar then a V2 HFA (one closed FP cursor). */
int mixed_double_v2(int n, ...) {
    va_list ap; va_start(ap, n);
    double d = va_arg(ap, double);
    struct V2 v = va_arg(ap, struct V2);
    va_end(ap);
    return (int)(d + (double)v.x + (double)v.y);
}

/* 4xfloat32 HFA variadic (hfaN=4). */
int sum_v4(int n, ...) {
    va_list ap; va_start(ap, n);
    float t = 0.0f;
    for (int i = 0; i < n; i++) {
        struct V4 v = va_arg(ap, struct V4);
        t += v.a + v.b + v.c + v.d;
    }
    va_end(ap);
    return (int)t;
}

/* 2xfloat64 HFA variadic (hfaW=8). */
int sum_d2(int n, ...) {
    va_list ap; va_start(ap, n);
    double t = 0.0;
    for (int i = 0; i < n; i++) { struct D2 v = va_arg(ap, struct D2); t += v.p + v.q; }
    va_end(ap);
    return (int)t;
}
EOF

# --- the Binate program: one variadic __c_call per shape ----------------------
cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

type V2 struct { x float32; y float32 }
type V4 struct { a float32; b float32; c float32; d float32 }
type D2 struct { p float64; q float64 }

func main() {
	// Two variadic 2xf32 HFAs: 10+11 + 9+12 = 42.
	var a V2
	a.x = 10.0
	a.y = 11.0
	var b V2
	b.x = 9.0
	b.y = 12.0
	testing.Println(cast(int, __c_call("sum_v2", int32, cast(int32, 2), ..., a, b)))

	// Variadic double scalar then a variadic HFA: 20 + 10+12 = 42.
	var e V2
	e.x = 10.0
	e.y = 12.0
	testing.Println(cast(int, __c_call("mixed_double_v2", int32,
			cast(int32, 2), ..., cast(float64, 20.0), e)))

	// One variadic 4xf32 HFA: 10+11+9+12 = 42.
	var q V4
	q.a = 10.0
	q.b = 11.0
	q.c = 9.0
	q.d = 12.0
	testing.Println(cast(int, __c_call("sum_v4", int32, cast(int32, 1), ..., q)))

	// One variadic 2xf64 HFA: 20+22 = 42.
	var r D2
	r.p = 20.0
	r.q = 22.0
	testing.Println(cast(int, __c_call("sum_d2", int32, cast(int32, 1), ..., r)))
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
    if ! "$CLANG" -c -O2 -o "$work/vhfa.o" "$TMP/vhfa.c" 2>"$work/cc.err"; then
        fail "$label: C callee compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra \
            --link-after-objs "$work/vhfa.o" --build-dir "$work" \
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
        pass "$label: variadic HFA __c_call args crossed the C ABI correctly"
    else
        fail "$label: variadic HFA __c_call argument mismatch" \
             "got:  $(echo "$got" | tr '\n' ' ')" \
             "want: five 42s (a variadic HFA in the wrong place perturbs one number)"
    fi
}

check_backend "llvm" "-O2" 1
check_backend "native" "--backend native -O2" 0

summary
