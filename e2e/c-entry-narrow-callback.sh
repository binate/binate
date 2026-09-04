#!/bin/sh
# e2e/c-entry-narrow-callback.sh — End-to-end test that a NARROW-argument Binate
# callback handed to C via `__c_entry` is invoked correctly across the ABI
# boundary, EXERCISING the native `__centry.<mangled>` adaptation thunk with a
# real C caller.
#
# `__c_entry(f)` yields a C-callable pointer to a Binate function.  When f has a
# narrow GP integer parameter (here int32, which is narrow on the 64-bit
# backends), the native backend cannot reference f's mangled entry directly: the
# C ABI guarantees only the LOW bits of a narrow argument register, leaving the
# upper bits unspecified, whereas the native backend keeps a narrow value
# 64-bit-canonical and spills the whole argument register.  So a C caller that
# leaves the upper bits DIRTY would make a naive entry read garbage.  The native
# backend therefore hands `__c_entry(f)` a WEAK `__centry.<mangled f>` thunk that
# re-canonicalizes the narrow argument registers, then branches to f's entry.
# This test drives exactly that dirty-upper case from C and checks f sees the
# canonical value.  It covers two narrow arguments: one passed in a REGISTER
# (re-canonicalized by the thunk) and — via a 9-parameter callback whose 9th
# argument is stack-passed on both SysV x64 and AAPCS64 — one on the STACK, which
# the thunk does NOT touch (it normalizes registers only) but the callback's own
# mangled-entry spill sizes-and-extends unconditionally.  The stack callback is not
# #[c_export], so it exercises the non-c_export __c_entry stack path specifically.
#
# The dirty-upper argument is injected the same way e2e/c-subword-return.sh does
# for a sub-word RETURN: the C caller declares the callback as taking a 64-bit
# `long long`, so the full value (low 32 = the real int32 argument, upper 32 =
# 0xBEEF junk) reaches the callback's argument register — a genuinely
# non-canonical int32 argument that a clean `int(*)(int)` call (which clang would
# narrow with a register-upper-zeroing 32-bit move) would NOT exercise.
#
# Built at -O2: the miscompile the thunk defends against only manifests once
# mem2reg PROMOTES the callback's argument out of its stack slot and a 64-bit use
# reads the non-canonical register (at -O0 the argument is spilled at its narrow
# width, which incidentally drops the dirty upper bits).  Verified while writing:
# at -O2 with the thunk suppressed, cb reads the dirty argument and prints 222;
# with the thunk it prints 111 — so this test genuinely guards the thunk.
#
# Both backends are checked: LLVM (always) and native (--backend native, which on
# the aa64/x64 CI hosts emits + links this program; self-skips if the host's
# native backend can't build it).  The thunk is native-only, so the native
# variant is the meaningful one; the LLVM variant pins that the two backends
# agree (clang's mangled entry handles the narrow argument directly).
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_centry.XXXXXX")"
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

# cb / cbStack each return 111 iff they saw their int32 argument as the canonical 5
# (upper bits re-normalized); a dirty-upper argument that leaks into the compare yields
# 222.  cb takes its argument in a REGISTER (normalized by the __c_entry thunk); cbStack's
# inspected argument is STACK-passed (normalized by the callback's own mangled-entry spill).
WANT="$(printf '111\n111')"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-entry-narrow-callback (no C compiler '$CLANG' available)"
    summary
fi

# --- the C caller: invoke the Binate callback with a dirty-upper int32 arg ----
cat > "$TMP/ccall.c" <<'EOF'
/* Calls the Binate callback with a narrow (int32) argument whose passing register
 * carries DIRTY upper bits.  The callback is declared here as taking a 64-bit
 * `long long`, so the whole `dirty` value (low 32 = the real int32 argument,
 * upper 32 = 0xBEEF junk) reaches the callback's argument register.  The C ABI
 * guarantees only the low 32 bits of an int32 argument, so a correct callback
 * must re-canonicalize the register — which the __c_entry adaptation thunk does.
 * This is the argument-side analogue of c-subword-return.sh's dirty-upper RETURN
 * technique. */
int call_i32_cb(int (*cb)(long long), long long dirty) { return cb(dirty); }

/* Stack-arg variant: a 9-int-parameter callback whose 9th argument is STACK-passed
 * on both SysV x64 (6 GP arg regs) and AAPCS64 (8).  Each parameter is declared
 * `long long` so its stack slot carries a full 64-bit word — the low 32 bits are the
 * real int32 argument, the upper bits are the dirty junk.  The __c_entry thunk
 * normalizes only the argument REGISTERS; the stack-passed narrow argument is
 * canonicalized by the callback's own mangled-entry spill (the unconditional sub-word
 * stack-arg extension).  Only the 9th argument (a8) is inspected by the callback. */
int call_i32_stack_cb(int (*cb)(long long, long long, long long, long long, long long,
                                long long, long long, long long, long long),
                      long long a8dirty) {
    return cb(0, 0, 0, 0, 0, 0, 0, 0, a8dirty);
}
EOF

# --- the Binate program: hand cb to C via __c_entry, check the value ----------
cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

// A narrow-argument (int32) callback.  It USES its argument in a comparison — the
// case a dirty-upper argument register corrupts if the C entry does not
// re-canonicalize the register (the native __c_entry thunk's job).
func cb(x int32) int32 {
	if x == 5 {
		return 111
	}
	return 222
}

// A narrow (int32) callback whose 9th parameter is STACK-passed on both SysV x64 (6 GP arg
// regs) and AAPCS64 (8).  cbStack is NOT #[c_export], so this exercises the non-c_export
// __c_entry stack path: the adaptation thunk normalizes only the argument REGISTERS, so a8's
// dirty upper bits are canonicalized by cbStack's own mangled-entry spill (the unconditional
// sub-word stack-arg extension).  Only a8 is inspected.
func cbStack(a0 int32, a1 int32, a2 int32, a3 int32, a4 int32, a5 int32,
		a6 int32, a7 int32, a8 int32) int32 {
	if a8 == 5 {
		return 111
	}
	return 222
}

func main() {
	// A non-canonical int32 5: low 32 bits = 5, upper 32 bits = 0xBEEF (dirty).
	var hi int64 = cast(int64, 0xBEEF)
	var dirty int64 = (hi << 48) | 5
	// Register-arg callback: the __c_entry thunk re-canonicalizes the argument register.
	var r int32 = __c_call("call_i32_cb", int32, __c_entry(cb), dirty)
	testing.Println(cast(int, r))
	// Stack-arg callback: a8 lands on the stack; cbStack's mangled-entry spill extends it.
	var r2 int32 = __c_call("call_i32_stack_cb", int32, __c_entry(cbStack), dirty)
	testing.Println(cast(int, r2))
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
#   Compile the C caller for the HOST arch, compile+link the Binate program
#   against it with the given backend, run, and check the output.  required=1 -> a
#   compile failure is a hard FAIL (LLVM); required=0 -> a native backend that
#   can't build this program on this host SKIPs.
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
        pass "$label: narrow-arg __c_entry callback saw the canonical argument ('$got')"
    else
        fail "$label: narrow-arg __c_entry callback argument mismatch" \
             "got:  $got" \
             "want: $WANT (222 => the dirty upper bits leaked into cb's argument)"
    fi
}

check_backend "llvm" "-O2" 1
check_backend "native" "--backend native -O2" 0

summary
