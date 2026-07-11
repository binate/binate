#!/bin/sh
# Usage: ./scripts/hygiene/pkg-tiers.sh
#
# Enforces the tier DEPENDENCY rules from explorations/pkg-layout-spec.md
# ("Tiers"): a package may import only packages at its own tier or LOWER.
# Tiers, low -> high:
#
#   0/0b  pkg/builtins/*  (+ pkg/bootstrap, + runtime/<target>/pkg/* shipped
#         runtime components) — always bundled with the toolchain
#   1     pkg/std/*   — standards library (bundled by default)
#   1x    pkg/stdx/*  — standards-track, no inter-version compat (bundled by default)
#   2     pkg/<org>/* (e.g. pkg/binate/*) — package-manager-pulled
#   3     app-specific (cmd/*, package "main") — not bundled
#
# Importing a strictly-higher tier is a violation.  A bundled package (0/0b/1/
# 1x) that reaches a not-bundled tier (2/3) silently breaks the bundle: the
# dependency's source isn't shipped, so a consumer compiling against the bundle
# gets `package "<dep>" not found`.  This is the runtime enforcement of the
# spec's "Transitive constraint" + tier table.  Nothing else catches it — it
# only manifests when a consumer compiles the offending package from a real
# bundle (the 2026-06-10 pkg/builtins/lang -> pkg/binate/buf bug, binate
# 84818a77, present + undetected since bnc-0.0.7).
#
# Refinement (std -> stdx): tier 1 (std) may depend on tier 1x (stdx) from its
# .bn IMPL files (internal) but NOT from its .bni INTERFACE files — a .bni
# importing stdx leaks a no-inter-version-compat (1x) type into std's
# strict-compat surface.  So .bni and .bn are scanned with the same rule except
# this one edge.
#
# *_test.bn files are EXEMPT (tests aren't bundled — e.g. lang_test.bn
# legitimately imports pkg/binate/buf).  Sanctioned exceptions live in
# pkg-tiers.whitelist (one `<repo-relative-file>:<import-path>` per line).
#
# Scanned trees: ifaces/ impls/ runtime/ pkg/ cmd/.  (conformance/ test
# programs are governed by conformance-imports.sh instead.)
#
# Exit code: 1 if any violations found, 0 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WHITELIST_FILE="$SCRIPT_DIR/pkg-tiers.whitelist"
cd "$BINATE_DIR"

# Runtime-shipped packages (runtime/<target>/pkg/<name>...) bundle with the
# toolchain like tier 0 — an import of one is never a violation.  Collect the
# bare `pkg/<name>` prefixes (e.g. pkg/semihost).
RUNTIME_PKGS=$(find runtime -type f \( -name '*.bn' -o -name '*.bni' \) 2>/dev/null \
    | sed -E 's#^runtime/[^/]+/##; s#^(pkg/[^/]+)/.*#\1#; s#\.bni?$##' | sort -u)

# import_level <import-path> -> tier level 0..3 of the imported package.
import_level() {
    case "$1" in
        pkg/builtins/*)                echo 0; return ;;
        pkg/bootstrap|pkg/bootstrap/*) echo 0; return ;;
        pkg/std/*)                     echo 1; return ;;
        pkg/stdx/*)                    echo 2; return ;;
    esac
    for r in $RUNTIME_PKGS; do
        [ "$1" = "$r" ] && { echo 0; return; }
        case "$1" in "$r"/*) echo 0; return ;; esac
    done
    case "$1" in
        pkg/*) echo 3; return ;;   # tier 2 (pkg/<org>/*)
    esac
    echo 4                          # non-pkg import (unexpected)
}

# file_level <repo-relative-file> -> tier level 0..4 of the OWNING package.
file_level() {
    case "$1" in
        runtime/*)         echo 0; return ;;   # runtime-shipped
        */pkg/builtins/*)  echo 0; return ;;   # tier 0/0b
        */pkg/bootstrap*)  echo 0; return ;;
        */pkg/std/*)       echo 1; return ;;
        */pkg/stdx/*)      echo 2; return ;;   # tier 1x
        pkg/*)             echo 3; return ;;   # tier 2 collocated (top-level pkg/)
        cmd/*)             echo 4; return ;;   # tier 3 app
    esac
    echo 4                                      # other -> app-level (permissive)
}

# lvl_name <level> -> the human tier label.
lvl_name() {
    case "$1" in 0) echo "0/0b" ;; 1) echo "1" ;; 2) echo "1x" ;; 3) echo "2" ;; *) echo "3" ;; esac
}

is_exempt() {  # <rel-file> <import>
    [ -f "$WHITELIST_FILE" ] || return 1
    grep -v '^[[:space:]]*#' "$WHITELIST_FILE" | grep -v '^[[:space:]]*$' \
        | grep -Fxq "$1:$2"
}

VIOL=$(mktemp -t hygiene-pkg-tiers.XXXXXX)
trap 'rm -f "$VIOL"' EXIT

find ifaces impls runtime pkg cmd -type f \( -name '*.bn' -o -name '*.bni' \) 2>/dev/null \
    | grep -v '_test\.bn$' | sort | while IFS= read -r f; do
    ilevel=$(file_level "$f")
    # Extract every "pkg/..." import (single-line, optionally aliased, and the
    # grouped `import ( ... )` form).
    imports=$(awk '
        /^import[ \t]*\(/ { in_group = 1; next }
        in_group && /^\)/  { in_group = 0; next }
        in_group { if (match($0, /"pkg\/[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2); next }
        /^import[ \t]/ { if (match($0, /"pkg\/[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2) }
    ' "$f")
    [ -z "$imports" ] && continue
    printf '%s\n' "$imports" | while IFS= read -r imp; do
        [ -z "$imp" ] && continue
        dlevel=$(import_level "$imp")
        [ "$dlevel" -le "$ilevel" ] && continue    # same tier or lower -> ok
        # The only sanctioned higher-tier edge is std (.bn) -> stdx.
        if [ "$ilevel" -eq 1 ] && [ "$dlevel" -eq 2 ]; then
            case "$f" in *.bn) continue ;; esac    # std IMPL may use stdx
            # a .bni std -> stdx falls through to a violation (refinement).
        fi
        is_exempt "$f" "$imp" && continue
        echo "$f: tier-$(lvl_name "$ilevel") package imports higher-tier \"$imp\" (tier-$(lvl_name "$dlevel"))" >> "$VIOL"
    done
done

if [ -s "$VIOL" ]; then
    sort -u "$VIOL"
    n=$(sort -u "$VIOL" | wc -l | tr -d ' ')
    echo ""
    echo "=== $n tier dependency violation(s) ==="
    echo "A package may import only its own tier or lower (explorations/pkg-layout-spec.md)."
    echo "std->stdx is allowed from .bn impls only; *_test.bn is exempt."
    echo "Sanctioned exceptions: $WHITELIST_FILE"
    exit 1
fi
