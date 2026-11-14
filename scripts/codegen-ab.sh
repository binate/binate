#!/bin/sh
# Usage: ./scripts/codegen-ab.sh [-j N] [-t target] [-f "bnc flags"] [-m regex]
#            <before bnc> <after bnc> <out dir> [corpus...]
#
# Compare the code two bnc builds generate, program by program: each input is
# compiled by both builds with -c, which leaves an object for every module of
# the program -- its own packages, the runtime, the standard library -- and the
# two sets of objects are compared file by file.  The corpora, drawn from this
# tree (default all three):
#
#   single  the single-file conformance tests (the files conformance/run.sh
#           runs as one-file programs)
#   multi   the multi-package conformance tests, each built from its main.bn
#           with its directory prepended to the search paths
#   bnc     cmd/bnc itself
#
# -t compiles for a bnc --target key (also handed to binate-paths.sh, for the
# target's search paths); -f passes extra flags to both builds (-f "--backend
# native" compares the native backend's objects); -m keeps only the inputs whose
# path matches the extended regex; -j compiles N inputs at once (default 8).
# <out dir> must be new or empty.
#
# Each input gets a line in <out dir>/<corpus>.results, a result and the input:
#
#   SAME        both built, every object identical
#   DIFF        both built; then the objects that differ, and +name / -name for
#               an object only the after / before build made.  A differing
#               object's disassembly diff is kept in <out dir>/diff.<input>.<object>.diff
#   BOTHFAIL    both failed, with the same output
#   FAILDIFF    both failed, with different output, kept in
#               <out dir>/faildiff.<input>.{before,after}
#   AFTERFAIL / BEFOREFAIL
#               one build failed; its output is kept in
#               <out dir>/{after,before}fail.<input>.out
#   NOOBJ       both built, but a build left no main.o (a flag in -f that stops
#               bnc from writing objects), so nothing was compared
#   TIMEOUT     a build ran past 15 minutes (when timeout or gtimeout exists)
#
# (<input> with its slashes made underscores.)  Per corpus, prints the count of
# each result and every line that is not SAME or BOTHFAIL.  Exits 1 when an input
# is anything else or has no result, when a corpus builds none of its inputs, or
# when no corpus has an input.
#
# A change that should not alter the generated code is checked with <before bnc>
# built from the change's parent and <after bnc> with the change, on the same
# base: every line should be SAME or BOTHFAIL.
set -u
# One collation for ls, sort and comm.
LC_ALL=C
export LC_ALL
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
BINATE_DIR="$(cd "$(dirname "$SCRIPT")/.." && pwd)"

# one <kind> <input>: build one input with both builds and print its result
# line.  The main mode runs it through xargs, with BEFORE, AFTER, OUT, TARGET,
# FLAGS and TIMEOUT exported; each build runs in a scratch directory under OUT.
one() {
    kind=$1
    f=$2
    d=$(mktemp -d "$OUT/job.XXXXXX") || exit 2
    mkdir -p "$d/b" "$d/a"
    root=$BINATE_DIR
    if [ "$kind" = multi ]; then root=$(dirname "$BINATE_DIR/$f"); fi
    tflags=
    if [ -n "$TARGET" ]; then tflags="--target $TARGET"; fi
    paths="$BINATE_DIR/scripts/binate-paths.sh"
    # tflags and FLAGS are split into words on purpose.
    # shellcheck disable=SC2086
    ip=$("$paths" --iface --base "$BINATE_DIR" --prepend "$root" $tflags)
    # shellcheck disable=SC2086
    lp=$("$paths" --impl --base "$BINATE_DIR" --prepend "$root" $tflags)
    for side in b a; do
        if [ $side = b ]; then bnc=$BEFORE; else bnc=$AFTER; fi
        # shellcheck disable=SC2086
        (cd "$d/$side" && $TIMEOUT "$bnc" -c $tflags $FLAGS -I "$ip" -L "$lp" \
                --build-dir "$d/$side" "$BINATE_DIR/$f") > "$d/$side.out" 2>&1
        echo $? > "$d/$side.rc"
    done
    rb=$(cat "$d/b.rc")
    ra=$(cat "$d/a.rc")
    tag=$(echo "$f" | tr / _)
    if [ -n "$TIMEOUT" ] && { [ "$rb" -eq 124 ] || [ "$ra" -eq 124 ]; }; then
        echo "TIMEOUT $f"
    elif [ "$rb" -ne 0 ] && [ "$ra" -ne 0 ]; then
        # A build's output names its build directory; the two differ.
        sed "s#$d/b#BUILD#g" "$d/b.out" > "$d/b.norm"
        sed "s#$d/a#BUILD#g" "$d/a.out" > "$d/a.norm"
        if cmp -s "$d/b.norm" "$d/a.norm"; then
            echo "BOTHFAIL $f"
        else
            echo "FAILDIFF $f"
            cp "$d/b.norm" "$OUT/faildiff.$tag.before"
            cp "$d/a.norm" "$OUT/faildiff.$tag.after"
        fi
    elif [ "$ra" -ne 0 ]; then
        echo "AFTERFAIL $f"
        cp "$d/a.out" "$OUT/afterfail.$tag.out"
    elif [ "$rb" -ne 0 ]; then
        echo "BEFOREFAIL $f"
        cp "$d/b.out" "$OUT/beforefail.$tag.out"
    else
        (cd "$d/b" && ls) > "$d/b.list"
        (cd "$d/a" && ls) > "$d/a.list"
        if ! grep -qx main.o "$d/b.list" || ! grep -qx main.o "$d/a.list"; then
            echo "NOOBJ $f"
            case $d in "$OUT"/job.*) rm -rf "$d" ;; esac
            return
        fi
        found=
        for m in $(comm -12 "$d/b.list" "$d/a.list"); do
            cmp -s "$d/b/$m" "$d/a/$m" && continue
            found="$found $m"
            if command -v objdump > /dev/null; then
                (cd "$d/b" && objdump -d -r -t --no-show-raw-insn "$m") > "$d/b.dis" 2>&1
                (cd "$d/a" && objdump -d -r -t --no-show-raw-insn "$m") > "$d/a.dis" 2>&1
                diff "$d/b.dis" "$d/a.dis" > "$OUT/diff.$tag.$m.diff"
            fi
        done
        for m in $(comm -13 "$d/b.list" "$d/a.list"); do found="$found +$m"; done
        for m in $(comm -23 "$d/b.list" "$d/a.list"); do found="$found -$m"; done
        if [ -z "$found" ]; then echo "SAME $f"; else echo "DIFF $f$found"; fi
    fi
    case $d in "$OUT"/job.*) rm -rf "$d" ;; esac
}

