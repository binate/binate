#!/bin/sh
# e2e/cross-compile.sh — End-to-end test that the release build scripts can
# CROSS-COMPILE the toolchain: `build-bnc.sh --target <key>` produces a bnc
# binary OF the target arch (not the host's), and that cross-built bnc is a
# working compiler.
#
# This guards the cross-target plumbing that lets a release build a bundle for
# a platform other than the runner's (e.g. a linux-arm64 BUILDER bundle built on
# an x86_64 runner): scripts/build-{bnc,bni,bnas,bnlint,bnfmt}.sh grew a
# --target flag that cross-EMITS Stage 2 while keeping gen1 a host binary, and
# make-bundle.sh derives it from a non-host --platform.  Nothing else exercises
# that path outside a real release.
#
# Coverage is host-shaped, because a cross build needs the target's cross-link
# toolchain AND a way to run the result:
#   - macOS/arm64  -> target x86_64-darwin: the universal SDK links it and
#                     Rosetta runs it, so this host does the FULL check (build a
#                     cross bnc, run it to compile+run a hello).  This is the CI
#                     macos-latest runner.
#   - Linux + a matching cross toolchain (gcc-<arch>-linux-gnu) -> arch-only
#                     check: the cross bnc is built and its arch asserted, but
#                     it is not executed (running a foreign-arch bnc that itself
#                     execs the host clang under qemu-user is fragile; the arch
#                     assertion already proves --target threaded through).
#   - otherwise    -> SKIP (no cross-link toolchain on this host).
#
# The stock CI ubuntu-latest e2e runner ships only host clang, so it SKIPs; the
# macos-latest runner runs the full check.  Exit 0 on pass/skip; non-zero on a
# real failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || echo clang)}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_xc.XXXXXX")"
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

# clang_can_target <triple>: true if clang can compile a trivial C TU for the
# triple (i.e. the cross sysroot / headers are installed).  Same probe the
# conformance cross runners use to detect a missing cross toolchain early.
clang_can_target() {
    # Include <stdio.h> so the probe needs the target's libc headers — the real
    # cross build links against the target libc, and a header-free TU compiles
    # even when the cross libc-dev is absent, so it would wrongly report the
    # toolchain present and the real build would then fail on a missing
    # bits/libc-header-start.h — which is precisely what reddened ubuntu CI.
    printf '#include <stdio.h>\nint main(void){return 0;}\n' | \
        "$CLANG" -target "$1" -x c -c - -o "$TMP/_probe.o" >/dev/null 2>&1
}

# Pick a cross target for this host: sets XTARGET (bnc --target key), XTRIPLE
# (clang triple, for the toolchain probe), XARCH (substring `file` must report
# on the produced binary), and RUN_EMU (emulator command to run a target binary,
# or empty for "runnable directly" / "do not run").  Leaves XTARGET empty when
# no cross target is available on this host.
XTARGET=""; XTRIPLE=""; XARCH=""; RUN_EMU=""; RUN_OK=0
host_os="$(uname -s)"; host_arch="$(uname -m)"
case "$host_os/$host_arch" in
    Darwin/arm64)
        # x86_64 macOS: universal SDK links it, Rosetta runs it directly.
        XTARGET=x86_64-darwin; XTRIPLE=x86_64-apple-darwin
        XARCH=x86_64; RUN_EMU=""; RUN_OK=1 ;;
    Linux/x86_64)
        # aarch64 Linux: needs gcc-aarch64-linux-gnu; arch-only (no run).
        XTARGET=aarch64-linux; XTRIPLE=aarch64-linux-gnu; XARCH=aarch64 ;;
    Linux/aarch64)
        XTARGET=x86_64-linux; XTRIPLE=x86_64-linux-gnu; XARCH=x86-64 ;;
esac

if [ -z "$XTARGET" ]; then
    skip "no cross target for host $host_os/$host_arch"
elif ! clang_can_target "$XTRIPLE"; then
    skip "cross toolchain for $XTRIPLE not installed (host $host_os/$host_arch)"
else
    echo "Cross-building bnc for $XTARGET on $host_os/$host_arch ..."
    XBNC="$TMP/bnc-$XTARGET"
    build_log=$("$BINATE_DIR/scripts/build-bnc.sh" --target "$XTARGET" -o "$XBNC" 2>&1) || true
    if [ ! -x "$XBNC" ]; then
        fail "cross-build: build-bnc.sh --target $XTARGET produced no binary" \
             "$(printf '%s\n' "$build_log" | tail -6)"
    else
        ftype="$(file "$XBNC")"
        case "$ftype" in
            *"$XARCH"*)
                if [ "$RUN_OK" -eq 1 ]; then
                    # Full check: the cross bnc compiles+runs a hello for its
                    # target (RUN_EMU empty => direct exec, e.g. Rosetta).
                    hello="$TMP/hello.bn"
                    printf 'package "main"\n\nimport "pkg/std/fmt"\n\nfunc main() {\n\tfmt.Println("cross-compile-ok")\n}\n' > "$hello"
                    I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target "$XTARGET")"
                    L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --target "$XTARGET")"
                    prog="$TMP/hello-$XTARGET"
                    clog=$($RUN_EMU "$XBNC" -I "$I" -L "$L" \
                            --target "$XTARGET" -o "$prog" "$hello" 2>&1) || true
                    if [ ! -x "$prog" ]; then
                        fail "cross-run: cross-built bnc failed to compile a hello" \
                             "$(printf '%s\n' "$clog" | tail -6)"
                    else
                        out=$($RUN_EMU "$prog" 2>&1) || true
                        if [ "$out" = "cross-compile-ok" ]; then
                            pass "cross-compile $XTARGET (bnc is $XARCH; runs + compiles + runs a hello)"
                        else
                            fail "cross-run: unexpected program output" \
                                 "want 'cross-compile-ok', got '$out'"
                        fi
                    fi
                else
                    pass "cross-compile $XTARGET (bnc is $XARCH; execution not attempted on this host)"
                fi ;;
            *)
                fail "cross-build: bnc is not $XARCH" "file: $ftype" ;;
        esac
    fi
fi

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed, $SKIPS skipped ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
exit 0
