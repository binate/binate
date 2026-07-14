#!/bin/sh
# scripts/e2e-run.sh <script-name> [args...] — run one e2e/<name>.sh honoring
# per-OS skip/xfail markers, so known-expected failures (host-specific infra,
# features pending a later phase) don't red the e2e gate.  Mirrors conformance's
# `.xfail.<mode>` markers.  Lives under scripts/ (not e2e/) so it is NOT swept
# into the CI matrix's `ls e2e/*.sh` discovery.
#
# Markers live next to the script, in e2e/:
#   <name>.skip[.<os>]   — do NOT run; report SKIP, exit 0.
#   <name>.xfail[.<os>]  — run, but a NON-zero exit is EXPECTED (XFAIL, exit 0);
#                          a ZERO exit is XPASS (the marker is stale) -> exit 1,
#                          so a fixed script gets noticed and its marker removed.
# <os> is `linux` or `darwin` (from uname -s); the unsuffixed form applies on
# every OS.  A marker file's contents, if any, are printed as the reason.
#
# With no marker, the script's own exit code passes through unchanged.

set -u

name="${1:?usage: e2e-run.sh <script-name> [args...]}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
E2E_DIR="$BINATE_DIR/e2e"
script="$E2E_DIR/$name.sh"

if [ ! -f "$script" ]; then
    echo "e2e-run: no such e2e script: $script" >&2
    exit 2
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
    linux*)  os=linux ;;
    darwin*) os=darwin ;;
esac

# marker <kind>: echo the path of a matching `<name>.<kind>.<os>` or
# `<name>.<kind>` marker (OS-specific preferred), or return non-zero if none.
marker() {
    for m in "$E2E_DIR/$name.$1.$os" "$E2E_DIR/$name.$1"; do
        if [ -f "$m" ]; then
            echo "$m"
            return 0
        fi
    done
    return 1
}

if skip_m="$(marker skip)"; then
    reason="$(cat "$skip_m" 2>/dev/null)"
    echo "SKIP: $name ($os)${reason:+ — $reason}"
    exit 0
fi

"$script" "$@"
rc=$?

if xfail_m="$(marker xfail)"; then
    reason="$(cat "$xfail_m" 2>/dev/null)"
    if [ "$rc" -eq 0 ]; then
        echo "XPASS: $name ($os) unexpectedly PASSED — remove the stale marker $xfail_m" >&2
        exit 1
    fi
    echo "XFAIL: $name ($os) failed as expected (rc=$rc)${reason:+ — $reason}"
    exit 0
fi

exit "$rc"
