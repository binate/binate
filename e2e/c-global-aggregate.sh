#!/bin/sh
# e2e/c-global-aggregate.sh — End-to-end test that `__c_global` reaches an
# AGGREGATE C global (a struct) by address and reads/writes it correctly across
# the ABI boundary.
#
# `__c_global("sym", T)` yields the ADDRESS of the external C global `sym` as a raw
# `*T`.  T was long restricted to a scalar or pointer; it now admits any type with
# a defined ABI layout (the same widened C-representability `__c_call` applies to
# its arguments), so a C global struct/array is reachable.  This test defines a C
# global `struct Cfg g_cfg = {10,20,30}`, then from Binate: reads it whole through
# `*p` and checks the fields (10+20+30 = 60), writes a new value back through
# `*p = ...`, and calls a C function that re-reads `g_cfg` to confirm the write
# (100+200+300 = 600).
#
# Unlike the by-value PARAMETER case, an aggregate C GLOBAL is not
# ABI-divergent across targets — `__c_global` only ever materializes the symbol's
# ADDRESS (the pointee layout is the compiler's, and the C side owns the storage) —
# so this exercises the feature identically on every host.
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_cglobal_agg.XXXXXX")"
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

# 60  = the struct read whole (10+20+30); 600 = the C re-read after the write-back.
WANT="$(printf '60\n600')"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-global-aggregate (no C compiler '$CLANG' available)"
    summary
fi

# --- the C side: a global struct + a re-reader to confirm the write-back --------
cat > "$TMP/cglobal.c" <<'EOF'
struct Cfg { int a; int b; int c; };

/* The aggregate C global __c_global reaches by address. */
struct Cfg g_cfg = { 10, 20, 30 };

/* Re-read g_cfg after Binate writes it, to confirm the write crossed the ABI. */
int cfg_sum(void) { return g_cfg.a + g_cfg.b + g_cfg.c; }
EOF

# --- the Binate program: read the struct global, write it, verify via C ---------
cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

// Matches the C `struct Cfg { int a, b, c; }` (int == int32 on these targets).
type Cfg struct { a int32; b int32; c int32 }

func main() {
	var p *Cfg = __c_global("g_cfg", Cfg)
	// Read the whole struct through *p and check the fields.
	var s Cfg = *p
	testing.Println(cast(int, s.a + s.b + s.c))
	// Write a new value back through *p, then have C re-read it.
	s.a = 100
	s.b = 200
	s.c = 300
	*p = s
	var sum int32 = __c_call("cfg_sum", int32)
	testing.Println(cast(int, sum))
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
    if ! "$CLANG" -c -O2 -o "$work/cglobal.o" "$TMP/cglobal.c" 2>"$work/cc.err"; then
        fail "$label: C side compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra \
            --link-after-objs "$work/cglobal.o" --build-dir "$work" \
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
        pass "$label: __c_global struct read ('60') and write-back ('600') correct"
    else
        fail "$label: __c_global aggregate read/write mismatch" \
             "got:  $got" \
             "want: $WANT"
    fi
}

check_backend "llvm" "-O2" 1
check_backend "native" "--backend native -O2" 0

summary
