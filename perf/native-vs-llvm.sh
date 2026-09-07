#!/bin/sh
# perf/native-vs-llvm.sh — measure the native↔LLVM codegen-quality gap.
#
# The gap this project is closing is a RUNTIME-code-quality gap: for the same
# source program, code emitted by the native backend runs slower than code
# emitted by the LLVM backend (clang -O2).  This benchmark measures that ratio
# directly and reproducibly:
#
#   1. Build bnc TWICE from the CURRENT tree, with the same bootstrap compiler
#      (gen1) and the same rt:
#        L = bnc --backend llvm  -O2 --cflag -O2   (clang -O2 codegen)
#        N = bnc --backend native -O2              (native backend codegen)
#      L and N are the SAME program built two ways; their only difference is the
#      quality of the machine code they are made of.
#   2. Time EACH binary performing the identical work: compile <path> with a
#      fixed, in-process (no clang subprocess) backend+linker.
#   3. Report both times and the ratio time(N)/time(L).
#
# Because L and N do byte-identical work, the ratio isolates code quality.  The
# timed work defaults to `--backend native --linker bnld` (fully in-process, so
# the number reflects the binary's own code, not an external clang process).
#
# CROSS-ARCH (--arch KEY): the wall-clock path above measures the HOST backend.
# `--backend native` on a given box compiles for that box's arch, so on an arm64
# dev machine it builds AARCH64 and CANNOT see an x64/arm32 codegen change (the
# revert leaves the aarch64 output identical → looks falsely "neutral").  Pass
# `--arch x86_64-darwin` (etc.) to cross-build L and N for KEY and report a
# STATIC code-quality gap instead: __text size, and — for x86_64 targets — the
# frame reload / address-recompute counts (the metric within-block retention
# moves).  Wall-clock is intentionally NOT reported for a cross target: running
# it under an emulator (Rosetta / qemu) is an unreliable proxy that hides the
# gap.  Diff a change's effect by running --arch at two commits and comparing
# N's static numbers; real cross-arch wall-clock needs the target hardware / CI.
#
# Usage: perf/native-vs-llvm.sh [options]
#   --target PATH     what the timed bnc run compiles (default: cmd/bnc = self-compile)
#   --arch KEY        cross-build L/N for a bnc --target key (e.g. x86_64-darwin);
#                     reports STATIC code-quality metrics, no wall-clock
#   --rounds N        interleaved timed rounds; best + median reported (default 5)
#   --work-backend B  backend the TIMED run uses: native (default) | llvm
#   --work-linker L   linker the TIMED run uses: bnld (default) | clang
#   --keep            keep the built L/N binaries and print their paths
#
# Env: BINATE_DIR (defaults to this script's repo).  Requires clang for the
# LLVM build and for the --work-linker clang / --work-backend llvm paths.
#
# (No `set -u`: scripts/lib/build-compilers.sh, sourced below, relies on unset
# variables — the other perf/*.sh drivers don't set -u either.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${BINATE_DIR:="$(cd "$SCRIPT_DIR/.." && pwd)"}"
export BINATE_DIR

TARGET="$BINATE_DIR/cmd/bnc"
ARCH=""
ROUNDS=5
WORK_BACKEND=native
WORK_LINKER=bnld
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --work-backend) WORK_BACKEND="$2"; shift 2 ;;
        --work-linker) WORK_LINKER="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,49p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

. "$BINATE_DIR/scripts/lib/build-compilers.sh"

# When cross-building, gen1 stays a HOST binary (it must run here) but its
# Stage-2 emit and the search paths are retargeted to KEY.
TARGET_OPT=""
[ -n "$ARCH" ] && TARGET_OPT="--target $ARCH"
IP="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" $TARGET_OPT)"
LP="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" $TARGET_OPT)"

# Millisecond-resolution wall time (perl Time::HiRes is core), matching perf/*.sh.
now()   { perl -MTime::HiRes=time -e 'printf "%.3f", time()'; }
delta() { perl -e "printf '%.3f', $2 - $1"; }
# min / median of the whitespace-separated numbers in $1 (empties filtered).
minof()    { echo "$1" | tr ' ' '\n' | awk 'NF' | sort -n | head -1; }
medianof() { echo "$1" | tr ' ' '\n' | awk 'NF' | sort -n | awk '{a[NR]=$0} END{print a[int((NR+1)/2)]}'; }

echo "=== native-vs-llvm gap benchmark ==="
echo "tree:        $BINATE_DIR"
echo "compile tgt: $TARGET"
if [ -n "$ARCH" ]; then
    echo "arch:        $ARCH (cross-build; STATIC code-quality metrics, no wall-clock)"
else
    echo "timed work:  bnc --backend $WORK_BACKEND --linker $WORK_LINKER <tgt>"
    echo "rounds:      $ROUNDS (interleaved, best + median reported)"
fi
echo

echo "Building bootstrap gen1..." >&2
build_gen1 >&2

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nvl_XXXXXX")"
mkdir -p "$WORK/bl" "$WORK/bn" "$WORK/out"
L="$WORK/bnc_llvm"
N="$WORK/bnc_native"

echo "Building L = bnc --backend llvm -O2 --cflag -O2 $TARGET_OPT (clang codegen)..." >&2
"$GEN1_COMPILER" --backend llvm -O2 --cflag -O2 $TARGET_OPT -I "$IP" -L "$LP" \
    --build-dir "$WORK/bl" -o "$L" "$BINATE_DIR/cmd/bnc" >&2 || { echo "L build failed" >&2; exit 1; }
