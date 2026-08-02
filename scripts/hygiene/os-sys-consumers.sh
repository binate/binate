#!/bin/sh
# Usage: ./scripts/hygiene/os-sys-consumers.sh
#
# Enforces that pkg/std/os/sys — the low-level libc-syscall layer (raw __c_call
# syscalls + errno classification, per explorations/design-syscall.md) — is
# imported ONLY by the os family: pkg/std/os and its subpackages (os itself,
# os/process, and any future pkg/std/os/*).  os/sys is the os abstraction's
# private syscall foundation; OS-specific code must not leak outside of os.
# Binate has no `internal/` visibility mechanism, so this repo-internal hygiene
# check is the enforcement.
#
# This is deliberately NOT a bnlint rule: bnlint runs on arbitrary user code,
# and an external consumer of a shipped bundle may have a legitimate reason to
# reach os/sys for OS-specific code.  We only forbid the leak inside OUR stdlib.
#
# Allowed importers: any file under */pkg/std/os/* (the os family).  Sanctioned
# exceptions (e.g. the VM's stdlib-injection glue, which imports every native
# stdlib package to register it) live in os-sys-consumers.whitelist — one
# <repo-relative-file> per line.
#
# Scanned trees: ifaces/ impls/ runtime/ pkg/ cmd/.  (conformance/ test programs
# are governed by conformance-imports.sh instead.)
#
# Exit code: 1 if any disallowed importer found, 0 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WHITELIST_FILE="$SCRIPT_DIR/os-sys-consumers.whitelist"
cd "$BINATE_DIR"

WL_CLEAN=$(mktemp -t hygiene-os-sys-wl.XXXXXX)
VIOL=$(mktemp -t hygiene-os-sys.XXXXXX)
trap 'rm -f "$WL_CLEAN" "$VIOL"' EXIT

# Pre-strip the whitelist's comments/blanks once.
if [ -f "$WHITELIST_FILE" ]; then
    grep -v '^[[:space:]]*#' "$WHITELIST_FILE" | grep -v '^[[:space:]]*$' > "$WL_CLEAN"
fi

# Every file that imports pkg/std/os/sys — the single-line `import "..."` form or
# a bare entry inside a grouped `import ( ... )` block (both are whole-line, so a
# "pkg/std/os/sys" string appearing mid-expression is not matched).
FILES=$(grep -rlE '^[[:space:]]*(import[[:space:]]+)?"pkg/std/os/sys"[[:space:]]*$' \
    --include='*.bn' --include='*.bni' ifaces impls runtime pkg cmd 2>/dev/null | sort -u)

for f in $FILES; do
    # The os family (pkg/std/os and its subpackages) may import os/sys freely.
    case "$f" in
        */pkg/std/os/*) continue ;;
    esac
    # Sanctioned exception?
    if [ -s "$WL_CLEAN" ] && grep -Fxq "$f" "$WL_CLEAN"; then
        continue
    fi
    echo "$f: imports \"pkg/std/os/sys\" from outside the os family (pkg/std/os*)" >> "$VIOL"
done

if [ -s "$VIOL" ]; then
    sort -u "$VIOL"
    n=$(sort -u "$VIOL" | wc -l | tr -d ' ')
    echo ""
    echo "=== $n os/sys boundary violation(s) ==="
    echo "pkg/std/os/sys is the os abstraction's private syscall foundation — only"
    echo "pkg/std/os and its subpackages (os, os/process, ...) may import it."
    echo "Reach OS services through the higher-level pkg/std/os / pkg/std/os/process APIs."
    echo "Sanctioned exceptions: $WHITELIST_FILE"
    exit 1
fi
