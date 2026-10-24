#!/bin/sh
# E2E: the native backends compile one very large function in bounded time and
# memory.
#
# The native backends' per-function analyses (liveness, the frame planner's slot
# analyses, the aggregate-load elision) must scale with a function's size: once,
# one of them was quadratic in time and memory, and the generated unit-test
# runner's main — one function with a block group per test — took 64 GB to compile
# for a package of 1569 tests, which got CI runners killed.  This test builds a
# main of the same shape — N blocks, each storing a call's aggregate result into a
# local, passing the local by value to another call, and holding a managed value
# across a branch — and compiles it with --backend native for the host (linked and
# run, checking its output) and for x86-64, AArch64 and arm32 Linux (objects only).
# Each compile must stay under a CPU-time and a peak-memory budget well above what
# a linear compile needs and well below what a quadratic one did.
#
# Exit 0 on full pass; non-zero with diagnostics on any failure.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

# The function's size, and each compile's budgets: CPU seconds (user + system, the
# compiler and its children) and peak resident memory in bytes.  A compile running
# over a wall-clock limit of four times the CPU budget is stopped and fails.
N=2000
MAX_CPU=30
MAX_RSS=$((2 * 1024 * 1024 * 1024))
WALL_LIMIT=$((MAX_CPU * 4))

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_largefn.XXXXXX")"
trap 'rm -rf "$TMP"; cleanup_compilers' EXIT

build_gen1

# ----- The program: main with N blocks -----
mkdir -p "$TMP/prog"
{
    printf 'package "main"\n\nimport "pkg/builtins/testing"\n\n'
    printf 'type Pair struct {\n\ta int\n\tb int\n}\n\n'
    printf 'func mk(i int) Pair {\n\tvar p Pair\n\tp.a = i\n\tp.b = i + 1\n\treturn p\n}\n\n'
    printf 'func use(p Pair) int { return p.a + p.b }\n\n'
    printf 'func label(i int) @[]char {\n\tif i %% 2 == 0 { return "even" }\n\treturn "odd"\n}\n\n'
    printf 'func main() {\n\tvar sum int = 0\n\tvar evens int = 0\n'
    i=0
    while [ "$i" -lt "$N" ]; do
        printf '\tif sum >= 0 {\n\t\tvar p%d Pair = mk(%d)\n\t\tsum = sum + use(p%d)\n' "$i" "$i" "$i"
        printf '\t\tvar r%d @[]char = label(%d)\n\t\tif len(r%d) > 3 { evens = evens + 1 }\n\t}\n' "$i" "$i" "$i"
        i=$((i + 1))
    done
    printf '\ttesting.Println(sum)\n\ttesting.Println(evens)\n}\n'
} > "$TMP/prog/main.bn"
# sum adds 2i + 1 for each i < N, so N * N; evens counts the even i.
EXPECTED="$(printf '%d\n%d' $((N * N)) $((N / 2)))"

# measure OUT CMD... runs CMD, writing "<exit status> <cpu seconds> <peak rss bytes>"
# to OUT; a run past WALL_LIMIT seconds is stopped and reports status 124.
cat > "$TMP/measure.py" <<'PY'
import resource, subprocess, sys
out, limit, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
try:
    rc = subprocess.call(cmd, timeout=limit)
except subprocess.TimeoutExpired:
    rc = 124
r = resource.getrusage(resource.RUSAGE_CHILDREN)
rss = r.ru_maxrss * (1 if sys.platform == 'darwin' else 1024)
with open(out, 'w') as f:
    f.write("%d %.2f %d\n" % (rc, r.ru_utime + r.ru_stime, rss))
PY

rc=0

# check NAME — judges the measurement in $TMP/NAME.m against the budgets.
check() {
    read -r status cpu rss < "$TMP/$1.m"
    echo "$1: exit $status, $cpu s CPU, $((rss / 1048576)) MiB peak"
    if [ "$status" -ne 0 ]; then
        echo "FAIL: $1: the compile failed (exit $status; 124 is the $WALL_LIMIT s wall limit)"
        sed 's/^/  /' "$TMP/$1.log" | tail -20
        rc=1
        return
    fi
    if [ "$(python3 -c "print(1 if $cpu > $MAX_CPU else 0)")" -ne 0 ]; then
        echo "FAIL: $1: $cpu s CPU is over the $MAX_CPU s budget"
        rc=1
    fi
    if [ "$rss" -gt "$MAX_RSS" ]; then
        echo "FAIL: $1: $((rss / 1048576)) MiB peak is over the $((MAX_RSS / 1048576)) MiB budget"
        rc=1
    fi
}

# ----- The host: link and run -----
mkdir -p "$TMP/host-build"
python3 "$TMP/measure.py" "$TMP/host.m" "$WALL_LIMIT" "$GEN1_COMPILER" --backend native \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    --build-dir "$TMP/host-build" -o "$TMP/prog-host" "$TMP/prog" > "$TMP/host.log" 2>&1
check host
if [ -x "$TMP/prog-host" ]; then
    got="$("$TMP/prog-host" 2>&1)"
    if [ "$got" != "$EXPECTED" ]; then
        echo "FAIL: the host program printed:"
        echo "$got" | sed 's/^/  /'
        echo "expected:"
        echo "$EXPECTED" | sed 's/^/  /'
        rc=1
    fi
fi

# ----- Each native target: objects only (bnc -c writes them to the cwd) -----
for target in x86_64-linux aarch64-linux arm32-linux; do
    mkdir -p "$TMP/obj-$target"
    (cd "$TMP/obj-$target" && python3 "$TMP/measure.py" "$TMP/$target.m" "$WALL_LIMIT" \
        "$GEN1_COMPILER" --backend native --target "$target" -c \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target "$target")" \
        -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --target "$target")" \
        "$TMP/prog" > "$TMP/$target.log" 2>&1)
    check "$target"
done

if [ "$rc" -eq 0 ]; then
    echo "PASS: a $N-block function compiles natively within $MAX_CPU s CPU and $((MAX_RSS / 1048576)) MiB on every target"
fi
exit "$rc"
