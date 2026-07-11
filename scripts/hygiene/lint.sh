#!/bin/sh
# Usage: ./scripts/hygiene/lint.sh
#
# Runs cmd/bnlint over every package under pkg/ and every command under cmd/.
# Fails if any lint diagnostic is reported.
#
# Exit code: 1 if any diagnostics found (or on bnlint error), 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/../bootstrap" && pwd)"

# Packages to skip from linting.  bnlint is fetched from the CHECK_TOOLS_VERSION
# bundle (bnc-0.0.11pre2), decoupled from BUILDER_VERSION so a newer check-tool
# feature does not require a build-ladder rung (see
# explorations/plan-check-tools-version.md).  A skipped target stays fully
# type-checked and compiled by every conformance mode — only bnlint's style rules
# pause — and bnlint typechecks dependency BODIES, so a version-lag skip must
# cover the whole transitive importer chain of the offending source.
#
# LINT_SKIP is EMPTY: every package is linted.  The last skips cleared at the
# bnc-0.0.11pre2 CHECK_TOOLS bump + the --tests wiring:
#   - the container-adoption methods-on-generics cone (pkg/stdx/containers/
#     {vec,hashmap,set} + importers pkg/binate/format + cmd/bnfmt) — pre2's bnlint
#     parses methods-on-generic-types AND carries the cross-package generic
#     name-collision fix the COMBINED sweep needs;
#   - pkg/binate/interp — its `undefined: __Package` version-lag cleared at the
#     bump, and its lone `[unused-func] shortName` was a false positive (used by
#     imports_test.bn, which `--tests` now counts);
#   - pkg/binate/asm/{arm32,elf,macho,parse,x64} — the 17 [managed-to-raw-assign]
#     safe-borrow over-flags (raw views of fields of a live @asm.Section /
#     @Assembler / buffer that outlive the synchronous read) now carry per-site
#     `// bnlint:allow managed-to-raw-assign` directives (claude-todo asm
#     INCREMENT 2; the 1 real UAF was fixed separately in 8a883450).
#
# One skip remains (CHECK-TOOLS-lag, NOT BUILDER-lag): the injectable-key-policy +
# fn-injected-container packages pkg/stdx/{hash,cmp} and pkg/stdx/containers/{table,
# mapfn,setfn}.  They lean on the generic-instantiation-as-constraint-arg support and
# the genericImplSatisfies guard (checker fixes 2f8969e8 / 6647c49f) that postdate
# bnc-0.0.11pre2, so pre2's bnlint typecheck aborts with false "type argument H does
# not satisfy constraint Hasher[T]" / "K does not satisfy Hashable" at their blanket
# impls.  A current-source bnlint accepts them.  Drop at the next CHECK_TOOLS bump past
# 6647c49f.
LINT_SKIP="pkg/stdx/hash pkg/stdx/cmp pkg/stdx/containers/table pkg/stdx/containers/mapfn pkg/stdx/containers/setfn"

# Discover targets:
#   - every package directory under pkg/ that has a .bn file — RECURSIVELY, so
#     the compiler (which lives at pkg/binate/<pkg>, two levels deep) is covered;
#     a one-level `pkg/*/` glob misses it (pkg/ holds only pkg/binate/, which has
#     no direct .bn).  Excludes pkg/bootstrap (only a .bni interface, no dir).
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
for pp in $(find "$BINATE_DIR/impls" "$BINATE_DIR/ifaces" \( -name '*.bn' -o -name '*.bni' \) 2>/dev/null \
        | xargs grep -hE '^package "' 2>/dev/null \
        | sed -E 's/^package "([^"]+)".*/\1/' | sort -u); do
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

# Prefer the bundled bnlint from CHECK_TOOLS_VERSION when available
# (bnc-* mode) — saves the per-invocation cost of compiling bnlint
# from source.  --check-tools resolves the CHECK-TOOLS release (which may
# be a pre-release ahead of the BUILDER, carrying newer language support
# like methods-on-generics — see plan-check-tools-version.md), NOT the
# BUILDER the tree builds with.  Falls back to building from current
# source under bootstrap-* (no toolchain bundle exists) or when the
# fetcher doesn't return a usable path.
BNLINT_BIN="$("$BINATE_DIR/scripts/fetch-builder.sh" --check-tools --tool bnlint 2>/dev/null || true)"
if [ -z "$BNLINT_BIN" ] || [ ! -x "$BNLINT_BIN" ]; then
    BNLINT_BIN="$(mktemp -t binate-lint.XXXXXX)"
    trap 'rm -f "$BNLINT_BIN"' EXIT
    "$SCRIPT_DIR/../build-bnlint.sh" -o "$BNLINT_BIN" >/dev/null || {
        echo "lint: failed to build bnlint" >&2
        exit 1
    }
fi

"$BNLINT_BIN" --tests -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" $TARGETS
rc=$?

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "=== lint failed (exit $rc) ==="
    exit 1
fi
