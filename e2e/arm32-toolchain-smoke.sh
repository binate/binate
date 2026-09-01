#!/bin/sh
# e2e/arm32-toolchain-smoke.sh — smoke-test the Binate toolchain binaries running
# AS arm32-linux (ILP32) processes under qemu-user.
#
# This is distinct from the arm32 conformance / unittest modes, which cross-compile
# TARGET code from a 64-bit host; here the TOOLS THEMSELVES run as 32-bit binaries,
# so ILP32 bugs in a tool's OWN execution (32-bit int/pointers, over-wide shifts,
# oversized constants, ...) are exercised, not just bugs in the code it emits.
#
# Each tool is cross-built for arm32-linux (`bnc --target arm32-linux`) and run
# under qemu-arm on a tiny input.  Covers all six: bni, bnas, bnlint, bnfmt, bnc
# (compile a program and run the result), and bnld (assemble an object with bnas,
# link it, structure-check the ELF).  bnc + bnld became arm32-buildable once the
# link address-width fix landed (b2c68b22b — 64-bit Mach-O addresses moved from
# word-sized int/uint to uint64).  See explorations/plan-arm32-toolchain-smoke.md.
#
# Auto-discovered by .github/workflows/e2e-tests.yml.  SKIPs (exit 0) unless a
# qemu-arm(-static) + a WORKING arm-linux-gnueabihf cross-toolchain (clang that can
# link a dynamic arm32 binary + the arm32 glibc qemu loads via QEMU_LD_PREFIX) is
# present — the prereq probe actually cross-compiles AND RUNS a tiny arm binary, so
# a partial toolchain skips rather than reds the gate.  The current e2e image
# installs clang but not qemu, so it skips there.  Exit 0 on pass or SKIP; non-zero
# with diagnostics only on a real tool failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
[ -d "$BINATE_DIR/pkg" ] || { echo "FAIL: not a binate repo: $BINATE_DIR" >&2; exit 1; }

CLANG="${CLANG:-$(command -v clang || echo clang)}"
QEMU_ARM="${QEMU_ARM:-}"
[ -n "$QEMU_ARM" ] || QEMU_ARM="$(command -v qemu-arm-static || command -v qemu-arm || true)"

# --- cheap prereq SKIPs (before any temp/build work) ----------------------
[ -n "$QEMU_ARM" ] || { echo "SKIP: qemu-arm(-static) not found (needed to run the 32-bit tools)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: clang not found"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_tcsmoke.XXXXXX")" || true
[ -d "$TMP" ] || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# The dynamically-linked arm32 binaries need the arm32 glibc + loader, which
# gcc-arm-linux-gnueabihf installs here; qemu-user finds them via QEMU_LD_PREFIX.
[ -d /usr/arm-linux-gnueabihf ] && export QEMU_LD_PREFIX=/usr/arm-linux-gnueabihf

# --- runtime prereq probe: cross-compile AND RUN a tiny arm binary ---------
# Gates on the FULL dependency (clang can LINK for arm-linux-gnueabihf + the arm32
# glibc/loader is present + qemu can run the result), not just "clang can compile"
# — a compile-only check passes on any clang and would red a partial-toolchain
# runner at the tool runs instead of skipping.
if ! { echo 'int main(void){return 0;}' \
        | "$CLANG" -target arm-linux-gnueabihf -march=armv7-a -x c - -o "$TMP/probe" 2>/dev/null \
        && "$QEMU_ARM" "$TMP/probe" >/dev/null 2>&1; }; then
    echo "SKIP: cannot cross-compile + run an arm-linux-gnueabihf binary under qemu" \
         "(need gcc-arm-linux-gnueabihf + its arm32 glibc)"
    exit 0
fi

# --- build a host bnc (the cross-compiler for the arm32 tools) ------------
echo "Building host bnc (cross-compiler)..."
BNC="$TMP/bnc"
build_log="$("$BINATE_DIR/scripts/build-bnc.sh" -o "$BNC" 2>&1)" || true
[ -x "$BNC" ] || { echo "FAIL: host bnc build failed" >&2; echo "$build_log" | tail -5 >&2; exit 1; }

# Search paths: --target arm32-linux for the cross-BUILD of each tool; plain host
# source paths for tools that INTERPRET Binate source at run time (bni).
A32_I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-linux)"
A32_L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl  --base "$BINATE_DIR" --target arm32-linux)"
SRC_I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
SRC_L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl  --base "$BINATE_DIR")"

cat > "$TMP/hello.bn" <<'BN'
package "main"
import "pkg/builtins/testing"
func main() { testing.Println("smoke-ok") }
BN

PASS=0
FAIL=0

# xbuild <tool>: cross-compile cmd/<tool> for arm32-linux into $TMP/<tool>_a32.
xbuild() {
    if ! "$BNC" --target arm32-linux -I "$A32_I" -L "$A32_L" \
            -o "$TMP/${1}_a32" "$BINATE_DIR/cmd/$1" >"$TMP/${1}.build" 2>&1; then
        echo "FAIL: cross-build of $1 for arm32 failed"
        tail -3 "$TMP/${1}.build" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
        return 1
    fi
    return 0
}

