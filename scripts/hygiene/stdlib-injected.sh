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
# A package is injected via one of two mechanisms in cmd/bni/externs.bn:
#   1. native-only — listed in nativeOnlyStdPkgs() (lowered-skipped + fully
#      injected: functions, globals, impl vtables), for the pure packages; or
#   2. lowered + injected — an explicit RegisterPackageFunctions(vmInst,
#      <pkg>._Package()) call, for os (whose __c_call funcs need native dispatch
#      even while its pure funcs run as bytecode).
#
# There is deliberately NO exemption list: every pkg/std package must be
# injected. If a future package genuinely should NOT be, that is a deliberate
# decision to surface here (and update this check), not to paper over silently.
#
# Packages are enumerated from the iface tree (one .bni per package — the
# canonical importable list). The injection set is read from externs.bn so the
# check stays in sync with that one source of truth (assumes one nativeOnlyStdPkg
# entry per line and the `<alias>._Package()` call on one line — the code's form).
#
# Exit code: 1 if any pkg/std package is not injected, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXTERNS="$BINATE_DIR/cmd/bni/externs.bn"
IFACE_STD="$BINATE_DIR/ifaces/stdlib/pkg/std"

missing=0

for bni in $(find "$IFACE_STD" -name '*.bni' | sort); do
    # Package path: strip the ifaces/stdlib/ prefix and the .bni suffix, e.g.
    # ifaces/stdlib/pkg/std/math/big.bni -> pkg/std/math/big.
    rel="${bni#"$BINATE_DIR"/ifaces/stdlib/}"
    pkg="${rel%.bni}"
    base="${pkg##*/}"   # the import alias, e.g. "big" for pkg/std/math/big

    # 1. native-only: a nativeOnlyStdPkg{ path: "<pkg>" } table entry.
    if grep -E "nativeOnlyStdPkg\{.*\"$pkg\"" "$EXTERNS" >/dev/null 2>&1; then
        continue
    fi
    # 2. explicit injection: a <alias>._Package() call (e.g. os._Package()).
    # The table's descriptor field uses the bare thunk `<alias>._Package` (no
    # parens), so matching the parenthesized call distinguishes the two.
    if grep -F "$base._Package()" "$EXTERNS" >/dev/null 2>&1; then
        continue
    fi

    echo "NOT INJECTED: $pkg"
    missing=$((missing + 1))
done

if [ "$missing" -gt 0 ]; then
    echo ""
    echo "=== $missing pkg/std package(s) not injected into the VM ==="
    echo "Inject in cmd/bni/externs.bn: add to nativeOnlyStdPkgs() (pure packages)"
    echo "or an explicit RegisterPackageFunctions(vmInst, <pkg>._Package()) call."
    exit 1
fi
