#!/bin/sh
# Usage: ./scripts/hygiene/lint.sh [--from-source]
#
# Runs cmd/bnlint over every package under pkg/ and every command under cmd/.
# Fails if any lint diagnostic is reported.
#
# --from-source: build bnlint from the CURRENT source tree instead of preferring
#   the pinned CHECK_TOOLS bundle.  Used by e2e/bnlint-self.sh to actually TEST
#   this tree's bnlint against the whole repo — the default, bundle-preferring
#   path exercises the pinned tool, not the tree.
#
# Exit code: 1 if any diagnostics found (or on bnlint error), 0 otherwise.

FROM_SOURCE=0
for arg in "$@"; do
    case "$arg" in
        --from-source) FROM_SOURCE=1 ;;
        *) echo "lint: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Packages to skip from linting.  bnlint is fetched from the CHECK_TOOLS_VERSION
# bundle, decoupled from BUILDER_VERSION so a newer check-tool feature does not
# require a build-ladder rung.
# A skipped target stays fully type-checked and compiled by every conformance
# mode — only bnlint's style rules pause — and bnlint typechecks dependency
# BODIES, so a skip must cover the whole transitive importer chain of the
# offending source.  (No skips today.)
LINT_SKIP=""

# Discover targets:
#   - every package directory under pkg/ that has a .bn file — RECURSIVELY, so
#     the compiler (which lives at pkg/binate/<pkg>, two levels deep) is covered;
#     a one-level `pkg/*/` glob misses it (pkg/ holds only pkg/binate/, which has
#     no direct .bn).
#   - every directory under cmd/
TARGETS=""
for d in $(find "$BINATE_DIR/pkg" -type d -not -path '*/testdata/*' 2>/dev/null | sort); do
    found=0
    for bn in "$d"/*.bn; do
        [ -f "$bn" ] && found=1 && break
    done
    [ "$found" -eq 1 ] || continue
    rel=$(echo "$d" | sed "s|^$BINATE_DIR/||")
    case " $LINT_SKIP " in
        *" $rel "*) continue ;;
    esac
    TARGETS="$TARGETS $rel"
done
for d in "$BINATE_DIR"/cmd/*/; do
    [ -d "$d" ] || continue
    rel="cmd/$(basename "$d")"
    case " $LINT_SKIP " in
        *" $rel "*) continue ;;
    esac
    TARGETS="$TARGETS $rel"
done

# Stdlib + runtime packages live under impls/ + ifaces/ addressed by package
# PATH, not under the pkg/ filesystem dir, so the pkg/* loop above misses them.
# Discover every such package from the `package "..."` clause of its files
# (impl .bn, interface .bni, or test .bn — interface-only packages and
# test-only packages both need to be found) and lint each by path (bnlint
# resolves the right impl variant via -L).
#
# PKG_PATH_AWK prints each file's package path: the first string after its
# `package` keyword, past comments and line breaks (bnfmt keeps a comment
# between the keyword and the path, and a line comment there puts the path on
# the next line).  Strings and comments before the keyword are skipped.
PKG_PATH_AWK='
FNR == 1 { blk = 0; kw = 0; done = 0 }
done { next }
{
    n = length($0); i = 1
    while (i <= n && !done) {
        c = substr($0, i, 1)
        if (blk) {
            if (substr($0, i, 2) == "*/") { blk = 0; i += 2 } else i++
            continue
        }
        if (substr($0, i, 2) == "//") break
        if (substr($0, i, 2) == "/*") { blk = 1; i += 2; continue }
        if (c == "\"") {
            j = i + 1
            while (j <= n && substr($0, j, 1) != "\"") {
                if (substr($0, j, 1) == "\\") j++
                j++
            }
            if (kw) { print substr($0, i + 1, j - i - 1); done = 1 }
            i = j + 1
            continue
        }
        if (kw && c !~ /[ \t\r]/) { done = 1; break }
        if (!kw && substr($0, i, 7) == "package" && \
                (i == 1 || substr($0, i - 1, 1) !~ /[A-Za-z0-9_]/) && \
                substr($0, i + 7, 1) !~ /[A-Za-z0-9_]/) { kw = 1; i += 7; continue }
        i++
    }
}'
for pp in $(find "$BINATE_DIR/impls" "$BINATE_DIR/ifaces" \( -name '*.bn' -o -name '*.bni' \) 2>/dev/null \
        | xargs awk "$PKG_PATH_AWK" 2>/dev/null | sort -u); do
    case " $LINT_SKIP " in
        *" $pp "*) continue ;;
    esac
    case " $TARGETS " in
        *" $pp "*) continue ;;
    esac
    TARGETS="$TARGETS $pp"
done

# Trim leading whitespace
TARGETS="$(echo "$TARGETS" | sed -e 's/^ *//')"

if [ -z "$TARGETS" ]; then
    echo "lint: no packages found"
    exit 1
fi

# build_bnlint_from_source sets BNLINT_BIN to a freshly-built bnlint from the
# current tree (removed on exit).
build_bnlint_from_source() {
    BNLINT_BIN="$(mktemp -t binate-lint.XXXXXX)"
    trap 'rm -f "$BNLINT_BIN"' EXIT
    "$SCRIPT_DIR/../build-bnlint.sh" -o "$BNLINT_BIN" >/dev/null || {
        echo "lint: failed to build bnlint" >&2
        exit 1
    }
}

if [ "$FROM_SOURCE" -eq 1 ]; then
    # e2e/bnlint-self.sh path: test THIS tree's bnlint, never the pinned bundle.
    build_bnlint_from_source
else
    # Prefer the bundled bnlint from CHECK_TOOLS_VERSION when available
    # (bnc-* mode) — saves the per-invocation cost of compiling bnlint
    # from source.  --check-tools resolves the CHECK-TOOLS release (which may
    # be a pre-release ahead of the BUILDER, carrying newer language support
    # like methods-on-generics), NOT the
    # BUILDER the tree builds with.  Falls back to building from current
    # source when the fetcher doesn't return a usable path (bundle lacks
    # bnlint, network failure, etc.).
    BNLINT_BIN="$("$BINATE_DIR/scripts/fetch-builder.sh" --check-tools --tool bnlint 2>/dev/null || true)"
    if [ -z "$BNLINT_BIN" ] || [ ! -x "$BNLINT_BIN" ]; then
        build_bnlint_from_source
    fi
fi

"$BNLINT_BIN" --tests -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" $TARGETS
rc=$?

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "=== lint failed (exit $rc) ==="
    exit 1
fi
