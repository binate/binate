#!/bin/sh
# e2e/mixed-backend-calls.sh — native- and LLVM-compiled code calling each other.
#
# One program may link packages compiled by different backends (a `bnc --pkg` object
# from one, the rest from the other), so every Binate-internal call between them must
# follow the one internal calling convention (docs/abi/02).  Conformance compiles a
# whole program with ONE backend, so a placement the two backends decide differently
# passes there; this compiles a dependency package with one backend and the program
# with the other, in both directions, and checks every result.
#
# The shapes are those each backend places by its own code: multi-value returns with
# a struct / array field (a float HFA and not — struct and array, 8 to 32 bytes, word-
# multiple and word-rounded, first and last, five of them), a single HFA result, HFA
# arguments, and a multi-value return through a func value (its shim emitted on the
# callee's side and on the caller's), a capturing closure and an interface method.
#
# Both backends target the host arch — or, with MIXED_TARGET=arm32-linux (set by
# e2e/arm32-mixed-backend-calls.sh), arm32 hard-float, linked with
# arm-linux-gnueabihf-gcc and run under qemu-arm (SKIP when those are missing).
# Exit 0 on full pass; non-zero with diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
[ -d "$BINATE_DIR/pkg" ] || { echo "FAIL: not a binate repo: $BINATE_DIR" >&2; exit 1; }

CLANG="${CLANG:-$(command -v clang || command -v cc || echo cc)}"
ARM32=""
TARGET_ARGS=""
PATHS_ARGS=""
if [ "${MIXED_TARGET:-}" = arm32-linux ]; then
    ARM32=1
    QEMU_ARM="${QEMU_ARM:-$(command -v qemu-arm-static || command -v qemu-arm || true)}"
    ARM32_CC="${ARM32_CC:-$(command -v arm-linux-gnueabihf-gcc || true)}"
    [ -n "$QEMU_ARM" ] || { echo "SKIP: qemu-arm(-static) not found"; exit 0; }
    [ -n "$ARM32_CC" ] || { echo "SKIP: arm-linux-gnueabihf-gcc not found"; exit 0; }
    TARGET_ARGS="--target arm32-linux"
    PATHS_ARGS="--target arm32-linux"
elif [ -n "${MIXED_TARGET:-}" ]; then
    echo "FAIL: unknown MIXED_TARGET ${MIXED_TARGET}"; exit 1
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_mixbe.XXXXXX")" || true
[ -d "$TMP" ] || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# arm32: gate on the whole dependency — gcc can link a static arm-linux-gnueabihf
# binary (-static: self-contained under qemu, and non-PIE for the native backend's
# absolute movw/movt relocations) AND qemu can run it.
if [ -n "$ARM32" ] && ! { echo 'int main(void){return 0;}' \
        | "$ARM32_CC" -static -x c - -o "$TMP/probe" 2>/dev/null \
        && "$QEMU_ARM" "$TMP/probe" >/dev/null 2>&1; }; then
    echo "SKIP: cannot cross-compile + run a static arm-linux-gnueabihf binary under qemu"
    exit 0
fi

# link_prog <out> <objects...>: link the program for the target.
link_prog() {
    o="$1"; shift
    if [ -n "$ARM32" ]; then "$ARM32_CC" -static -w -o "$o" "$@"; else "$CLANG" -w -o "$o" "$@"; fi
}

# run_prog <exe>: run the program, under qemu on arm32.
run_prog() {
    if [ -n "$ARM32" ]; then "$QEMU_ARM" "$1"; else "$1"; fi
}

echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log="$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1)" || true
[ -x "$GEN1" ] || { echo "FAIL: gen1 bnc build failed"; echo "$gen1_log" | tail -20; exit 1; }
IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" $PATHS_ARGS)"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" $PATHS_ARGS)"

# --- the dependency package, compiled by one backend ----------------------
mkdir -p "$TMP/src/pkg/mbdep"
cat > "$TMP/src/pkg/mbdep.bni" <<'EOF'
package "pkg/mbdep"

// V2f is a two-float32 HFA (8 bytes).
type V2f struct { x float32; y float32 }

// V3f is a three-float32 HFA (12 bytes — not a whole number of 8-byte words).
type V3f struct { x float32; y float32; z float32 }

// D2 is a two-float64 HFA.
type D2 struct { x float64; y float64 }

