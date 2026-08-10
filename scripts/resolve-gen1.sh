#!/bin/sh
# scripts/resolve-gen1.sh — resolve a cached "gen1" compiler (the BUILDER
# compiling the checkout's cmd/bnc) and print its path, building + caching it on
# a miss.  Mirrors fetch-builder.sh: stdout is ONLY the resolved binary path;
# all progress/diagnostics go to stderr.
#
# WHY a cache: gen1 is a native binary that depends solely on (a) the pinned
# BUILDER (its compiler + frozen stdlib bundle) and (b) the checkout source that
# feeds the build (cmd/bnc + the pkg/binate compiler cone and the ifaces/impls
# stdlib it resolves via `--prepend "$BINATE_DIR"`).  Every e2e test that needs a
# checkout-source compiler (os.Args / testing.Print* / … postdate the frozen
# BUILDER bundle) was rebuilding its own gen1 from scratch — one ~40s build per
# such test.  Caching it means a full e2e run builds gen1 once and shares it.
#
# CACHE KEY: a hash of the WHOLE working tree (committed HEAD + tracked diff +
# untracked source), which already contains BUILDER_VERSION, plus the host
# platform.  Deliberately NOT a precise dependency cone: over-invalidation (an
# edit anywhere rebuilds gen1) is cheap and safe; a too-narrow key that reused a
# stale gen1 after a real compiler-source change would silently run tests against
# the wrong compiler.  A clean checkout (CI) yields a stable key, so every gen1
# test in the run shares one build; a dirty dev tree rebuilds only when its
# content actually changes.
#
# Usage: resolve-gen1.sh          # print path to a cached/freshly-built gen1 bnc
#        resolve-gen1.sh --force  # ignore any cached entry and rebuild

set -e

force=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force) force=1; shift ;;
        --)      shift; break ;;
        -*)      echo "resolve-gen1: unknown flag: $1" >&2; exit 2 ;;
        *)       echo "resolve-gen1: unexpected arg: $1" >&2; exit 2 ;;
    esac
done

# Locate the binate repo root from this script's path so it works regardless of
# the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Detect host platform — part of the cache key so multi-OS dev machines and
# shared caches don't collide.  Mirrors fetch-builder.sh.
case "$(uname -s)" in
    Darwin) HOST_OS=macos ;;
    Linux)  HOST_OS=linux ;;
    *)      HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) HOST_ARCH=arm64 ;;
    x86_64|amd64)  HOST_ARCH=x64 ;;
    *)             HOST_ARCH="$(uname -m)" ;;
esac
PLATFORM="$HOST_OS-$HOST_ARCH"

# sha256 helper: prefer shasum (present on macOS + most Linux), fall back to
# sha256sum.  Emits the bare hex digest.
_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    else
        sha256sum | cut -d' ' -f1
    fi
}

# Whole-tree content hash: HEAD + tracked working-tree diff + untracked source
# (names and contents).  Uses only read-only git plumbing — never git stash /
# write-tree, so it does not touch the index or working tree.
tree_hash="$(
    {
        git -C "$BINATE_DIR" rev-parse HEAD 2>/dev/null || echo "no-head"
        git -C "$BINATE_DIR" diff HEAD 2>/dev/null || true
        git -C "$BINATE_DIR" ls-files --others --exclude-standard -z 2>/dev/null \
            | while IFS= read -r -d '' f; do
                printf '%s\n' "$f"
                shasum -a 256 "$BINATE_DIR/$f" 2>/dev/null || true
            done
    } | _sha256
)"

KEY="$(printf '%s\n%s\n' "$PLATFORM" "$tree_hash" | _sha256)"

CACHE_ROOT="${BINATE_GEN1_CACHE_DIR:-$HOME/.cache/binate/gen1}"
CACHE_DIR="$CACHE_ROOT/$KEY"
CACHE_BIN="$CACHE_DIR/bnc"

if [ "$force" -eq 0 ] && [ -x "$CACHE_BIN" ]; then
    echo "$CACHE_BIN"
    exit 0
fi

# Serialize concurrent builders (a parallel e2e run) with a mkdir lock so the
# suite still builds gen1 only once.  If another builder holds the lock, wait for
# it to publish the binary rather than building a redundant copy; fall back to
# building ourselves if it never appears (crashed / timed out).
mkdir -p "$CACHE_ROOT"
LOCK="$CACHE_DIR.lock"
have_lock=0
if [ "$force" -eq 0 ] && ! mkdir "$LOCK" 2>/dev/null; then
    waited=0
    while [ ! -x "$CACHE_BIN" ] && [ "$waited" -lt 600 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ -x "$CACHE_BIN" ]; then
        echo "$CACHE_BIN"
        exit 0
    fi
    # The other builder did not publish — take over.
    mkdir "$LOCK" 2>/dev/null && have_lock=1
else
    have_lock=1
fi
[ "$have_lock" -eq 1 ] && trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Re-check after acquiring the lock: a builder we waited on may have just won.
if [ "$force" -eq 0 ] && [ -x "$CACHE_BIN" ]; then
    echo "$CACHE_BIN"
    exit 0
fi

echo "resolve-gen1: building gen1 for $PLATFORM (key $(printf '%.8s' "$KEY")…)" >&2

BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
BUILDER_RUNTIME="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BUILDER_LIB")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/binate_gen1.XXXXXX")"
trap 'rmdir "$LOCK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/build"
GEN1_TMP="$WORK/bnc"

# gen1 = the BUILDER compiling checkout cmd/bnc.  Its builtin + stdlib deps
# resolve from the BUILDER's frozen bundle (`--base "$BUILDER_LIB"`, also the C
# runtime); only the compiler's own source (pkg/binate, pkg/bootstrap) comes from
# the checkout via `--prepend "$BINATE_DIR"`.  Identical to build-compilers.sh
# build_gen1 and e2e/os-args.sh — the shape this script exists to deduplicate.
if ! "$BUILDER" \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
        -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
        --runtime "$BUILDER_RUNTIME" \
        --build-dir "$WORK/build" \
        -o "$GEN1_TMP" \
        "$BINATE_DIR/cmd/bnc" >"$WORK/log" 2>&1 || [ ! -x "$GEN1_TMP" ]; then
    echo "resolve-gen1: gen1 build failed:" >&2
    sed 's/^/  /' "$WORK/log" >&2
    exit 1
fi

# Publish atomically: move the finished binary into place with a rename so a
# concurrent reader never sees a half-written file.
mkdir -p "$CACHE_DIR"
mv -f "$GEN1_TMP" "$CACHE_BIN"
echo "$CACHE_BIN"
