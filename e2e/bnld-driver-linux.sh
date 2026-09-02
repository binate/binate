#!/bin/sh
# e2e/bnld-driver-linux.sh — End-to-end proof of Step 7: an INTERPRETED linker driver
# drives the COMPILED linker.  `bnld -driver drivers/elf.bn` embeds the bytecode VM,
# injects the compiled pkg/binate/link library as an extern, and runs the driver's typed
# `Drive(objs, out, target)` entry under the VM — the driver's link.* calls execute
# compiled.  The dual-mode showcase: interpreted policy driving the compiled linker.
#
# Two hand-asm programs are assembled with bnas, linked with `bnld -driver`, structure-
# checked as static ELF64 ET_EXEC, and run:
#   * exit42 — exits 42 (no relocations; pins the exit path through the driver).
#   * hello  — writes "hi\n" then exits 0 (a .rodata string via a PC-relative reloc).
#
# The run needs a linux-x86-64 environment: native on an x86-64 Linux host, else Docker on
# a Mac.  Where it can't run, the build + structure check still assert the driver produced
# a valid image.  Exit 0 on pass (incl. run-skipped); non-zero on any failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
DRIVER="$BINATE_DIR/drivers/elf.bn"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_driver.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ----- build bnas + bnld from the current tree -----
BNAS="$TMP/bnas"
if ! "$BINATE_DIR/scripts/build-bnas.sh" -o "$BNAS" > "$TMP/build_bnas.log" 2>&1; then
    echo "FAIL: could not build bnas" >&2
    cat "$TMP/build_bnas.log" >&2
    exit 1
fi
BNLD="$TMP/bnld"
if ! "$BINATE_DIR/scripts/build-bnld.sh" -o "$BNLD" > "$TMP/build_bnld.log" 2>&1; then
    echo "FAIL: could not build bnld" >&2
    cat "$TMP/build_bnld.log" >&2
    exit 1
fi

# The driver's imports (pkg/binate/link, buf, pkg/std/*) resolve from the standard search
# dirs — supplied to bnld as flags from binate-paths.sh, NOT a formula baked into bnld.
IFACE_DIRS="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL_DIRS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# check_elf <path> <name>: the driver's output must be a static ELF64 ET_EXEC.
check_elf() {
    _p="$1"; _n="$2"
    if [ "$(od -An -tx1 -N4 "$_p" | tr -d ' \n')" != "7f454c46" ]; then
        echo "FAIL: $_n is not an ELF file" >&2; exit 1
    fi
    if [ "$(od -An -tu1 -j16 -N1 "$_p" | tr -d ' \n')" != "2" ]; then
        echo "FAIL: $_n is not ET_EXEC" >&2; exit 1
    fi
    if [ ! -x "$_p" ]; then echo "FAIL: $_n is not owner-executable" >&2; exit 1; fi
}

# drv_link <name> <bnas-arch> <bnld-target> <want-e_machine>: assemble the stdin .s with
# bnas for <bnas-arch>, link it via the INTERPRETED driver (bnld -driver) for <bnld-target>,
# and structure-check the result (static ELF64 ET_EXEC with the expected e_machine — so the
# driver selected the right machine for the target).
drv_link() {
    _name="$1"; _arch="$2"; _target="$3"; _emach="$4"
    cat > "$TMP/$_name.s"
    if ! "$BNAS" -arch "$_arch" -o "$TMP/$_name.o" "$TMP/$_name.s" > "$TMP/$_name.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $_name" >&2; cat "$TMP/$_name.asm.log" >&2; exit 1
    fi
    if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target "$_target" \
            -o "$TMP/$_name" "$TMP/$_name.o" > "$TMP/$_name.link.log" 2>&1; then
        echo "FAIL: bnld -driver could not link $_name" >&2; cat "$TMP/$_name.link.log" >&2; exit 1
    fi
    check_elf "$TMP/$_name" "$_name"
    _got="$(od -An -tu1 -j18 -N1 "$TMP/$_name" | tr -d ' \n')" # e_machine low byte
    if [ "$_got" != "$_emach" ]; then
        echo "FAIL: $_name e_machine=$_got, want $_emach" >&2; exit 1
    fi
    echo "PASS: $_name linked via the interpreted driver → static ELF64 (e_machine $_emach)"
}

