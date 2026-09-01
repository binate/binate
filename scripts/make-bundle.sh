#!/bin/sh
# Build a release bundle tarball for one platform.
#
# A bundle is the self-contained toolchain a release ships: the release
# binaries plus the standard library and runtime, packed so a consumer
# can use it without a Binate source checkout.  This is the same
# artifact `BUILDER` is pinned to (see BUILDER_VERSION /
# scripts/fetch-builder.sh) and the same thing the Release workflow
# (.github/workflows/release.yml) publishes — that workflow calls this
# script so local bundles and released bundles are built identically.
#
# Output: <out-dir>/<version>-<platform>.tar.gz (+ a .tar.gz.sha256
# manifest line "<sha>  <asset>", which the release job concatenates
# into SHA256SUMS).  The tarball holds a single top-level directory
# <version>-<platform>/ that fetch-builder.sh extracts with
# --strip-components=1:
#
#   <version>-<platform>/
#     bin/{bnc,bni,bnas,bnlint,bnfmt,bnld}  the release binaries
#     bin/binate-paths            search-path helper (see BUNDLE-HOWTO.md)
#     lib/runtime/                bare-metal target startup (baremetal_arm32/)
#     lib/ifaces/{core,stdlib}/   .bni interfaces (builtins + stdlib)
#     lib/impls/{core,stdlib}/    implementations (core builtins + stdlib)
#
# The lib/ tree is what bnc/bni/bnas/bnlint resolve against; see
# BUNDLE-HOWTO.md for how a consumer points -I/-L at it.  bnfmt is
# self-contained (it parses and re-prints source syntax), so it needs no lib/.
#
# Building each binary goes through scripts/build-{bnc,bni,bnas,bnlint,bnfmt,bnld}.sh,
# which resolve a BUILDER via scripts/fetch-builder.sh (a prebuilt bnc-*
# release bundle).

set -e

usage() {
    cat <<'EOF'
Usage: scripts/make-bundle.sh [--version <ver>] [--platform <plat>] [--out-dir <dir>]

Build a release bundle tarball (bin/{bnc,bni,bnas,bnlint,bnfmt,bnld} + lib/) for one
platform, writing <out-dir>/<version>-<platform>.tar.gz (+ .sha256).

Options:
  --version <ver>    bundle version label, e.g. bnc-0.0.7
                     (default: contents of the VERSION file)
  --platform <plat>  platform tag, e.g. macos-arm64 / linux-x64 / linux-arm64
                     (default: detected from the host).  A non-host platform
                     cross-compiles the binaries (needs a matching cross-
                     toolchain); lib/ is source, so it is platform-independent.
  --out-dir <dir>    directory to write the tarball into
                     (default: ./dist; created if absent)
  -h, --help         show this help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
PLATFORM=""
OUT_DIR="$PWD/dist"

while [ $# -gt 0 ]; do
    case "$1" in
        --version)    VERSION="$2"; shift 2 ;;
        --version=*)  VERSION="${1#--version=}"; shift ;;
        --platform)   PLATFORM="$2"; shift 2 ;;
        --platform=*) PLATFORM="${1#--platform=}"; shift ;;
        --out-dir)    OUT_DIR="$2"; shift 2 ;;
        --out-dir=*)  OUT_DIR="${1#--out-dir=}"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "make-bundle: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Default the version from the VERSION file (e.g. a local build of an
# in-progress "bnc-X.Y.Z-pre1").  A release passes the tag explicitly.
if [ -z "$VERSION" ]; then
    VERSION="$(tr -d '[:space:]' < "$BINATE_DIR/VERSION" 2>/dev/null || true)"
fi
if [ -z "$VERSION" ]; then
    echo "make-bundle: version is empty (pass --version or populate VERSION)" >&2
    exit 1
fi

# Host os/arch — same os/arch mapping the cache key in fetch-builder.sh uses,
# so a locally-built host bundle lands under the platform name the fetcher
# would look for.  Also the reference point for cross detection below.
case "$(uname -s)" in
    Darwin) host_os=macos ;;
    Linux)  host_os=linux ;;
    *)      host_os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) host_arch=arm64 ;;
    x86_64|amd64)  host_arch=x64 ;;
    *)             host_arch="$(uname -m)" ;;
esac

# Default the platform to the host when not given.
if [ -z "$PLATFORM" ]; then
    PLATFORM="$host_os-$host_arch"
fi

