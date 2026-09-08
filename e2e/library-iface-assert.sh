#!/bin/sh
# e2e/library-iface-assert.sh — End-to-end test that a `bnc --library` archive
# builds the interface-satisfaction registry, so an interface assertion inside a
# library works after the C host calls bn_init.
#
# A library artifact has no `__entry` (the program entry point where the
# whole-program path wires the registry fill), so its registry must be built from
# `bn_init` instead — walking the facade's `__pkg_satfrag` graph node.  Without
# that, rt.BuildSatRegistry never runs in a library and EVERY interface
# assertion/satisfaction lookup MISSES: the comma-ok assertion below returns
# ok=false and the export yields the -1 sentinel.
#
# The facade boxes a concrete type into interface J, then asserts j.(@K) — an
# interface-to-interface assertion, resolved at runtime via the registry (J's
# dynamic type is erased into the value, so the (T, K) satentry must be looked
# up).  The C driver calls bn_init once, then the #[c_export] assertion function,
# and checks it returns k() (= v*2), not the -1 miss sentinel.
#
# Uses a gen1 bnc from current source.  Auto-discovered by
# .github/workflows/e2e-tests.yml on Linux + macOS; needs only a host C compiler
# (no cross-toolchain).  Exit 0 on pass.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || command -v cc || echo cc)}"
if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: library-iface-assert (no C compiler '$CLANG' available)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_libsat.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- build gen1 bnc from current source -----------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed:"
    echo "$gen1_log" | tail -20
    exit 1
fi
IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# --- the facade: interfaces J/K, a type T satisfying both, and a #[c_export]
# assertion.  The (T, K) satentry is what the registry walk must register.
mkdir -p "$TMP/if" "$TMP/im/libsat"
cat > "$TMP/if/libsat.bni" <<'EOF'
package "libsat"

interface J {
	j() int
}

interface K {
	k() int
}

type T struct {
	v int
}

impl *T : J

impl *T : K

func (t *T) j() int

func (t *T) k() int
EOF
cat > "$TMP/im/libsat/lib.bn" <<'EOF'
package "libsat"

func (t *T) j() int { return t.v }

func (t *T) k() int { return t.v * 2 }

// Box a T into interface J, then assert j.(@K) — an interface-to-interface
// assertion resolved at runtime through the satisfaction registry.  Returns k()
// on a HIT, or -1 on a MISS (the symptom of a library whose registry was never
// built).
#[c_export("libsat_assert")]
func assertJK(v int32) int32 {
	var t @T = make(T)
	t.v = cast(int, v)
	var jv @J = t
	kv, ok := jv.(@K)
	if !ok {
		return -1
	}
	return cast(int32, kv.k())
}
EOF

# --- C driver: init once, then call the asserting export ----------------------
cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern void bn_init(void);
extern int libsat_assert(int);
int main(void) {
    bn_init();                     /* fills the interface-satisfaction registry */
    int r = libsat_assert(21);     /* j.(@K) must HIT -> k() = 21*2 = 42 */
    printf("%d\n", r);
    return (r == 42) ? 0 : 1;
}
EOF

PASSES=0
FAILS=0
SKIPS=0
FAIL_NAMES=""

# check_backend <label> <extra-bnc-flags> <required>
#   Build the --library archive with the given backend, link the C driver, run,
#   and check the assertion HIT.  required=1 -> a build failure is a hard FAIL;
#   required=0 (native) -> a build producing no archive SKIPs (the host native
#   backend may not cover this facade), but a produced-but-wrong result FAILs.
check_backend() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    echo "[$label] building --library archive..."
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" $extra \
            --build-dir "$work" -o "$work/lib.a" --library libsat >"$work/lib.log" 2>&1 \
            || [ ! -f "$work/lib.a" ]; then
        if [ "$required" -eq 1 ]; then
            echo "FAIL: $label: --library libsat produced no archive"
            tail -8 "$work/lib.log" | sed 's/^/    /'
            FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
        else
            echo "SKIP: $label: native --library unavailable for this host (no archive)"
            SKIPS=$((SKIPS + 1))
        fi
        return
    fi
    if ! "$CLANG" -w "$TMP/driver.c" "$work/lib.a" -o "$work/run" 2>"$work/link.err" \
            || [ ! -x "$work/run" ]; then
        echo "FAIL: $label: link of C driver + --library archive failed"
        head -8 "$work/link.err" | sed 's/^/    /'
        FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
        return
    fi
    out="$("$work/run" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "42" ]; then
        echo "PASS: $label: library interface assertion HIT (registry built from bn_init): '$out'"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label: assertion result '$out' (rc=$rc, want '42' — '-1' means the registry was never built)"
        FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# LLVM is required (the fix lives in backend-neutral IR-gen, but LLVM is the
# always-available backend); native self-skips when the host backend can't emit
# the archive, but must pass when it runs.
check_backend "llvm"   ""                 1
check_backend "native" "--backend native" 0

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed, $SKIPS skipped ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
exit 0