# check <name> <expected-substring> <cmd...>: run cmd, require exit 0 AND the
# substring on stdout/stderr.  The exit-code check matters — a tool that prints
# the right line then crashes at teardown (an ILP32 refcount/free/shift bug, the
# class this smoke targets) must FAIL, not slip through on the substring alone.
check() {
    _name="$1"
    _want="$2"
    shift 2
    _out="$("$@" 2>&1)"
    _rc=$?
    if [ "$_rc" -eq 0 ] && printf '%s' "$_out" | grep -qF -- "$_want"; then
        echo "PASS: $_name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $_name (rc=$_rc, got: $(printf '%s' "$_out" | head -1))"
        FAIL=$((FAIL + 1))
    fi
}

# --- bnfmt: --version + format a file --------------------------------------
if xbuild bnfmt; then
    check "bnfmt --version" "bnfmt-"        "$QEMU_ARM" "$TMP/bnfmt_a32" --version
    check "bnfmt format"    'package "main"' "$QEMU_ARM" "$TMP/bnfmt_a32" "$TMP/hello.bn"
fi

# --- bnlint: --version -----------------------------------------------------
if xbuild bnlint; then
    check "bnlint --version" "bnlint-" "$QEMU_ARM" "$TMP/bnlint_a32" --version
fi

# --- bni: --version + interpret a program ----------------------------------
if xbuild bni; then
    check "bni --version" "bni-"     "$QEMU_ARM" "$TMP/bni_a32" --version
    check "bni interpret" "smoke-ok" "$QEMU_ARM" "$TMP/bni_a32" -I "$SRC_I" -L "$SRC_L" "$TMP/hello.bn"
fi

# --- bnas: assemble a real arm32 runtime .s into an object -----------------
if xbuild bnas; then
    if "$QEMU_ARM" "$TMP/bnas_a32" -arch arm32 -o "$TMP/out.o" \
            "$BINATE_DIR/runtime/baremetal_arm32/aeabi_int.s" >"$TMP/bnas.err" 2>&1 \
            && [ -s "$TMP/out.o" ]; then
        echo "PASS: bnas assemble (arm32 .s -> $(wc -c <"$TMP/out.o" | tr -d ' ')-byte .o)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: bnas assemble"
        tail -3 "$TMP/bnas.err" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
fi

# --- bnc: --version + compile a program and run the result -----------------
if xbuild bnc; then
    check "bnc --version" "bnc-" "$QEMU_ARM" "$TMP/bnc_a32" --version
    # Compile for arm32-linux EXPLICITLY.  bnc runs emulated (arm32) under qemu but
    # execs the NATIVE clang (the runner's arch) for assemble + link; a default host
    # build lets clang pick its own default triple, i.e. the runner's arch, not arm32.
    # --target makes bnc drive clang's arm-linux-gnueabihf cross-triple, so the output
    # is an arm32 binary we can then run under qemu.  (This leans on qemu-user passing
    # the execve of a native clang through to the host — standard, but qemu-version
    # sensitive; a break there would surface as a bnc-compile FAIL, not a SKIP.)
    if "$QEMU_ARM" "$TMP/bnc_a32" --target arm32-linux -I "$A32_I" -L "$A32_L" \
            -o "$TMP/hello_bnc" "$TMP/hello.bn" >"$TMP/bnc.err" 2>&1; then
        check "bnc compile+run" "smoke-ok" "$QEMU_ARM" "$TMP/hello_bnc"
    else
        echo "FAIL: bnc compile"
        tail -3 "$TMP/bnc.err" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
fi

# --- bnld: assemble a tiny object with bnas, link it, structure-check the ELF ---
# bnld targets 64-bit outputs, so it links an x64 object (from bnas) and we
# structure-check the ELF header rather than run it under qemu-arm.  The header
# checks — magic, EI_CLASS=2 (ELF64), e_type=2 (ET_EXEC) — are the point: a bnld
# ILP32 bug that truncates a 64-bit header field would still start with the magic,
# so magic alone is not enough (cf. check_elf in e2e/bnld-linux.sh).
if xbuild bnld; then
    printf '.arch x64\n.section text\n.global _start\n_start:\n\tmov edi, 42\n\tmov eax, 60\n\tsyscall\n' > "$TMP/exit42.s"
    if "$QEMU_ARM" "$TMP/bnas_a32" -arch x64 -o "$TMP/exit42.o" "$TMP/exit42.s" >"$TMP/bnld.err" 2>&1 \
            && "$QEMU_ARM" "$TMP/bnld_a32" -o "$TMP/exit42" "$TMP/exit42.o" >>"$TMP/bnld.err" 2>&1 \
            && [ "$(od -An -tx1 -N4 "$TMP/exit42"    | tr -d ' \n')" = "7f454c46" ] \
            && [ "$(od -An -tu1 -j4  -N1 "$TMP/exit42" | tr -d ' \n')" = "2" ] \
            && [ "$(od -An -tu1 -j16 -N1 "$TMP/exit42" | tr -d ' \n')" = "2" ] \
            && [ -x "$TMP/exit42" ]; then
        echo "PASS: bnld link (bnas x64 .o -> ELF64 ET_EXEC)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: bnld link"
        tail -3 "$TMP/bnld.err" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
fi

echo ""
echo "=== arm32 toolchain smoke: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
