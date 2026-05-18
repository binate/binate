#!/bin/sh
# Resolve the builder binary specified by BUILDER_VERSION and print its
# absolute path on stdout.  Callers capture it via $(...) and invoke
# directly:
#
#     BUILDER="$(scripts/fetch-builder.sh)"
#     "$BUILDER" --root "$BINATE_DIR" ...
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
#   bnc-X.Y.Z         (Future.)  Download the bnc binary for the host
#                     platform from the matching GitHub release and
#                     cache it.  Verifies sha256 against the release
#                     manifest.  Not yet implemented — falls through
#                     to an error.
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
        echo "fetch-builder: bnc-X.Y.Z prefix not yet implemented — see plan-bnc-as-builder.md" >&2
        exit 1
        ;;
    *)
        echo "fetch-builder: unrecognized BUILDER_VERSION prefix: $BUILDER_VERSION" >&2
        exit 1
        ;;
esac
