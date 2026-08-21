#!/bin/sh
# Usage: ./scripts/hygiene/stdlib-injected.sh
#
# Checks that EVERY pkg/std/** package is injected into the bytecode VM by
# cmd/bni — i.e. backed by the single compiled (native) instance, never left as
# a separately-lowered bytecode copy. A lowered-only pkg/std package would split
# into two instances across the compiled<->bytecode boundary, re-opening the
# cross-mode-identity hazards (errors.Is / io.IsEOF sentinel identity, interface
# dispatch over a native-only type's vtable) that the inject-all effort closed.
#
# A package is injected by listing it in stdPkgs() in pkg/binate/interp/externs.bn — that
# ONE table drives both the lowering skip (isNativeOnlyInVM) and the injection
# (injectStdlibExterns), so the package runs as its single compiled instance
# (functions + globals + impl vtables), never as a separately-lowered bytecode
# copy. EVERY pkg/std package belongs there, INCLUDING __c_call packages
# (pkg/std/os): a __c_call package is injected wholesale too, so its methods run
# as the linked native impl. (Lowering it instead lets an INDIRECT __c_call
# wrapper like os.cLseek become an un-injectable bytecode call — the exact hazard
# a prior carve-out for os let through. No carve-outs: one mechanism, one rule.)
#
# There is ONE deliberate exemption: pkg/std/debug. It introspects the VM's OWN
# bytecode call stack (its _stack_frames intrinsic walks vm.Stack frame headers
# for FRAME_VM frames), so it MUST be lowered to bytecode and run inside the VM —
# injecting the single native instance would substitute an FP-chain walk of the
# host stack, which is meaningless in the interpreter. This is surfaced here as a
# named skip, not papered over. Every OTHER pkg/std package must still be
# injected; a future exemption is likewise a deliberate decision to add here.
#
# Packages are enumerated from the iface tree (one .bni per package — the
# canonical importable list). The injection set is read from externs.bn so the
# check stays in sync with that one source of truth (assumes one stdPkg entry
# per line — the code's form).
#
# Exit code: 1 if any pkg/std package is not injected, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXTERNS="$BINATE_DIR/pkg/binate/interp/externs.bn"
IFACE_STD="$BINATE_DIR/ifaces/stdlib/pkg/std"

missing=0

for bni in $(find "$IFACE_STD" -name '*.bni' | sort); do
    # Package path: strip the ifaces/stdlib/ prefix and the .bni suffix, e.g.
    # ifaces/stdlib/pkg/std/math/big.bni -> pkg/std/math/big.
    rel="${bni#"$BINATE_DIR"/ifaces/stdlib/}"
    pkg="${rel%.bni}"

    # pkg/std/debug is the one deliberate carve-out (see the header comment): it
    # walks the VM's own bytecode stack, so it must be lowered, never injected.
    if [ "$pkg" = "pkg/std/debug" ]; then
        continue
    fi

    # Injected iff it has a stdPkg{ path: "<pkg>" } entry in stdPkgs() (which
    # drives both the lowering skip and the injection — see externs.bn).
    if grep -E "stdPkg\{.*\"$pkg\"" "$EXTERNS" >/dev/null 2>&1; then
        continue
    fi

    echo "NOT INJECTED: $pkg"
    missing=$((missing + 1))
done

if [ "$missing" -gt 0 ]; then
    echo ""
    echo "=== $missing pkg/std package(s) not injected into the VM ==="
    echo "Inject it: add a stdPkg{ path: \"<pkg>\", descriptor: <alias>.__Package }"
    echo "entry to stdPkgs() in pkg/binate/interp/externs.bn."
    exit 1
fi
