#!/bin/sh
# Resolve the builder bundle specified by BUILDER_VERSION and print
# the requested path (binary or library root) on stdout.  Typical
# usage from a runner:
#
#     BUILDER="$(scripts/fetch-builder.sh)"           # binary path
#     BUILDER_LIB="$(scripts/fetch-builder.sh --lib)" # stdlib root
#     "$BUILDER" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib" \
#         "$BINATE_DIR/cmd/bnc" -- \
#         -I "$BINATE_DIR:$BUILDER_LIB:$BUILDER_LIB/ifaces/core:$BUILDER_LIB/ifaces/stdlib" \
#         -L "$BINATE_DIR:$BUILDER_LIB:$BUILDER_LIB/impls/core/common:$BUILDER_LIB/impls/core/libc:$BUILDER_LIB/impls/stdlib" ...
#
# Modes:
#   (no flags)             print the default tool's invocation path
#                          (bnc).  For bnc-* this is a wrapper script
#                          that hides the bootstrap-vs-bnc calling-
#                          shape difference; for bootstrap-* this is
#                          the bootstrap binary directly.
#   --tool <bnc|bni|bnas|bnlint>
#                          print that tool's invocation path.  For
#                          bootstrap-*, only `bnc` is meaningful
#                          (there is one Go binary) and other names
#                          are an error.
#   --lib                  print the stdlib root.  For bnc-* this is
#                          the bundle's `lib/`; for bootstrap-* this
#                          is the binate checkout (since bootstrap
#                          interprets bnc directly against current
#                          sources — there is no pinned bundle).
#
# Calling-shape compatibility (bnc-*):
# Builder-link callers invoke the resolved BUILDER as
#   "$BUILDER" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib" \
#       "$BINATE_DIR/cmd/bnc" -- <bnc-args>
# because under bootstrap-* mode BUILDER is the bootstrap interpreter
# and that prefix tells bootstrap to load cmd/bnc from $BINATE_DIR.
# Under bnc-* mode BUILDER is a bnc binary that has no such flag.  To
# keep callers untouched across the BUILDER_VERSION switch, bnc-*
# mode returns a tiny wrapper script that strips the prefix when
# present and exec's the real binary.  Direct callers (no prefix)
# pass through unchanged.
#
# Supports two BUILDER_VERSION schemes:
#
#   bootstrap-X.Y.Z   Build the sibling `../bootstrap/` Go repo via
#                     `go build` and cache the resulting binary.  The
#                     version is informational — the fetcher uses the
#                     bootstrap repo's working tree as-is.  A
#                     `bootstrap-X.Y.Z` tag exists in that repo as a
#                     reproducibility anchor; checking out that tag
#                     before building is the user's responsibility.
#
#   bnc-X.Y.Z         Download the prebuilt release tarball for the
#                     host platform from the matching GitHub release
#                     and extract it.  Asset name follows the release
#                     workflow's convention:
#                     `bnc-X.Y.Z-<host-os>-<host-arch>.tar.gz`,
#                     containing `bin/{bnc,bni,bnas,bnlint}` and
#                     `lib/{pkg,runtime}`.  Verifies sha256 against
#                     the release's SHA256SUMS manifest before
#                     extracting.  Cache hits skip the download (and
#                     the re-verify — the cache is trusted on hit).
#
# See explorations/plan-bnc-as-builder.md for the broader migration.

set -e

mode=bin
tool=bnc
while [ $# -gt 0 ]; do
    case "$1" in
        --lib)        mode=lib; shift ;;
        --tool)       tool="$2"; shift 2 ;;
        --tool=*)     tool="${1#--tool=}"; shift ;;
        --)           shift; break ;;
        -*)           echo "fetch-builder: unknown flag: $1" >&2; exit 2 ;;
        *)            echo "fetch-builder: unexpected arg: $1" >&2; exit 2 ;;
    esac
done

case "$tool" in
    bnc|bni|bnas|bnlint) ;;
    *) echo "fetch-builder: unknown --tool: $tool" >&2; exit 2 ;;
