#!/bin/sh
# Usage: ./scripts/hygiene/stdlib-error-rooting.sh
#
# Enforces that STANDARD-LIBRARY code roots every error it returns in one of the
# errors.bni base failures (InvalidArgument, ConditionsUnmet, BadData, NotFound,
# OutOfRange, ...), so a caller can classify any stdlib failure with errors.Is.
# The check flags the vector that silently defeats this: a call to
# errors.New(...), which builds an UNCLASSIFIED root — its Unwrap() is empty, so
# errors.Is matches no base.  A stdlib error must instead root in a base:
# errors.Rooted(base, msg), errors.Wrap(cause, msg), or return a base directly.
#
# errors.New is reserved for ONE job: defining the base singletons themselves
# (impls/stdlib/pkg/std/errors/errors.bn).  So the errors package is exempt;
# everywhere else in the stdlib, errors.New(...) is a violation.
#
# Scope: pkg/std and pkg/stdx only (wherever they live under impls/ and ifaces/),
# EXCLUDING *_test.bn.  Deliberately NOT scanned (may use errors.New freely):
# tests, user code (conformance/, examples/), tool code (cmd/), pkg/builtins
# (which cannot depend on pkg/std/errors anyway), and the compiler's own private
# packages (pkg/binate/*).  This discipline is specifically about errors the
# SHIPPED STANDARD LIBRARY hands back to a caller.
#
# NOTE (what this static check does NOT catch): a custom error type whose
# Unwrap() returns an empty @errors.Error is the same defect (roots in no base)
# but is not statically detectable here — that relies on review plus the
# package's own errors.Is tests.  (That exact bug was fixed in strconv's numError
# — see explorations/claude-todo-done.md.)
#
# Sanctioned exceptions live in stdlib-error-rooting.whitelist, one
# <repo-relative-file> per line.
#
# Exit code: 1 if any disallowed errors.New use found, 0 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WHITELIST_FILE="$SCRIPT_DIR/stdlib-error-rooting.whitelist"
cd "$BINATE_DIR"

WL_CLEAN=$(mktemp -t hygiene-stdlib-err-wl.XXXXXX)
VIOL=$(mktemp -t hygiene-stdlib-err.XXXXXX)
trap 'rm -f "$WL_CLEAN" "$VIOL"' EXIT

# Pre-strip the whitelist's comments/blanks once.
if [ -f "$WHITELIST_FILE" ]; then
    grep -v '^[[:space:]]*#' "$WHITELIST_FILE" | grep -v '^[[:space:]]*$' > "$WL_CLEAN"
fi

# Candidate files: .bn/.bni mentioning errors.New(, scoped below to pkg/std +
# pkg/stdx, minus tests and the errors package itself (which DEFINES the bases).
FILES=$(grep -rlE 'errors\.New\(' --include='*.bn' --include='*.bni' \
    impls ifaces 2>/dev/null | sort -u)

for f in $FILES; do
    # Scope: pkg/std and pkg/stdx only; everything else is out of scope.
    case "$f" in
        */pkg/std/*|*/pkg/stdx/*) ;;
        *) continue ;;
    esac
    case "$f" in
        *_test.bn) continue ;;              # tests may do anything
        */pkg/std/errors/*) continue ;;     # the errors package defines the bases
    esac
    if [ -s "$WL_CLEAN" ] && grep -Fxq "$f" "$WL_CLEAN"; then
        continue
    fi
    # Report each real call site.  Strip an inline // comment before testing, so a
    # docstring merely REFERENCING errors.New( is not flagged; report the original
    # line for context.
    awk '{ code = $0; sub(/\/\/.*/, "", code);
           if (code ~ /errors\.New\(/) printf "%s:%d: %s\n", FILENAME, NR, $0 }' \
        "$f" >> "$VIOL"
done

if [ -s "$VIOL" ]; then
    sort -u "$VIOL"
    n=$(sort -u "$VIOL" | wc -l | tr -d ' ')
    echo ""
    echo "=== $n stdlib unclassified-error violation(s) ==="
    echo "Standard-library code must root every error in an errors.bni base so a"
    echo "caller can classify it with errors.Is.  errors.New(...) builds an"
    echo "UNCLASSIFIED root (empty Unwrap) and is reserved for defining the base"
    echo "singletons in pkg/std/errors.  Use errors.Rooted(base, msg),"
    echo "errors.Wrap(cause, msg), or return a base directly."
    echo "Sanctioned exceptions: $WHITELIST_FILE"
    exit 1
fi
