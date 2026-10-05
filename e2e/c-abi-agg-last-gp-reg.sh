#!/bin/sh
# e2e/c-abi-agg-last-gp-reg.sh — End-to-end test that a 16-byte by-value aggregate
# arriving after seven integer arguments — with only one general-purpose argument
# register left on aarch64 (x7), none on x86-64 — travels between Binate and C
# exactly as the platform C ABI places it, in both directions and on both backends.
#
# AAPCS64 never splits such an aggregate: it goes wholly to the stack and the
# remaining register stays unused, so a following argument goes to the stack too
# (stage C.13); SysV-AMD64 passes it in memory.  Both kinds are checked: a raw slice
# (a first-class `{ptr, len}` aggregate, `struct { long *p; long n; }` in C) and a
# struct of two int64.  Directions: Binate calls C (`__c_call`, also one returning a
# struct through a hidden sret pointer), C calls a `#[c_export]` function (also one
# returning three ints, which C receives through sret and Binate returns in registers,
# so it goes through an adapting entry), and C calls a function handed to it with
# `__c_entry`.  A mismatch reads a field from the wrong place and prints a different
# number.
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_agg_last_gp.XXXXXX")"
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

# a + g + <field0> * 100 + <field1> * 1000 + z * 10000 for (1..7, {5, 3} or {6, 7}, 9);
# the C-calls-Binate total adds the struct result times 10^6.
WANT="93508
97608
97608093508
93508
93508
93508"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-abi-agg-last-gp-reg (no C compiler '$CLANG' available)"
    summary
fi

cat > "$TMP/cside.c" <<'EOF'
/* A raw slice is struct { T *data; ptrdiff_t len; }; S16 is the Binate struct. */
struct Sl { long *p; long n; };
struct S16 { long a, b; };

long c_take_slice(long a, long b, long c, long d, long e, long f, long g, struct Sl s, long z) {
    return a + g + s.p[0] * 100 + s.n * 1000 + z * 10000;
}

long c_take_s16(long a, long b, long c, long d, long e, long f, long g, struct S16 s, long z) {
    return a + g + s.a * 100 + s.b * 1000 + z * 10000;
}

extern long bn_take_slice(long, long, long, long, long, long, long, struct Sl, long);
extern long bn_take_s16(long, long, long, long, long, long, long, struct S16, long);

long c_call_exports(void) {
    long arr[3] = {5, 0, 0};
    struct Sl s = {arr, 3};
    struct S16 t = {6, 7};
    return bn_take_slice(1, 2, 3, 4, 5, 6, 7, s, 9) +
           bn_take_s16(1, 2, 3, 4, 5, 6, 7, t, 9) * 1000000;
}

struct Big3 { long a, b, c; };

struct Big3 c_take_slice_big(long a, long b, long c, long d, long e, long f, long g,
                             struct Sl s, long z) {
    struct Big3 r = {a + g, s.p[0] * 100 + s.n * 1000, z * 10000};
    return r;
}

extern struct Big3 bn_take_tuple(long, long, long, long, long, long, long, struct Sl, long);

long c_call_tuple(void) {
    long arr[3] = {5, 0, 0};
    struct Sl s = {arr, 3};
    struct Big3 r = bn_take_tuple(1, 2, 3, 4, 5, 6, 7, s, 9);
    return r.a + r.b + r.c;
}

long c_call_cb(long (*cb)(long, long, long, long, long, long, long, struct Sl, long)) {
    long arr[3] = {5, 0, 0};
    struct Sl s = {arr, 3};
    return cb(1, 2, 3, 4, 5, 6, 7, s, 9);
}
EOF

cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

type S16 struct {
	a int
	b int
}

type Big3 struct {
	a int
	b int
	c int
}

#[c_export("bn_take_slice")]
func takeSlice(a int, b int, c int, d int, e int, f int, g int, s *[]int, z int) int {
	return a + g + s[0] * 100 + len(s) * 1000 + z * 10000
}

#[c_export("bn_take_tuple")]
func takeTuple(a int, b int, c int, d int, e int, f int, g int, s *[]int, z int) (int, int, int) {
	return a + g, s[0] * 100 + len(s) * 1000, z * 10000
}

#[c_export("bn_take_s16")]
func takeS16(a int, b int, c int, d int, e int, f int, g int, s S16, z int) int {
	return a + g + s.a * 100 + s.b * 1000 + z * 10000
}

func main() {
	var arr [3]int
	arr[0] = 5
	var s *[]int = arr[:]
	var t S16
	t.a = 6
	t.b = 7
	testing.Println(__c_call("c_take_slice", int, 1, 2, 3, 4, 5, 6, 7, s, 9))
	testing.Println(__c_call("c_take_s16", int, 1, 2, 3, 4, 5, 6, 7, t, 9))
	testing.Println(__c_call("c_call_exports", int))
	testing.Println(__c_call("c_call_cb", int, __c_entry(takeSlice)))
	var r Big3 = __c_call("c_take_slice_big", Big3, 1, 2, 3, 4, 5, 6, 7, s, 9)
	testing.Println(r.a + r.b + r.c)
	testing.Println(__c_call("c_call_tuple", int))
}
EOF

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
#   Compile the C side for the HOST arch, compile+link the Binate program against it
#   with the given backend, run, and check the output.  A build failure on either
#   backend is a FAIL.
check_backend() {
    label="$1"; extra="$2"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$CLANG" -c -O2 -o "$work/cside.o" "$TMP/cside.c" 2>"$work/cc.err"; then
        fail "$label: C side compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra \
            --link-after-objs "$work/cside.o" --build-dir "$work" \
            -o "$work/run" "$TMP/main.bn" >"$work/comp.log" 2>&1 \
            || [ ! -x "$work/run" ]; then
        fail "$label: compile/link of the Binate program failed" \
             "$(tail -5 "$work/comp.log")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT" ]; then
        pass "$label: aggregates after seven ints agree with C both ways"
    else
        fail "$label: an aggregate after seven ints was mis-placed" \
             "got:  $(echo $got)" \
             "want: $(echo $WANT)"
    fi
}

check_backend "llvm" "-O2"
check_backend "native" "--backend native -O2"

summary
