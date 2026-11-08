#!/bin/sh
# e2e/arm32-baremetal-fault-report.sh — a CPU fault on arm32 bare metal is
# reported, and ends the run.
#
# runtime/baremetal_arm32/crt0.s points VBAR at its exception vectors, whose
# handlers write "fatal: <exception> at pc 0x<pc>[, address 0x<address>]"
# through semihosting and exit with status 1.  Three programs fault one way
# each under qemu-system-arm:
#   - a Binate load from an address with no memory behind it (a data abort);
#   - a __c_call of an asm probe that executes UDF (an undefined instruction);
#   - a __c_call of an asm probe that branches to an address with no memory
#     behind it (a prefetch abort).
# Each must print the report -- the pc of the faulting instruction (checked
# exactly for the two probes), and the faulting address for an abort -- and
# exit 1 within the timeout, where a missing handler would loop forever.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || echo clang)}"
QEMU="${QEMU_SYSTEM_ARM:-$(command -v qemu-system-arm || true)}"

# --- prerequisite probe (SKIP, not FAIL, when unavailable) ----------------
if [ -z "$QEMU" ]; then
    echo "SKIP: qemu-system-arm not found (needed to run the arm32-baremetal programs)"
    exit 0
fi
if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: clang not found"
    exit 0
fi
if ! echo 'int main(void){return 0;}' | "$CLANG" -target arm-none-eabi -mfloat-abi=soft \
        -ffreestanding -nostdlib -x c -c - -o /tmp/_bn_e2e_probe_fault.o 2>/dev/null; then
    echo "SKIP: clang cannot target arm-none-eabi"
    rm -f /tmp/_bn_e2e_probe_fault.o
    exit 0
fi
rm -f /tmp/_bn_e2e_probe_fault.o
if ! command -v ld.lld >/dev/null 2>&1; then
    echo "SKIP: ld.lld (lld) not found (needed to link the arm32-baremetal programs)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_fault_report.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# NOWHERE has no memory behind it on QEMU `virt`: RAM starts at 0x40000000 and
# these runs give it 16 MiB, and no device is mapped at 0x60000000.
NOWHERE=0x60000000

# --- the asm probes ----------------------------------------------------------
cat > "$TMP/probes.s" <<'EOF'
	.arch armv7-a
	.text

	.global probe_udf
probe_udf:
	udf     #0

	.global probe_udf_addr
probe_udf_addr:
	ldr     r0, =probe_udf
	bx      lr

	.global probe_jump_nowhere
probe_jump_nowhere:
	ldr     r0, =0x60000000
	bx      r0

	.ltorg
EOF

# --- the programs --------------------------------------------------------------
mkdir -p "$TMP/dabort" "$TMP/undef" "$TMP/pabort"
cat > "$TMP/dabort/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

func main() {
	testing.Println("loading")
	var p *int = bit_cast(*int, cast(uint, 0x60000000))
	testing.Println(p[0])
	testing.Println("not reached")
}
EOF
cat > "$TMP/undef/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

func main() {
	testing.Println(__c_call("probe_udf_addr", int))
	__c_call("probe_udf", "void")
	testing.Println("not reached")
}
EOF
cat > "$TMP/pabort/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

func main() {
	testing.Println("jumping")
	__c_call("probe_jump_nowhere", "void")
	testing.Println("not reached")
}
EOF

# --- build gen1 bnc from current source -----------------------------------
GEN1="$TMP/gen1-bnc"
gen1_log="$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1)" || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed" >&2
    echo "$gen1_log" | tail -5 >&2
    exit 1
fi

if ! "$CLANG" -target arm-none-eabi -march=armv7-a -mfloat-abi=soft -c \
        "$TMP/probes.s" -o "$TMP/probes.o" 2>"$TMP/as.err"; then
    echo "FAIL: assembling probes.s failed" >&2
    head -6 "$TMP/as.err" >&2
    exit 1
fi

IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-baremetal)"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --target arm32-baremetal)"
LD_EXTRA=""
if [ "$(uname -s)" = "Darwin" ]; then LD_EXTRA="--cflag -fuse-ld=lld"; fi

# build_and_run <name>: compile and link $TMP/<name>/main.bn, run it under qemu,
# and leave its output in RUN_OUT and its exit status in RUN_RC.
build_and_run() {
    mkdir -p "$TMP/$1/build"
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" -I "$BINATE_DIR" -L "$BINATE_DIR" \
            --target arm32-baremetal \
            --runtime "$BINATE_DIR/runtime/baremetal_arm32/crt0.s" \
            $LD_EXTRA --link-after-objs "$TMP/probes.o" \
            --build-dir "$TMP/$1/build" -o "$TMP/$1/prog" "$TMP/$1/main.bn" >"$TMP/$1/comp.log" 2>&1 \
            || [ ! -x "$TMP/$1/prog" ]; then
        echo "FAIL: compile/link of the $1 program failed" >&2
        tail -8 "$TMP/$1/comp.log" >&2
        exit 1
    fi
    RUN_OUT="$(timeout 15 "$QEMU" -M virt -cpu cortex-a15 -m 16M -nographic -semihosting \
            -no-reboot -kernel "$TMP/$1/prog" 2>&1)"
    RUN_RC=$?
}

# expect <name> <want>: the run's output must be <want> and its status 1.
expect() {
    if [ "$RUN_RC" -ne 1 ] || [ "$RUN_OUT" != "$2" ]; then
        echo "FAIL: arm32 bare-metal $1 report (status $RUN_RC; 124 means it hung)" >&2
        echo "--- got ---"  >&2; printf '%s\n' "$RUN_OUT" >&2
        echo "--- want ---" >&2; printf '%s\n' "$2" >&2
        exit 1
    fi
}

build_and_run dabort
# The load's own pc is not known here; take it from the report, and check
# that the report is otherwise exact.
pc="$(printf '%s\n' "$RUN_OUT" | sed -n 's/^fatal: data abort at pc \(0x[0-9a-f]\{8\}\), address .*/\1/p')"
expect "data abort" "$(printf 'loading\nfatal: data abort at pc %s, address %s' "${pc:-<none>}" "$NOWHERE")"

build_and_run undef
addr="$(printf '%s\n' "$RUN_OUT" | head -1)"
case "$addr" in
    ''|*[!0-9]*) echo "FAIL: the undef program did not print probe_udf's address: $addr" >&2; exit 1 ;;
esac
expect "undefined instruction" "$(printf '%s\nfatal: undefined instruction at pc 0x%08x' "$addr" "$addr")"

build_and_run pabort
expect "prefetch abort" "$(printf 'jumping\nfatal: prefetch abort at pc %s, address %s' "$NOWHERE" "$NOWHERE")"

echo "PASS: arm32 bare-metal CPU faults (data abort, undefined instruction, prefetch abort) are reported and exit 1 under qemu"
exit 0
