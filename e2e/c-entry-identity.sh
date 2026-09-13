#!/bin/sh
# e2e/c-entry-identity.sh — CROSS-PRODUCER pointer identity for `__c_entry` of a
# narrow-register-parameter function (language spec `pkg.centry.identity`, ABI
# review #10).
#
# `__c_entry(f)` must yield the SAME pointer value for the same f regardless of
# which backend compiled the referencing translation unit.  For a narrow GP
# register parameter the native backends route `__c_entry(f)` through a weak
# `__centry.<mangled f>` adaptation thunk (the C ABI leaves a narrow argument
# register's upper bits unspecified; the thunk re-canonicalizes them).  The LLVM
# backend does not NEED that adaptation — its calling convention self-extends
# narrow arguments — but it must still emit the SAME weak `__centry.` forwarding
# thunk, or a mixed-producer program gets two different pointers for one f: the
# LLVM TU's bare mangled-entry address vs the native TU's thunk address.
#
# This builds ONE program from two independently-compiled translation units that
# each take `__c_entry` of the SAME narrow-parameter function f:
#   - package `centryf` (compiled by the LLVM backend) defines f and a
#     `#[c_export]` getter returning `__c_entry(f)`;
#   - package `centryb` (compiled by the NATIVE backend) imports centryf and a
#     `#[c_export]` getter returning `__c_entry(centryf.f)`.
# A C driver links both objects and asserts the two getters return EQUAL pointers
# (and that calling through one invokes f correctly).  Before the LLVM narrow-param
# thunk existed, the LLVM getter returned f's mangled address while the native
# getter returned the `__centry.` thunk address — unequal — so this test guards the
# harmonization.
#
# The two objects are a MIXED-producer link (one LLVM .o + one native .o), which is
# exactly what `pkg.centry.identity` promises works.  The weak `__centry.` copies
# the two producers emit coalesce to one address at link time.
#
# Runs only where the host's native backend can build centryb (the aa64/x64 CI
# hosts); self-skips otherwise, and skips if no C compiler is present.  int32 is
# the narrow parameter — narrow on both 64-bit backends.
#
# Uses a gen1 bnc built from current source.  Auto-discovered by
# .github/workflows/e2e-tests.yml on Linux + macOS.
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_centry_id.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: c-entry-identity (no C compiler '$CLANG' available)"
    exit 0
fi

# --- package centryf: defines f (narrow int32 param) + the LLVM-side getter ----
mkdir -p "$TMP/if/centryf" "$TMP/im/centryf" "$TMP/if/centryb" "$TMP/im/centryb"
cat > "$TMP/if/centryf.bni" <<'EOF'
package "centryf"

// f is __c_entry'd from another package (centryb), so it must be .bni-visible.
func F(x int32) int32
EOF
cat > "$TMP/im/centryf/lib.bn" <<'EOF'
package "centryf"

// A narrow (int32) GP-register parameter: narrow on the 64-bit backends, so
// __c_entry(F) routes through the weak __centry.<mangled F> thunk on native — and,
// after the harmonization, on LLVM too.
func F(x int32) int32 { return x }

// GetA returns __c_entry(F) as a C void*.  This package is compiled by the LLVM
// backend, so GetA exercises the LLVM __c_entry lowering for a narrow-param target.
#[c_export("cent_get_a")]
func GetA() *uint8 { return __c_entry(F) }
EOF

# --- package centryb: the NATIVE-side getter, __c_entry of the SAME F -----------
cat > "$TMP/if/centryb.bni" <<'EOF'
package "centryb"
EOF
cat > "$TMP/im/centryb/lib.bn" <<'EOF'
package "centryb"

import "centryf"

// GetB returns __c_entry(centryf.F) — the SAME function GetA points at.  This
// package is compiled by the native backend, so GetB exercises the native
// __c_entry lowering (the weak __centry. thunk).  For pkg.centry.identity to hold,
// GetA() and GetB() must be EQUAL.
#[c_export("cent_get_b")]
func GetB() *uint8 { return __c_entry(centryf.F) }
EOF

# --- the C driver: compare the two __c_entry pointers, then call through one ----
cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern void *cent_get_a(void);   /* __c_entry(F) via the LLVM-compiled TU   */
extern void *cent_get_b(void);   /* __c_entry(F) via the native-compiled TU */
typedef int (*cb_t)(int);
int main(void) {
    void *a = cent_get_a();
    void *b = cent_get_b();
    printf("%s\n", a == b ? "equal" : "differ");
    /* Both point at the same C entry of F(x)=x; calling through it returns its arg. */
    printf("%d\n", ((cb_t)a)(5));
    return 0;
}
EOF
WANT="$(printf 'equal\n5')"

echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed"
    echo "$gen1_log" | tail -5
    exit 1
fi

IFACE="$TMP/if:$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$TMP/im:$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

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

# centryf is always the LLVM getter of __c_entry(F).
mkdir -p "$TMP/wa"
if ! "$GEN1" -I "$IFACE" -L "$IMPL" --build-dir "$TMP/wa" --pkg centryf >"$TMP/wa.log" 2>&1 \
        || [ ! -f "$TMP/wa/centryf.o" ]; then
    fail "identity: LLVM compile of centryf (--pkg) produced no object" "$(tail -5 "$TMP/wa.log")"
    summary
fi

# check_identity <label> <centryb-object>: link centryf (LLVM) + the given centryb
# object + the driver, run, and assert the two __c_entry(F) getters return EQUAL
# pointers.
check_identity() {
    label="$1"; centrybo="$2"
    if ! "$CLANG" -w "$TMP/driver.c" "$TMP/wa/centryf.o" "$centrybo" -o "$TMP/run_$label" 2>"$TMP/link_$label.err"; then
        fail "$label: link (centryf.o + $label centryb.o + driver) failed" "$(head -8 "$TMP/link_$label.err")"
        return
    fi
    got="$("$TMP/run_$label" 2>&1)"
    if [ "$got" = "$WANT" ]; then
        pass "$label: __c_entry(F) yields one coalesced pointer ('$(echo "$got" | tr '\n' '/')')"
    else
        fail "$label: __c_entry identity mismatch" \
             "got:  $(echo "$got" | tr '\n' '/')" \
             "want: $(echo "$WANT" | tr '\n' '/')  (differ => a TU used the bare mangled entry, not __centry.)"
    fi
}

# 1. Two LLVM producers: guards that the weak `__centry.` copies two LLVM TUs emit
#    coalesce to one address (always runnable).
mkdir -p "$TMP/wbll"
if ! "$GEN1" -I "$IFACE" -L "$IMPL" --build-dir "$TMP/wbll" --pkg centryb >"$TMP/wbll.log" 2>&1 \
        || [ ! -f "$TMP/wbll/centryb.o" ]; then
    fail "llvm+llvm: LLVM compile of centryb (--pkg) produced no object" "$(tail -5 "$TMP/wbll.log")"
else
    check_identity "llvm+llvm" "$TMP/wbll/centryb.o"
fi

# 2. Mixed producers: the LLVM getter and the NATIVE getter of the same F must
#    agree — the #[c_export]/native harmonization this test guards.  Native --pkg
#    that the host backend can't emit is a SKIP.
mkdir -p "$TMP/wb"
if ! "$GEN1" -I "$IFACE" -L "$IMPL" --backend native --build-dir "$TMP/wb" --pkg centryb >"$TMP/wb.log" 2>&1 \
        || [ ! -f "$TMP/wb/centryb.o" ]; then
    skip "llvm+native: native backend cannot build centryb on this host"
else
    check_identity "llvm+native" "$TMP/wb/centryb.o"
fi

summary
