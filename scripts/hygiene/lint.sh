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
# Currently empty: the previous skip (pkg/binate/vm + its importers
# pkg/binate/repl, cmd/bni) was for the `_Package()` accessor /
# `_func_handle(rt._Package)` / `@reflect.Package`, which the bundled bnlint
# now typechecks as of BUILDER_VERSION bnc-0.0.9 (verified: it lints all three
# cleanly).
LINT_SKIP=""

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

# TEMPORARY shim for the bundled bnlint: pkg/builtins/build is now one
# #[build(...)]-gated file (ifaces/core), and buildcfg imports it, so it is in
# this lint's dependency closure — but the bundled bnlint (bnc-0.0.8) predates
# #[build] parsing and chokes on it.  bnlint only needs build's *interface*
# (the const names/types) to typecheck, not its gated values, so shadow the
# real file with an UNGATED build.bni shim on -I (prepended, first-match-wins).
# Drop this once BUILDER_VERSION ships a bnc whose parser handles #[build].
BUILD_SHIM_DIR="$(mktemp -d -t binate-build-shim.XXXXXX)"
trap 'rm -f "$BNLINT_BIN"; rm -rf "$BUILD_SHIM_DIR"' EXIT
mkdir -p "$BUILD_SHIM_DIR/pkg/builtins"
cat > "$BUILD_SHIM_DIR/pkg/builtins/build.bni" <<'SHIM'
// Ungated stand-in for pkg/builtins/build, used ONLY to let the pre-#[build]
// bundled bnlint typecheck buildcfg's use of build.* (see scripts/hygiene/
// lint.sh).  Values are irrelevant to linting; the real gated file lives in
// ifaces/core/pkg/builtins/build.bni.
package "pkg/builtins/build"
type OSType int
const ( OS_LINUX OSType = iota; OS_DARWIN; OS_BAREMETAL )
type ArchType int
const ( ARCH_X64 ArchType = iota; ARCH_AARCH64; ARCH_ARM32 )
const ARCH_ARM64 ArchType = ARCH_AARCH64
const OS OSType = OS_DARWIN
const Arch ArchType = ARCH_AARCH64
const PtrSize int = 8
const IntSize int = 8
SHIM

"$BNLINT_BIN" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$BUILD_SHIM_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" $TARGETS
rc=$?

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "=== lint failed (exit $rc) ==="
    exit 1
fi