# Cross-compile detection: a platform whose arch/os differs from the host must
# be cross-built — derive the bnc --target key and pass it to the build-*.sh
# scripts, which cross-EMIT Stage 2 (gen1 stays a host binary).  Binaries built
# for a foreign platform on a host lacking the matching cross-toolchain fail
# loudly at link — strictly better than the old behavior here, which silently
# produced HOST binaries mislabeled with --platform.  lib/ is source, hence
# platform-independent, and is staged unchanged either way.
BUILD_TARGET_OPT=""
if [ "$PLATFORM" != "$host_os-$host_arch" ]; then
    case "$PLATFORM" in
        linux-x64)   xtarget=x86_64-linux ;;
        linux-arm64) xtarget=aarch64-linux ;;
        macos-x64)   xtarget=x86_64-darwin ;;
        *)
            echo "make-bundle: no cross-compile target for --platform $PLATFORM" >&2
            echo "  (host is $host_os-$host_arch; cross-buildable: linux-x64," >&2
            echo "   linux-arm64, macos-x64)" >&2
            exit 1 ;;
    esac
    BUILD_TARGET_OPT="--target $xtarget"
    echo "make-bundle: cross-compiling for $PLATFORM (bnc --target $xtarget)"
fi

bundle="$VERSION-$PLATFORM"
asset="$bundle.tar.gz"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"   # absolutize for the post-cd tar
out="$OUT_DIR/$asset"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/binate-bundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT INT TERM
dest="$STAGE/$bundle"
mkdir -p "$dest/bin" "$dest/lib"

echo "make-bundle: building $bundle"
echo "  source:  $BINATE_DIR"
echo "  output:  $out"
echo

# Build the release binaries directly into the staged bin/.  Each
# script manages its own mktemp scratch and writes only to its -o path,
# so this is safe to run concurrently with other work / worktrees.
echo "==> building binaries"
# $BUILD_TARGET_OPT is empty for a host build (unchanged) or `--target <key>`
# for a cross build; unquoted so it word-splits into two args (or none).
"$SCRIPT_DIR/build-bnc.sh"    -o "$dest/bin/bnc"    $BUILD_TARGET_OPT
"$SCRIPT_DIR/build-bni.sh"    -o "$dest/bin/bni"    $BUILD_TARGET_OPT
"$SCRIPT_DIR/build-bnas.sh"   -o "$dest/bin/bnas"   $BUILD_TARGET_OPT
"$SCRIPT_DIR/build-bnlint.sh" -o "$dest/bin/bnlint" $BUILD_TARGET_OPT
"$SCRIPT_DIR/build-bnfmt.sh"  -o "$dest/bin/bnfmt"  $BUILD_TARGET_OPT
"$SCRIPT_DIR/build-bnld.sh"   -o "$dest/bin/bnld"   $BUILD_TARGET_OPT
for b in bnc bni bnas bnlint bnfmt bnld; do
    test -x "$dest/bin/$b" || { echo "make-bundle: missing binary: $b" >&2; exit 1; }
done

# Ship the search-path helper next to the binaries (bin/ goes on PATH).  It
# emits the standard -I/-L for the bundle's lib/, self-locating the
# base as ../lib from bin/, so a consumer never re-derives the layout by hand.
# Same script the in-tree build/test scripts use, so the formula has one
# definition.  See BUNDLE-HOWTO.md.
cp "$SCRIPT_DIR/binate-paths.sh" "$dest/bin/binate-paths"
chmod +x "$dest/bin/binate-paths"
test -x "$dest/bin/binate-paths" || {
    echo "make-bundle: missing binate-paths" >&2; exit 1; }

# Bundle the stdlib + runtime that match these binaries.  cp -R keeps
# the source layout intact so a consumer resolves the bundle directly
# with -I <lib>/ifaces/... -L <lib>/impls/... (see BUNDLE-HOWTO.md).
echo "==> assembling lib/"
# Nothing from pkg/ is shipped: pkg/binate/* is the compiler's own source, and
# shipping it would make compiler internals importable through the bare-root -I
# entry.  The core builtins ship via the ifaces/ and impls/ trees below.
cp -R "$BINATE_DIR/runtime" "$dest/lib/runtime"
cp -R "$BINATE_DIR/ifaces"  "$dest/lib/ifaces"
cp -R "$BINATE_DIR/impls"   "$dest/lib/impls"

# Pack.  COPYFILE_DISABLE silences macOS's AppleDouble (._foo) metadata
# files so the archive contents are reproducible across platforms.
echo "==> packing $asset"
( cd "$STAGE" && COPYFILE_DISABLE=1 tar -czf "$out" "$bundle" )
test -s "$out"

# SHA256 of the tarball, as a SHA256SUMS-style "<sha>  <asset>" line.
if command -v sha256sum >/dev/null 2>&1; then
    sha="$(sha256sum "$out" | awk '{print $1}')"
else
    sha="$(shasum -a 256 "$out" | awk '{print $1}')"
fi
printf '%s  %s\n' "$sha" "$asset" > "$out.sha256"

echo
echo "make-bundle: wrote $out"
echo "make-bundle: sha256 $sha"