echo "Building N = bnc --backend native -O2 $TARGET_OPT (native codegen)..." >&2
"$GEN1_COMPILER" --backend native -O2 $TARGET_OPT -I "$IP" -L "$LP" \
    --build-dir "$WORK/bn" -o "$N" "$BINATE_DIR/cmd/bnc" >&2 || { echo "N build failed" >&2; exit 1; }

# __TEXT segment size in bytes (BSD `size`: header row, then values with __TEXT
# as the first column).  Reliable for any Mach-O regardless of host arch.
text_size() { size "$1" 2>/dev/null | awk 'NR==2{print $1}'; }

# For an x86_64 Mach-O: "instructions value-reloads addr-recomputes", counted
# from disassembly.  A value-reload is a mov-family load from a frame slot
# (rsp-relative source); an addr-recompute is a leaq of a frame address — both
# are what a cached (retained) register lets a later use skip.  Frame stores
# (spills) are deliberately not counted: retention leaves them unchanged.
x64_counts() {
    otool -tV "$1" 2>/dev/null | awk '
        /^[0-9a-f]{16}\t/ { i++ }
        /\t(movq|movl|movzbq|movslq|movsbq|movzwq)\t.*\(%rsp\),/ { r++ }
        /\tleaq\t.*\(%rsp\),/ { a++ }
        END { printf "%d %d %d", i, r, a }'
}

if [ -n "$ARCH" ]; then
    # Cross-arch: static code-quality gap (no emulated wall-clock).
    for b in "$L" "$N"; do
        [ -s "$b" ] || { echo "build produced no binary: $b" >&2; exit 1; }
    done
    echo "L = $L  ($(file -b "$L" 2>/dev/null))" >&2
    echo "N = $N  ($(file -b "$N" 2>/dev/null))" >&2

    LTEXT="$(text_size "$L")"; NTEXT="$(text_size "$N")"
    echo
    if [ -n "$LTEXT" ] && [ -n "$NTEXT" ] && [ "$LTEXT" -gt 0 ]; then
        SR="$(perl -e "printf '%.2f', $NTEXT/$LTEXT")"
        echo "__text bytes:  L(llvm) $LTEXT   N(native) $NTEXT   native/llvm ${SR}x"
    else
        echo "__text bytes:  could not read section sizes (non-Mach-O target?)"
    fi

    case "$ARCH" in
        x86_64*)
            set -- $(x64_counts "$L"); LI=$1; LR=$2; LA=$3
            set -- $(x64_counts "$N"); NI=$1; NR2=$2; NA=$3
            echo "instructions:  L(llvm) $LI   N(native) $NI"
            echo "value reloads: L(llvm) $LR   N(native) $NR2   (mov from frame)"
            echo "addr recomp:   L(llvm) $LA   N(native) $NA   (lea from frame)"
            echo
            echo "(To diff a native-backend change: run --arch $ARCH at two commits"
            echo " and compare N's reloads / __text — that is where retention shows.)"
            ;;
        *)
            echo "(Per-instruction reload counting is x86_64-only for now; __text"
            echo " size is the cross-arch gap proxy for $ARCH.)"
            ;;
    esac

    if [ "$KEEP" -eq 1 ]; then echo "kept: L=$L  N=$N" >&2; else rm -rf "$WORK"; fi
    exit 0
fi

# Host arch: wall-clock gap (the original path).
# Sanity: both must be real, working compilers (guards against a fast-failing
# build masquerading as a fast run).
lv="$("$L" --version 2>&1 | head -1)"
nv="$("$N" --version 2>&1 | head -1)"
echo "L = $L  ($lv)" >&2
echo "N = $N  ($nv)" >&2
if [ "$lv" != "$nv" ] || [ -z "$lv" ]; then
    echo "WARN: L/N --version differ or empty ('$lv' vs '$nv')" >&2
fi

BD="$WORK/out"
mkdir -p "$BD"
# One timed compile of TARGET by binary $1 -> prints seconds.
timed() {
    t0="$(now)"
    "$1" --backend "$WORK_BACKEND" --linker "$WORK_LINKER" -I "$IP" -L "$LP" \
        --build-dir "$BD" -o "$BD/out.bin" "$TARGET" >/dev/null 2>&1
    rc=$?
    t1="$(now)"
    if [ "$rc" -ne 0 ]; then echo "ERR"; else delta "$t0" "$t1"; fi
}

# Warmup (fills caches; discarded).
timed "$L" >/dev/null; timed "$N" >/dev/null

LT=""
NT=""
echo "round    L(llvm)   N(native)"
r=1
while [ "$r" -le "$ROUNDS" ]; do
    l="$(timed "$L")"
    n="$(timed "$N")"
    printf "  %-4s   %-8s  %-8s\n" "$r" "$l" "$n"
    LT="$LT $l"
    NT="$NT $n"
    r=$((r + 1))
done

case "$LT$NT" in
    *ERR*) echo; echo "ERROR: a timed compile failed — see a manual run for diagnostics." >&2; exit 1 ;;
esac

LBEST="$(minof "$LT")"; LMED="$(medianof "$LT")"
NBEST="$(minof "$NT")"; NMED="$(medianof "$NT")"
RBEST="$(perl -e "printf '%.2f', $NBEST/$LBEST")"
RMED="$(perl -e "printf '%.2f', $NMED/$LMED")"

echo
echo "L (llvm)   best ${LBEST}s   median ${LMED}s"
echo "N (native) best ${NBEST}s   median ${NMED}s"
echo "native/llvm ratio:  best ${RBEST}x   median ${RMED}x"

if [ "$KEEP" -eq 1 ]; then
    echo "kept: L=$L  N=$N" >&2
else
    rm -rf "$WORK"
fi
