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

# Targets skipped from linting (all tracked in claude-todo.md).  bnlint is
# fetched from the CHECK_TOOLS_VERSION bundle (bnc-0.0.11pre2), decoupled from
# BUILDER_VERSION so a newer check-tool feature does not require a build-ladder
# rung (see explorations/plan-check-tools-version.md).  Skipped targets stay
# fully type-checked and compiled by every conformance mode — only bnlint's
# style rules are paused.
#
# The only remaining skip is a PENDING REAL LINT FINDING needing a per-site fix
# before un-skipping.  (No version-lag skips remain: (1) the container-adoption
# methods-on-generics cone — pkg/stdx/containers/{vec,hashmap,set} + its importer
# chain pkg/binate/format + cmd/bnfmt — cleared at the bnc-0.0.11pre2 CHECK_TOOLS
# bump, whose bnlint parses methods-on-generic-types / parameterized-receiver
# impls AND carries the cross-package generic name-collision fix the COMBINED
# sweep needs (pre1's bnlint lints them clean individually, but colliding `Cursor`
# names across vec/set/hashmap tripped that bug in one invocation); (2)
# pkg/binate/interp's `undefined: __Package` / `_func_handle` abort cleared at the
# same bump, and its lone `[unused-func] shortName` was a FALSE POSITIVE — that
# helper is used by imports_test.bn, which `--tests` now counts — so interp lints
# clean and is no longer skipped.  bnlint typechecks dependency BODIES, so a
# version-lag skip, were one needed again, would have to cover the whole
# transitive importer chain of the source.)
#   - pkg/binate/asm/{arm32,elf,macho,parse,x64}: [managed-to-raw-assign]
#     (`var data *[]uint8 = sec.Data` — a borrow of a held @[]uint8).  Each needs
#     a per-site judgement (real UAF risk vs a safe borrow the rule over-flags);
#     the 17 safe-borrow over-flags un-skip by adopting `// bnlint:allow`
#     directives (claude-todo asm INCREMENT 2).  Uncovered once the recursive
#     pkg/ discovery below reached the compiler at pkg/binate/<pkg> (a one-level
#     `pkg/*/` glob missed it).
LINT_SKIP="pkg/binate/asm/arm32 pkg/binate/asm/elf pkg/binate/asm/macho pkg/binate/asm/parse pkg/binate/asm/x64"

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
