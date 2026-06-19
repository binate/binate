#!/bin/sh
# Usage: ./scripts/hygiene/spec-coverage.sh
#
# Spec-conformance citation integrity. Runs scripts/spec-coverage over the
# conformance/spec/ tests and fails on either:
#   - DANGLING: a .rules sidecar cites a rule-ID the spec does not declare
#               (a typo or a citation left dangling after a spec rename), or
#   - UNTAGGED: a spec test with no .rules sidecar.
#
# Coverage % and the GAP list (denominator rules with no test yet) are PROGRESS,
# not pass/fail, so they do not gate here — driving the gap list down is the
# work of Phase B (explorations/plan-spec-tests.md), not a hygiene violation.
#
# The coverage tool reads the vendored scripts/spec-coverage/rule-ids.txt, so
# this is self-contained: no toolchain build and no docs checkout required.
#
# Exit code: 1 if any DANGLING or UNTAGGED, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COV="$BINATE_DIR/scripts/spec-coverage/run.sh"

if [ ! -x "$COV" ]; then
    echo "spec-coverage tool not found/executable: $COV"
    exit 1
fi

out=$("$COV" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then
    # The tool exits non-zero exactly on DANGLING or UNTAGGED. Surface those
    # sections (DANGLING onward); fall back to the full output for any other
    # error (e.g. a missing inventory).
    details=$(printf '%s\n' "$out" | sed -n '/^DANGLING/,$p')
    if [ -n "$details" ]; then
        printf '%s\n' "$details"
    else
        printf '%s\n' "$out"
    fi
    exit 1
fi
exit 0
