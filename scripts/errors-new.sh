#!/bin/sh
# errors-new — enforce that stdlib code roots its errors in the failure
# hierarchy instead of creating bare, unrooted errors with errors.New.
#
# errors.New(msg) is Rooted(<empty>, msg): an error with NO parent, so it sits
# OUTSIDE the hierarchy and errors.Is can't classify it. The ONLY legitimate
# New calls are the base ROOT singletons defined inside pkg/std/errors itself
# (InvalidArgument, Unsupported, ConditionsUnmet, PermissionDenied, Retryable,
# Unknown) — and those use the UNQUALIFIED `New(` (same package), so the
# qualified `errors.New(` this checks for never matches them. Every other
# stdlib error must root in a base via errors.Rooted(<base>, msg) or
# errors.Wrap(<cause>, msg).
#
# Scope: production stdlib implementation files (impls/stdlib/**/*.bn, minus
# *_test.bn). Tests, conformance programs, and the compiler tree are out of
# scope — they may construct throwaway errors with errors.New freely.
#
# Heuristic: it matches the canonical qualified call `errors.New(`. An aliased
# import of the errors package (e.g. `import "pkg/std/errors" as e` → e.New)
# would evade it, but that is not the codebase convention.
#
# NOT wired into scripts/hygiene/run.sh yet. To activate as a hygiene check,
# `git mv` this into scripts/hygiene/ (run.sh auto-discovers *.sh there); the
# root detection below works from either location.
#
# Exit code: 1 if any violation found, 0 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Locate the binate repo root by walking up until impls/stdlib appears, so the
# script works whether it lives in scripts/ or scripts/hygiene/.
BINATE_DIR="$SCRIPT_DIR"
while [ "$BINATE_DIR" != "/" ] && [ ! -d "$BINATE_DIR/impls/stdlib" ]; do
    BINATE_DIR="$(dirname "$BINATE_DIR")"
done
if [ ! -d "$BINATE_DIR/impls/stdlib" ]; then
    echo "errors-new: cannot locate impls/stdlib from $SCRIPT_DIR" >&2
    exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

find "$BINATE_DIR/impls/stdlib" -name '*.bn' ! -name '*_test.bn' 2>/dev/null | sort | while IFS= read -r f; do
    rel="${f#"$BINATE_DIR"/}"
    # Strip line comments (so a `// errors.New(...)` doc example doesn't trip
    # the check), then flag any call to errors.New.
    sed 's://.*::' "$f" | grep -n 'errors\.New(' | while IFS= read -r hit; do
        printf '%s:%s\n' "$rel" "$hit" >> "$tmp"
    done
done

if [ -s "$tmp" ]; then
    echo "errors.New creates an UNROOTED error (outside the failure hierarchy)."
    echo "Root it via errors.Rooted(<base>, msg) or errors.Wrap(<cause>, msg)."
    echo "Offending calls:"
    sed 's/^/  /' "$tmp"
    exit 1
fi
exit 0