esac

# Locate the binate repo root from this script's path so the fetcher
# works regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$BINATE_DIR/BUILDER_VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "fetch-builder: $VERSION_FILE not found" >&2
    exit 1
fi

BUILDER_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ -z "$BUILDER_VERSION" ]; then
    echo "fetch-builder: BUILDER_VERSION is empty" >&2
    exit 1
fi

CACHE_DIR="${BINATE_CACHE_DIR:-$HOME/.cache/binate/builders}/$BUILDER_VERSION"
mkdir -p "$CACHE_DIR"

# Detect host platform — used in the cache key so multi-OS dev
# machines and shared NFS-style caches don't clash.
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

PLATFORM_DIR="$CACHE_DIR/$HOST_OS-$HOST_ARCH"

case "$BUILDER_VERSION" in
    bootstrap-*)
        BOOTSTRAP_DIR="$BINATE_DIR/../bootstrap"
        if [ ! -d "$BOOTSTRAP_DIR" ]; then
            echo "fetch-builder: bootstrap repo not found at $BOOTSTRAP_DIR" >&2
            echo "fetch-builder: clone github.com/binate/bootstrap as a sibling of this checkout" >&2
            exit 1
        fi
        if [ "$mode" = lib ]; then
            # bootstrap-* has no separate stdlib bundle — the
            # bootstrap interpreter loads bnc and its dep tree
            # directly from the current checkout.
            echo "$BINATE_DIR"
            exit 0
        fi
        if [ "$tool" != bnc ]; then
            echo "fetch-builder: BUILDER_VERSION=$BUILDER_VERSION has no '$tool' binary" >&2
            echo "fetch-builder: (bootstrap mode ships a single Go binary; use bnc-* for the full toolchain)" >&2
            exit 1
        fi
        BUILDER_BIN="$PLATFORM_DIR/bnc"
        # Rebuild if the cached binary is missing or older than any
        # .go source under the bootstrap repo.  `go build` is
        # incremental so this is cheap when nothing changed.
        needs_rebuild=0
        if [ ! -x "$BUILDER_BIN" ]; then
            needs_rebuild=1
        else
            # Any .go file newer than the cached binary?
            newer="$(find "$BOOTSTRAP_DIR" -name '*.go' -newer "$BUILDER_BIN" 2>/dev/null | head -1)"
            if [ -n "$newer" ]; then
                needs_rebuild=1
            fi
        fi
        if [ "$needs_rebuild" = 1 ]; then
            mkdir -p "$(dirname "$BUILDER_BIN")"
            (cd "$BOOTSTRAP_DIR" && go build -o "$BUILDER_BIN" .) 1>&2
        fi
        echo "$BUILDER_BIN"
        ;;
    bnc-*)
        # The bundle extracts to <platform-dir>/bundle/, with bin/
        # and lib/ subtrees.  A marker file (bundle/.fetched)
        # records "this is a complete, verified extract" so a
        # partially extracted tree (e.g. process killed mid-tar)
        # doesn't get confused with a good cache.
        BUNDLE_DIR="$PLATFORM_DIR/bundle"
        MARKER="$BUNDLE_DIR/.fetched"
        if [ ! -f "$MARKER" ]; then
            asset="$BUILDER_VERSION-$HOST_OS-$HOST_ARCH.tar.gz"
            release_url="${BINATE_RELEASE_URL:-https://github.com/binate/binate/releases/download}/$BUILDER_VERSION"
            tmpdir="$(mktemp -d)"
            trap 'rm -rf "$tmpdir"' EXIT INT TERM
            if ! curl -fL --retry 3 --retry-delay 2 \
                    -o "$tmpdir/SHA256SUMS" \
                    "$release_url/SHA256SUMS" 2>"$tmpdir/curl.err"; then
                echo "fetch-builder: failed to download $release_url/SHA256SUMS" >&2
                cat "$tmpdir/curl.err" >&2 2>/dev/null || true
                exit 1
            fi
            expected_sha="$(awk -v a="$asset" '$2 == a { print $1; exit }' \
                "$tmpdir/SHA256SUMS")"
            if [ -z "$expected_sha" ]; then
                echo "fetch-builder: no SHA256SUMS entry for $asset in $BUILDER_VERSION" >&2
                echo "fetch-builder: (manifest may be missing this platform's build)" >&2
                exit 1
            fi
            if ! curl -fL --retry 3 --retry-delay 2 \
                    -o "$tmpdir/$asset" \
                    "$release_url/$asset" 2>"$tmpdir/curl.err"; then
                echo "fetch-builder: failed to download $release_url/$asset" >&2
                cat "$tmpdir/curl.err" >&2 2>/dev/null || true
                exit 1
            fi
            if command -v sha256sum >/dev/null 2>&1; then
                actual_sha="$(sha256sum "$tmpdir/$asset" | awk '{print $1}')"
            else
                actual_sha="$(shasum -a 256 "$tmpdir/$asset" | awk '{print $1}')"
            fi
            if [ "$actual_sha" != "$expected_sha" ]; then
                echo "fetch-builder: sha256 mismatch for $asset" >&2
                echo "  expected: $expected_sha" >&2
                echo "  actual:   $actual_sha" >&2
                exit 1
            fi
            # Tarball contains a single top-level dir <asset-name>/;
            # strip it so the cache layout is platform-stable.
            rm -rf "$BUNDLE_DIR"
            mkdir -p "$BUNDLE_DIR"
            tar -xzf "$tmpdir/$asset" -C "$BUNDLE_DIR" --strip-components=1
            touch "$MARKER"
        fi
        if [ "$mode" = lib ]; then
            echo "$BUNDLE_DIR/lib"
        else
            # Wrapper-script indirection so callers keep one
            # invocation shape across bootstrap-* and bnc-*
            # BUILDER_VERSION schemes.  The bootstrap shape is
            # `$BUILDER -I <dir> -L <dir> <src> -- <bnc-args>`;
            # under bootstrap-* mode that's passed through to the
            # Go interpreter literally (it loads <src> and forwards
            # <bnc-args> after `--`).  Under bnc-* mode `$BUILDER`
            # is a native binary that has no such prefix, so the
            # wrapper strips everything up to and including `--`
            # before exec'ing the bundled bnc / bni / etc.  Direct
            # callers (no prefix) pass through unchanged.
            REAL_BIN="$BUNDLE_DIR/bin/$tool"
            WRAPPER="$PLATFORM_DIR/wrappers/$tool"
            # Always regenerate: the wrapper template lives in
            # this script, so a script update needs to invalidate
            # any previously cached wrapper.  The wrapper itself
            # is a handful of lines, so the rewrite cost is trivial.
            mkdir -p "$(dirname "$WRAPPER")"
            cat > "$WRAPPER" <<EOF
#!/bin/sh
# Generated by scripts/fetch-builder.sh.  Strip the bootstrap-shape
# prefix (the args bootstrap consumes before its \`--\` separator)
# when present, then exec the real binary.  Trigger: first arg
# looks like a bootstrap flag.  If there's no \`--\` in argv we
# fall through (direct callers pass unchanged).
case "\$1" in
    -root|-I|-L)
        seen_dashdash=0
        for arg; do
            if [ "\$arg" = "--" ]; then seen_dashdash=1; break; fi
        done
        if [ "\$seen_dashdash" = 1 ]; then
            while [ "\$1" != "--" ]; do shift; done
            shift  # past \`--\`
        fi
        ;;
esac
exec "$REAL_BIN" "\$@"
EOF
            chmod +x "$WRAPPER"
            echo "$WRAPPER"
        fi
        ;;
    *)
        echo "fetch-builder: unrecognized BUILDER_VERSION prefix: $BUILDER_VERSION" >&2
        exit 1
        ;;
esac
