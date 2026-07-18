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
# bundle (bnc-0.0.12-pre3), decoupled from BUILDER_VERSION so a newer check-tool
# feature does not require a build-ladder rung (see
# explorations/plan-check-tools-version.md).  A skipped target stays fully
# type-checked and compiled by every conformance mode — only bnlint's style rules
# pause — and bnlint typechecks dependency BODIES, so a skip must cover the whole
# transitive importer chain of the offending source.  (No skips today.)
#
# Previously skipped, now linted (kept as changelog — do NOT re-add without cause):
#   - pkg/stdx/fmt — pre2's bnlint rejected its scalar value-recovery (`case int:`
#     etc.) with "value-recovery type assertion not yet supported"; value-recovery
#     landed at `89b41531`, so it cleared at the bnc-0.0.12-pre3 CHECK_TOOLS bump —
#     the first bundle carrying that fix.
#   - pkg/stdx/containers/setfn — a multi-root checker-state-leak: within ONE bnlint
#     process, linting a target AFTER a package whose dependency closure interns a
#     `readonly uint8` slice element (e.g. pkg/binate/format, via pkg/std/strings'
#     `Builder.Write(p *[]readonly uint8)`, or any `vec.Vec[@[]readonly char]` site)
#     leaked that element type into the later target's typecheck, spuriously rejecting
#     an `@[]char` (== @[]uint8) assignment ("cannot assign @[]readonly uint8 to
#     @[]uint8").  The checker's generic-instantiation cache conflating
#     `readonly`-differing type args was FIXED in `962450cf`; setfn cleared at the
#     bnc-0.0.12-pre1 CHECK_TOOLS bump — the first bundle past that fix.  (The same
#     leak, once main gained more `vec.Vec[@[]readonly char]` instantiations, also
#     began mis-firing on pkg/binate/repl/loop_test.bn — a victim that shifts with the
#     instantiation set across the Vec sweep, so the CHECK_TOOLS bump, not a per-package
#     LINT_SKIP, was the right fix.)
#   - the rest of the injectable-key-policy + Table container cone (pkg/stdx/{hash,
#     cmp} + pkg/stdx/containers/{table,mapfn,hashmap,set}) — LEFT the skip at the
#     bnc-0.0.11 bump, which carries the generic-instantiation-as-constraint-arg /
#     genericImplSatisfies fixes (2f8969e8 / 6647c49f) that pre2 lacked, so pre2's
#     false "type argument H does not satisfy Hasher[T]" / "K does not satisfy
#     Hashable" at their blanket impls is gone;
#   - the container-adoption methods-on-generics cone (pkg/stdx/containers/{vec,
#     hashmap,set} + pkg/binate/format + cmd/bnfmt), pkg/binate/interp, and
#     pkg/binate/asm/{arm32,elf,macho,parse,x64} — all cleared at the bnc-0.0.11pre2
#     bump + the --tests wiring (methods-on-generics parsing, the generic
#     name-collision fix, `undefined: __Package` resolution, and per-site
#     `// bnlint:allow managed-to-raw-assign` directives; the 1 real asm UAF was fixed
#     separately in 8a883450).
LINT_SKIP=""

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
    # like methods-on-generics — see plan-check-tools-version.md), NOT the
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
