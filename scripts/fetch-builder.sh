#!/bin/sh
# Resolve the builder binary specified by BUILDER_VERSION and print its
# absolute path on stdout.  Callers capture it via $(...) and invoke
# directly:
#
#     BUILDER="$(scripts/fetch-builder.sh)"
#     "$BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- ...
#
# (The `-root` flag above is the bootstrap interpreter's pointer to
# the binate source root used to resolve `pkg/...` imports while
# interpreting cmd/bnc; once BUILDER_VERSION names a `bnc-*` binary
# instead, callers will invoke `"$BUILDER" -I ... -L ...` directly.)
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
#   bnc-X.Y.Z         Download the prebuilt bnc binary for the host
#                     platform from the matching GitHub release and
#                     cache it.  Asset name follows the release
#                     workflow's convention:
#                     `bnc-X.Y.Z-<host-os>-<host-arch>`.  Verifies
#                     sha256 against the release's SHA256SUMS
#                     manifest before caching.  Cache hits skip the
#                     download (and the re-verify — the cache is
#                     trusted on hit).
#
# See explorations/plan-bnc-as-builder.md for the broader migration.

set -e

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

BUILDER_BIN="$CACHE_DIR/$HOST_OS-$HOST_ARCH/bnc"

case "$BUILDER_VERSION" in
    bootstrap-*)
        BOOTSTRAP_DIR="$BINATE_DIR/../bootstrap"
        if [ ! -d "$BOOTSTRAP_DIR" ]; then
            echo "fetch-builder: bootstrap repo not found at $BOOTSTRAP_DIR" >&2
            echo "fetch-builder: clone github.com/binate/bootstrap as a sibling of this checkout" >&2
            exit 1
        fi
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
        # Cache hit: trust the prior download (sha256 was verified on
        # the way in).  On miss, fetch the SHA256SUMS manifest first,
        # locate the expected hash for this platform's asset, then
        # download the binary and verify before placing into the
        # cache.  A failed verify removes the downloaded file rather
        # than leaving a half-trusted artifact in the cache dir.
        if [ ! -x "$BUILDER_BIN" ]; then
            asset="$BUILDER_VERSION-$HOST_OS-$HOST_ARCH"
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
            mkdir -p "$(dirname "$BUILDER_BIN")"
            mv "$tmpdir/$asset" "$BUILDER_BIN"
            chmod +x "$BUILDER_BIN"
        fi
        echo "$BUILDER_BIN"
        ;;
    *)
        echo "fetch-builder: unrecognized BUILDER_VERSION prefix: $BUILDER_VERSION" >&2
        exit 1
        ;;
esac