// D4 is a four-float64 HFA (32 bytes).
type D4 struct { a float64; b float64; c float64; d float64 }

// S3 is a 12-byte non-float struct.
type S3 struct { a int32; b int32; c int32 }

func PairVf(a float32) (V2f, int32)
func PairIv(a float32) (int32, V3f)
func PairDf(a float64) (D2, float64)
func PairFv(a float32) (float32, V2f)
func PairIs(a int32) (int32, S3)
func PairAi(a float32) ([2]float32, int32)
func PairD4(a float64) (D4, int32)
func Five(a float32) (V2f, V2f, V2f, V2f, V2f)
func OneV3(a float32) V3f
func SumD2(p D2, q D2, r float64) float64
func PairVfFn() *func(float32) (V2f, int32)
func MakePairer(k int32) @func(float32) (V2f, int32)

// Ops returns a tuple with an HFA field through an interface method.
interface Ops {
	Pair(a float32) (V2f, int32)
}

// Impl is the Ops implementation.
type Impl struct { k int32 }

impl *Impl : Ops

func (p *Impl) Pair(a float32) (V2f, int32)
EOF
cat > "$TMP/src/pkg/mbdep/mbdep.bn" <<'EOF'
package "pkg/mbdep"

func PairVf(a float32) (V2f, int32) { return V2f{x: a, y: a + 1.0}, 7 }

func PairIv(a float32) (int32, V3f) { return 8, V3f{x: a, y: a + 1.0, z: a + 2.0} }

func PairDf(a float64) (D2, float64) { return D2{x: a, y: a + 1.0}, a + 2.0 }

func PairFv(a float32) (float32, V2f) { return a, V2f{x: a + 1.0, y: a + 2.0} }

func PairIs(a int32) (int32, S3) { return a, S3{a: a + 1, b: a + 2, c: a + 3} }

func PairAi(a float32) ([2]float32, int32) { return [2]float32{a, a * 2.0}, 9 }

func PairD4(a float64) (D4, int32) { return D4{a: a, b: a + 1.0, c: a + 2.0, d: a + 3.0}, 4 }

func Five(a float32) (V2f, V2f, V2f, V2f, V2f) {
	return V2f{x: a, y: a + 1.0}, V2f{x: a + 2.0, y: a + 3.0}, V2f{x: a + 4.0, y: a + 5.0},
			V2f{x: a + 6.0, y: a + 7.0}, V2f{x: a + 8.0, y: a + 9.0}
}

func OneV3(a float32) V3f { return V3f{x: a, y: a + 1.0, z: a + 2.0} }

func SumD2(p D2, q D2, r float64) float64 { return p.x + p.y + q.x + q.y + r }

func PairVfFn() *func(float32) (V2f, int32) { return PairVf }

func MakePairer(k int32) @func(float32) (V2f, int32) {
	return func(a float32) (V2f, int32) { return V2f{x: a, y: a * 2.0}, k }
}

func (p *Impl) Pair(a float32) (V2f, int32) { return V2f{x: a, y: a * 2.0}, p.k }
EOF

# --- the program, compiled by the other backend ---------------------------
cat > "$TMP/src/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/mbdep"