# in_multipkg <file>: true if a .bn belongs to a multi-package test -- it is a
# main.bn, or a directory above it (below conformance/) holds one.
in_multipkg() {
    case "$1" in */main.bn) return 0 ;; esac
    _d=$(dirname "$1")
    while [ "$_d" != conformance ] && [ "$_d" != . ]; do
        [ -f "$_d/main.bn" ] && return 0
        _d=$(dirname "$_d")
    done
    return 1
}

# The conformance subtrees whose tests are found recursively.
SUBTREES="conformance/matrix conformance/regressions conformance/spec conformance/stdlib"

single_inputs() {
    # shellcheck disable=SC2086
    for f in conformance/*.bn $(find $SUBTREES -name '*.bn'); do
        [ -f "$f" ] || continue
        in_multipkg "$f" || echo "$f"
    done
}

multi_inputs() {
    for d in conformance/[0-9][0-9][0-9]*_*/; do
        if [ -f "${d}main.bn" ]; then echo "${d}main.bn"; fi
    done
    # shellcheck disable=SC2086
    find $SUBTREES -name main.bn
}

if [ "${1:-}" = --one ]; then
    shift
    one "$@"
    exit 0
fi

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
JOBS=8
TARGET=
FLAGS=
MATCH=
while getopts j:t:f:m: opt; do
    case $opt in
        j) JOBS=$OPTARG ;;
        t) TARGET=$OPTARG ;;
        f) FLAGS=$OPTARG ;;
        m) MATCH=$OPTARG ;;
        *) usage; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
if [ $# -lt 3 ]; then
    usage
    exit 2
fi
for b in "$1" "$2"; do
    if [ ! -f "$b" ] || [ ! -x "$b" ]; then
        echo "codegen-ab.sh: $b is not an executable" >&2
        exit 2
    fi
done
if [ -d "$3" ] && [ -n "$(ls -A "$3")" ]; then
    echo "codegen-ab.sh: $3 is not empty" >&2
    exit 2
fi
BEFORE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
AFTER="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
mkdir -p "$3" || exit 2
OUT="$(cd "$3" && pwd)"
shift 3
TIMEOUT=$(command -v timeout || command -v gtimeout || true)
if [ -n "$TIMEOUT" ]; then TIMEOUT="$TIMEOUT 900"; fi
export BEFORE AFTER OUT TARGET FLAGS TIMEOUT
cd "$BINATE_DIR" || exit 2
status=0
total=0
for c in ${*:-single multi bnc}; do
    case $c in
        single) single_inputs ;;
        multi) multi_inputs ;;
        bnc) echo cmd/bnc ;;
        *) echo "codegen-ab.sh: unknown corpus $c" >&2; exit 2 ;;
    esac | sort | grep -E -e "${MATCH:-.}" | sed "s/^/$c /" > "$OUT/$c.inputs"
    n=$(wc -l < "$OUT/$c.inputs" | tr -d ' ')
    total=$((total + n))
    : > "$OUT/$c.results"
    if [ "$n" -gt 0 ]; then
        xargs -P "$JOBS" -L 1 "$SCRIPT" --one < "$OUT/$c.inputs" > "$OUT/$c.results"
    fi
    r=$(wc -l < "$OUT/$c.results" | tr -d ' ')
    echo "== $c: $n inputs"
    awk '{ print $1 }' "$OUT/$c.results" | sort | uniq -c
    if [ "$r" -ne "$n" ]; then
        echo "MISSING $((n - r)) result(s)"
        status=1
    fi
    if [ "$n" -gt 0 ] && ! grep -q '^SAME \|^DIFF ' "$OUT/$c.results"; then
        echo "NOTHING BUILT: no input of $c built with both builds"
        status=1
    fi
    if grep -v '^SAME \|^BOTHFAIL ' "$OUT/$c.results"; then status=1; fi
done
if [ "$total" -eq 0 ]; then
    echo "NO INPUTS: no corpus has an input"
    status=1
fi
exit $status
