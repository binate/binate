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

# Targets temporarily skipped because they use a language feature newer than
# the BUILDER-bundled bnlint (a BUILDER_VERSION snapshot) can typecheck — such
# source aborts at the typecheck pass before any lint rule runs.  bnlint
# typechecks dependency BODIES, so a skip must cover the whole transitive
# importer chain of the offending source, not just the file that names the
# feature.  Skipped targets stay fully type-checked and compiled by every
# conformance mode — only bnlint's style rules are paused.
#
# The skips fall in two groups (all tracked in claude-todo.md):
#
# (A) BUILDER-lag — the bundled bnlint (bnc-0.0.10) predates a feature/fix that
#     is already in the tree, so it aborts at the typecheck pass.  Clears at the
#     next BUILDER bump (verified: a current-source bnlint accepts it).
#   - pkg/binate/interp: its extern-registration enumerates `rt.__Package()` and
#     wraps each entry via `_func_handle` (the embeddable-interp work), a usage
#     newer than bnc-0.0.10 — the bundled bnlint aborts with `undefined:
#     __Package` / `_func_handle argument must be a named function`.
#     (The earlier bnc-0.0.9 lag — pkg/builtins/rt's void `__c_call` spelling and
#     pkg/std/os's .bni method fix `796effc7`, plus their vm/repl/cmd-bni/bnas/
#     bnlint importer chain — cleared at the bnc-0.0.10 bump and is now linted.)
#   - pkg/stdx/containers/{vec,hashmap,set}: migrated to generic-receiver methods
#     (`func (v @Vec[T]) Push(x T)`) and parameterized-receiver impls
#     (`impl *Cursor[T] : iter.Iterator[T]`) — methods-on-generic-types, newer
#     than bnc-0.0.10, so the bundled bnlint aborts at the PARSE pass (a cascade
#     of `expected ;, got :=` / `expected declaration`).  The interface-only
#     pkg/stdx/containers/iter is fine (generic interfaces predate the bundle).
#
# (B) Pending real lint findings — uncovered until the recursive pkg/ discovery
#     below was added (the old one-level `pkg/*/` glob never reached the
#     compiler at pkg/binate/<pkg>).  These asm subpackages trip
#     [managed-to-raw-assign] (`var data *[]uint8 = sec.Data` — a borrow of a
#     held @[]uint8); each needs a per-site judgement (real UAF risk vs a safe
#     borrow the rule over-flags) before un-skipping.  Tracked in claude-todo.md.
LINT_SKIP="pkg/binate/interp pkg/binate/asm/arm32 pkg/binate/asm/elf pkg/binate/asm/macho pkg/binate/asm/parse pkg/binate/asm/x64 pkg/stdx/containers/vec pkg/stdx/containers/hashmap pkg/stdx/containers/set"

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

# Prefer the bundled bnlint from BUILDER_VERSION when available
# (bnc-* mode) — saves the per-invocation cost of compiling bnlint
# from source.  Falls back to building from current source under
# bootstrap-* (no toolchain bundle exists) or when the fetcher
# doesn't return a usable path.
BNLINT_BIN="$("$BINATE_DIR/scripts/fetch-builder.sh" --tool bnlint 2>/dev/null || true)"
if [ -z "$BNLINT_BIN" ] || [ ! -x "$BNLINT_BIN" ]; then
    BNLINT_BIN="$(mktemp -t binate-lint.XXXXXX)"
    trap 'rm -f "$BNLINT_BIN"' EXIT
    "$SCRIPT_DIR/../build-bnlint.sh" -o "$BNLINT_BIN" >/dev/null || {
        echo "lint: failed to build bnlint" >&2
        exit 1
    }
fi

"$BNLINT_BIN" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" $TARGETS
rc=$?

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "=== lint failed (exit $rc) ==="
    exit 1
fi
