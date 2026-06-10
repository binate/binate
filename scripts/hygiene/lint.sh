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

# Targets temporarily skipped because they use a language feature newer
# than the BUILDER-bundled bnlint can typecheck.  The bundled bnlint
# (from BUILDER_VERSION) is a snapshot; source that references a feature
# postdating that snapshot makes it abort at the typecheck pass before any
# lint rule runs.  Skipped targets stay fully type-checked and compiled by
# every conformance mode — only bnlint's style rules are paused here.
#
# bnlint typechecks dependency BODIES, so the skip must cover the whole
# transitive importer chain of the offending source, not just the file
# that names the feature.
#
# TODO(remove after next release): pkg/binate/vm's extern_register_std.bn
# references each package's compiler-synthesized `_Package()` accessor
# (Phase B of explorations/notes-package-introspection.md) to register it
# as a VM extern.  The bundled bnlint predates that accessor's typecheck
# support, so it rejects `_func_handle(rt._Package)` / `@reflect.Package`.
# pkg/binate/repl imports vm and cmd/bni imports both, so all three abort.
# Drop this skip once BUILDER_VERSION is bumped to a snapshot that includes
# the `_Package` selector + `_func_handle` typecheck support (a from-source
# bnlint already lints all three cleanly).
LINT_SKIP="pkg/binate/vm pkg/binate/repl cmd/bni"

# Discover targets:
#   - every directory under pkg/ that has any .bn files (excludes builtin
#     pkg/bootstrap, which has only the .bni interface)
#   - every directory under cmd/
TARGETS=""
for d in "$BINATE_DIR"/pkg/*/; do
    [ -d "$d" ] || continue
    # Skip dirs with no .bn files (defensive; pkg/bootstrap has no dir at all)
    found=0
    for bn in "$d"*.bn; do
        [ -f "$bn" ] && found=1 && break
    done
    [ "$found" -eq 1 ] || continue
    rel="pkg/$(basename "$d")"
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