func main() {
	v, n := mbdep.PairVf(1.5)
	testing.Println(v.x, v.y, n)
	m, w := mbdep.PairIv(2.5)
	testing.Println(m, w.x, w.y, w.z)
	d, e := mbdep.PairDf(3.5)
	testing.Println(d.x, d.y, e)
	g, h := mbdep.PairFv(9.5)
	testing.Println(g, h.x, h.y)
	k, s := mbdep.PairIs(4)
	testing.Println(k, s.a, s.b, s.c)
	ar, an := mbdep.PairAi(1.5)
	testing.Println(ar[0], ar[1], an)
	q, qn := mbdep.PairD4(1.5)
	testing.Println(q.a, q.b, q.c, q.d, qn)
	f1, f2, f3, f4, f5 := mbdep.Five(1.5)
	testing.Println(f1.x, f2.y, f3.x, f4.y, f5.x, f5.y)
	var o mbdep.V3f = mbdep.OneV3(5.5)
	testing.Println(o.x, o.y, o.z)
	testing.Println(mbdep.SumD2(mbdep.D2{x: 1.25, y: 2.5}, mbdep.D2{x: 3.75, y: 5.0}, 0.5))
	var f *func(float32) (mbdep.V2f, int32) = mbdep.PairVfFn()
	fv, fn := f(6.5)
	testing.Println(fv.x, fv.y, fn)
	var gv *func(float32) (mbdep.V2f, int32) = mbdep.PairVf
	gx, gn := gv(3.5)
	testing.Println(gx.x, gx.y, gn)
	var c @func(float32) (mbdep.V2f, int32) = mbdep.MakePairer(12)
	cv, cn := c(2.5)
	testing.Println(cv.x, cv.y, cn)
	var im mbdep.Impl
	im.k = 11
	var ops *mbdep.Ops = &im
	iv, ik := ops.Pair(1.5)
	testing.Println(iv.x, iv.y, ik)
}
EOF
WANT="1.500000 2.500000 7
8 2.500000 3.500000 4.500000
3.500000 4.500000 5.500000
9.500000 10.500000 11.500000
4 5 6 7
1.500000 3.000000 9
1.500000 2.500000 3.500000 4.500000 4
1.500000 4.500000 5.500000 8.500000 9.500000 10.500000
5.500000 6.500000 7.500000
13.000000
6.500000 7.500000 7
3.500000 4.500000 7
2.500000 5.000000 12
1.500000 3.000000 11"

PASSES=0
FAILS=0

# check_mix <dep-backend> <main-backend>: compile pkg/mbdep with the first backend
# (--pkg) and the program with the second (-c, which also emits every dependency's
# object — pkg/mbdep's is replaced by the --pkg one), link, run, compare.
check_mix() {
    depbe="$1"; mainbe="$2"
    label="dep=$depbe,main=$mainbe"
    work="$TMP/$depbe-$mainbe"
    mkdir -p "$work/dep" "$work/main"
    if ! "$GEN1" -I "$TMP/src:$IFACE" -L "$TMP/src:$IMPL" --backend "$depbe" $TARGET_ARGS \
            --build-dir "$work/dep" --pkg pkg/mbdep >"$work/dep.log" 2>&1; then
        echo "FAIL: $label: --pkg pkg/mbdep failed"; tail -5 "$work/dep.log"
        FAILS=$((FAILS + 1)); return
    fi
    depobj="$(ls "$work/dep"/*.o 2>/dev/null)"
    if [ "$(printf '%s\n' "$depobj" | grep -c .)" -ne 1 ]; then
        echo "FAIL: $label: expected one object from --pkg, got: $depobj"
        FAILS=$((FAILS + 1)); return
    fi
    if ! (cd "$TMP/src" && "$GEN1" -I "$TMP/src:$IFACE" -L "$TMP/src:$IMPL" \
            --backend "$mainbe" $TARGET_ARGS --build-dir "$work/main" -c main.bn) >"$work/main.log" 2>&1 \
            || [ ! -f "$work/main/main.o" ]; then
        echo "FAIL: $label: -c main.bn failed"; tail -5 "$work/main.log"
        FAILS=$((FAILS + 1)); return
    fi
    # The -c build names pkg/mbdep's object after its full path.
    depname="pkg__mbdep.o"
    if [ ! -f "$work/main/$depname" ]; then
        echo "FAIL: $label: the -c build has no $depname to replace"
        ls "$work/main"
        FAILS=$((FAILS + 1)); return
    fi
    objs="$(ls "$work/main"/*.o | grep -v "/$depname\$" | tr '\n' ' ')"
    if ! link_prog "$work/run" $objs "$depobj" 2>"$work/link.err"; then
        echo "FAIL: $label: link failed"; head -5 "$work/link.err"
        FAILS=$((FAILS + 1)); return
    fi
    got="$(run_prog "$work/run" 2>&1)"
    if [ "$got" = "$WANT" ]; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label: output mismatch"
        printf '%s\n' "$WANT" > "$work/want"
        printf '%s\n' "$got" > "$work/got"
        diff "$work/want" "$work/got" | sed 's/^/    /'
        FAILS=$((FAILS + 1))
    fi
}

check_mix llvm llvm
check_mix native native
check_mix llvm native
check_mix native llvm

echo ""
echo "=== mixed-backend calls: $PASSES passed, $FAILS failed ==="
[ "$FAILS" -eq 0 ]