drv_link exit42 x64 linux-x64 62 <<'EOF'
.arch x64
.section text
.global _start
_start:
	mov edi, 42
	mov eax, 60
	syscall
EOF

drv_link hello x64 linux-x64 62 <<'EOF'
.arch x64
.section rodata
msg:
	.ascii "hi\n"
.section text
.global _start
_start:
	mov eax, 1
	mov edi, 1
	lea rsi, [rip + msg]
	mov edx, 3
	syscall
	mov eax, 60
	xor edi, edi
	syscall
EOF

# aarch64: same driver, linux-aarch64 target — proves the driver's machine selection and
# link.Link's aarch64 path produce a valid arm64 ELF (e_machine 183).  The RUN of a
# driver-agnostic aarch64 static ELF is already covered by bnld-linux-aarch64.sh.
drv_link exit42_aa aarch64 linux-aarch64 183 <<'EOF'
.arch aarch64
.section text
.global _start
_start:
	mov x0, #42
	mov x8, #93
	svc #0
EOF

# ----- init-driver: a driver whose OWN top-level var initializer must run before Drive.
#       Regression for LoadCallable's init dispatcher — without it, package init never runs,
#       sentinel stays 0, Drive returns an error, and the link below FAILS. -----
cat > "$TMP/init_driver.bn" <<'BN'
package "driver"

import "pkg/binate/buf"
import "pkg/binate/link"

// A non-constant top-level initializer emits driver.__init; if it does not run, sentinel
// is the zero value (0), not 42.
var sentinel int = computeSentinel()

func computeSentinel() int { return 42 }

func Drive(objs @[]@[]char, out @[]char, target @[]char) @[]char {
	if sentinel != 42 { return buf.CopyStr("driver: package init did not run (sentinel != 42)") }
	var err @[]readonly char = link.Link(objs, "_start", link.EM_X86_64, cast(uint64, 0x400000), out)
	if len(err) != 0 { return buf.Concat("driver: link failed: ", err) }
	return buf.CopyStr("")
}
BN
if ! "$BNLD" -driver "$TMP/init_driver.bn" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target linux-x64 \
        -o "$TMP/exit42_init" "$TMP/exit42.o" > "$TMP/init.link.log" 2>&1; then
    echo "FAIL: bnld -driver (init-driver) could not link — package init likely did not run" >&2
    cat "$TMP/init.link.log" >&2
    exit 1
fi
check_elf "$TMP/exit42_init" "exit42_init"
echo "PASS: init-driver linked — the driver's top-level var initializer ran (LoadCallable dispatcher)"

# ----- run the programs if a linux-x86-64 runtime is available -----
CAN_RUN=0
RUN_KIND=""
case "$(uname -s)" in
    Linux) case "$(uname -m)" in x86_64 | amd64) CAN_RUN=1; RUN_KIND=native ;; esac ;;
    Darwin)
        if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1 \
                && docker pull --platform linux/amd64 alpine > /dev/null 2>&1; then
            CAN_RUN=1; RUN_KIND=docker
        fi ;;
esac

# run_expect <name> <want-code> <want-out>: run and check exit code + stdout.
run_expect() {
    _name="$1"; _wcode="$2"; _wout="$3"
    if [ "$CAN_RUN" != 1 ]; then
        echo "SKIP: $_name run (no linux-x86-64 runtime) — build+structure verified"
        return
    fi
    _out=""; _code=0
    if [ "$RUN_KIND" = native ]; then
        _out="$("$TMP/$_name")"; _code=$?
    else
        _out="$(docker run --rm --platform linux/amd64 -v "$TMP:/w" alpine "/w/$_name" 2>/dev/null)"
        _code=$?
        case "$_code" in 125 | 127) echo "SKIP: $_name run (docker infra)"; return ;; esac
    fi
    if [ "$_code" != "$_wcode" ]; then
        echo "FAIL: $_name exited $_code, want $_wcode" >&2; exit 1
    fi
    if [ "$_out" != "$_wout" ]; then
        echo "FAIL: $_name printed '$_out', want '$_wout'" >&2; exit 1
    fi
    echo "PASS: $_name ran (driver-linked) → exit $_code"
}

run_expect exit42 42 ""
run_expect hello 0 "hi"
run_expect exit42_init 42 ""

echo "ALL PASS: bnld -driver (interpreted driver → compiled linker) on Linux (ELF)"
