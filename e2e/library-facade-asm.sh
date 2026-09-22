#!/bin/sh
# e2e/library-facade-asm.sh — End-to-end test that a `bnc --library` archive
# includes the FACADE package's own build-included `.s` objects.
#
# The facade package is compiled on its own path in cmd/bnc/library.bn (the
# per-package loop `continue`s past it so its `bn_init` dispatcher can see the
# whole closure), which once assembled the facade's module object but skipped its
# `.s` files — so a facade shipping hand-written asm produced an archive MISSING
# those symbols.  This guards the fix: the facade here carries a data-only `.s`
# (`.global_c libasm_answer` = the platform C symbol `_libasm_answer` / `libasm_answer`,
# a `.uint64 42`), and a C driver reads that symbol out of the linked archive.
# Without the facade `.s` being archived, the link fails undefined; with it, the
# program reads 42 and exits 0.
#
# The `.s` is data-only (a `.uint64`, no instructions), so it assembles for any
# arch (bnc supplies the target arch), keeping the test host-agnostic.  Uses a
# gen1 bnc from current source.  Auto-discovered by .github/workflows/e2e-tests.yml
# on Linux + macOS; needs only a host C compiler (no cross-toolchain).  Exit 0 on
# pass.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || command -v cc || echo cc)}"
if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: library-facade-asm (no C compiler '$CLANG' available)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_libasm.XXXXXX")"
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

# --- the facade package `libasm`: a trivial func (so it is a real impl dir) plus
# a data-only `.s` defining a C-visible symbol via `.global_c`. -----
mkdir -p "$TMP/if" "$TMP/im/libasm"
cat > "$TMP/if/libasm.bni" <<'EOF'
package "libasm"

func Ping() int
EOF
cat > "$TMP/im/libasm/lib.bn" <<'EOF'
package "libasm"

func Ping() int { return 7 }
EOF
cat > "$TMP/im/libasm/answer.s" <<'EOF'
.section data
.global_c libasm_answer
libasm_answer:
 .uint64 42
EOF

# --- C driver: read the facade `.s`'s data symbol straight out of the archive.
# `.global_c` gives the symbol the platform C name, so a plain C `extern` binds it
# (bare on ELF, `_`-prefixed on Mach-O).  The linker pulls the facade's asm member
# from the archive to satisfy the reference — which only works if it was archived. -----
cat > "$TMP/driver.c" <<'EOF'
#include <stdint.h>
extern uint64_t libasm_answer;
int main(void) { return libasm_answer == 42 ? 0 : 1; }
EOF

PASSES=0
FAILS=0
SKIPS=0
FAIL_NAMES=""

# check_backend <label> <extra-bnc-flags> <required>
#   Build the --library archive, link the C driver against it, run, and check the
#   facade `.s` symbol was archived + linkable.  required=1 -> a build failure is a
#   hard FAIL; required=0 (native) -> no archive SKIPs, but a wrong result FAILs.
check_backend() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    echo "[$label] building --library archive..."
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" $extra \
            --build-dir "$work" -o "$work/lib.a" --library libasm >"$work/lib.log" 2>&1 \
            || [ ! -f "$work/lib.a" ]; then
        if [ "$required" -eq 1 ]; then
            echo "FAIL: $label: --library libasm produced no archive"
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
        echo "FAIL: $label: link failed — the facade's .s object was not archived"
        echo "       (undefined 'libasm_answer' means library.bn skipped the facade's AsmFiles)"
        head -8 "$work/link.err" | sed 's/^/    /'
        FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
        return
    fi
    "$work/run"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "PASS: $label: facade .s symbol archived + linkable (read 42 from libasm_answer)"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label: driver rc=$rc (want 0 — the archived libasm_answer should read 42)"
        FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# The archiving fix is backend-neutral (library.bn adds the facade's asm object to
# oFiles regardless of --backend), so LLVM (always available) is the required check;
# native self-skips when the host backend can't emit the archive.
check_backend "llvm"   ""                 1
check_backend "native" "--backend native" 0

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed, $SKIPS skipped ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
exit 0
