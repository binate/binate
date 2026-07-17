#!/bin/sh
# Usage: ./scripts/hygiene/conformance-imports.sh
#
# Verifies that conformance tests only import from a small whitelist of
# real packages, or from a test-local fixture inside the same test
# directory. Always-allowed real packages:
#
#   pkg/bootstrap   — system calls (Write, Exit, Args, file I/O)
#   pkg/builtins/*  — tier-0 always-available runtime essentials (rt,
#                     lang, testing, reflect, ...); stable and bundled
#                     with the toolchain, so any conformance test may use
#                     them without a per-file exemption.
#
# A file's "test directory" is the immediate child of conformance/ that
# contains it. Single-file tests (conformance/NNN_name.bn) have no test
# directory and may only use whitelisted imports. Multi-package tests
# (conformance/NNN_name/) may additionally import any "pkg/X" whose
# fixture exists at NNN_name/pkg/X/, NNN_name/pkg/X.bn, or
# NNN_name/pkg/X.bni.
#
# Per-import exemptions live in conformance-imports.whitelist
# (one `<conformance-relative-path>:<import-path>` per line). Use
# sparingly — e.g. for a negative test that deliberately imports a
# non-existent package.
#
# See section 9 of explorations/code-hygiene-check.md for the rationale.
#
# Exit code: 1 if any violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFORMANCE_DIR="$BINATE_DIR/conformance"
WHITELIST_FILE="$SCRIPT_DIR/conformance-imports.whitelist"

ALLOWED_REAL="pkg/bootstrap"

LIST=$(mktemp -t hygiene-conformance-imports-list.XXXXXX)
VIOLATIONS=$(mktemp -t hygiene-conformance-imports-out.XXXXXX)
IMPORTS=$(mktemp -t hygiene-conformance-imports-imp.XXXXXX)
WL_CLEAN=$(mktemp -t hygiene-conformance-imports-wl.XXXXXX)
trap 'rm -f "$LIST" "$VIOLATIONS" "$IMPORTS" "$WL_CLEAN"' EXIT

find "$CONFORMANCE_DIR" -type f \( -name '*.bn' -o -name '*.bni' \) \
    | sort > "$LIST"

# Pre-strip the exemption whitelist's comments/blanks ONCE (was re-done via two
# greps on every non-allowed import).  Conformance paths never contain a tab or
# space, so the tab-delimited pipeline below is unambiguous.
if [ -f "$WHITELIST_FILE" ]; then
    grep -v '^[[:space:]]*#' "$WHITELIST_FILE" | grep -v '^[[:space:]]*$' > "$WL_CLEAN"
fi

# Extract every "pkg/..." import from EVERY file in ONE awk pass (was one awk
# fork PER file — ~3,500 forks / ~10s).  Emit "<path>\t<import>".  FNR==1 resets
# the group-state machine per file (an unterminated `import (` must not bleed
# into the next file).  Handles the single-line `import "pkg/X"` and grouped
# `import ( "pkg/X" ... )` forms, tolerating blanks/comments inside the group.
if [ -s "$LIST" ]; then
    xargs awk '
        FNR == 1 { in_group = 0 }
        /^import \(/ { in_group = 1; next }
        in_group && /^\)/ { in_group = 0; next }
        in_group {
            if (match($0, /"pkg\/[^"]+"/)) {
                print FILENAME "\t" substr($0, RSTART + 1, RLENGTH - 2)
            }
            next
        }
        /^import "pkg\// {
            if (match($0, /"pkg\/[^"]+"/)) {
                print FILENAME "\t" substr($0, RSTART + 1, RLENGTH - 2)
            }
        }
    ' < "$LIST" > "$IMPORTS"
fi

TAB=$(printf '\t')
while IFS="$TAB" read -r f imp; do
    [ -z "$imp" ] && continue
    rel_conf="${f#$CONFORMANCE_DIR/}"
    rel_repo="${f#$BINATE_DIR/}"

    # Tier-0 builtins (pkg/builtins/*) are always-available runtime
    # essentials — allowed for every conformance test.
    case "$imp" in
        pkg/builtins/*) continue ;;
    esac

    # Stdlib conformance subtree (conformance/stdlib/*) exercises the stdlib
    # end-to-end, so it may import pkg/std/*.  Scoped to the subtree by the
    # rel_conf prefix — the MAIN language conformance set stays core-only.
    case "$rel_conf" in
        stdlib/*)
            case "$imp" in
                pkg/std/*) continue ;;
            esac
            ;;
    esac

    # Whitelisted real package?
    skip=0
    for w in $ALLOWED_REAL; do
        [ "$imp" = "$w" ] && { skip=1; break; }
    done
    [ "$skip" = 1 ] && continue

    # Test-local fixture?  A file's test directory is the nearest ancestor (up
    # to conformance/) holding a main.bn.  Computed lazily here — only reached
    # for the rare non-whitelisted import — via param-expansion (no `dirname`
    # fork per file).
    test_root=""
    _d="${f%/*}"
    while [ "$_d" != "$CONFORMANCE_DIR" ] && [ "$_d" != "/" ] && [ -n "$_d" ]; do
        if [ -f "$_d/main.bn" ]; then test_root="$_d"; break; fi
        _d="${_d%/*}"
    done
    if [ -n "$test_root" ]; then
        local_path="$test_root/$imp"
        if [ -d "$local_path" ] || \
           [ -f "$local_path.bn" ] || \
           [ -f "$local_path.bni" ]; then
            continue
        fi
    fi

    # Per-file exemption? (single grep against the pre-stripped whitelist)
    if [ -s "$WL_CLEAN" ] && grep -Fxq "$rel_conf:$imp" "$WL_CLEAN"; then
        continue
    fi

    echo "$rel_repo: disallowed import \"$imp\"" >> "$VIOLATIONS"
done < "$IMPORTS"

if [ -s "$VIOLATIONS" ]; then
    cat "$VIOLATIONS"
    n=$(wc -l < "$VIOLATIONS" | tr -d ' ')
    echo ""
    echo "=== $n conformance import violation(s) ==="
    echo "Allowed: $ALLOWED_REAL, pkg/builtins/*, plus any test-local fixture."
    echo "See $WHITELIST_FILE for per-file exemptions."
    exit 1
fi
