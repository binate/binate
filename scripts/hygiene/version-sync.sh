#!/bin/sh
# Usage: ./scripts/hygiene/version-sync.sh
#
# Checks that the release identifier baked into the pkg/binate/version
# package (version/version.bn's `var Version ... = "..."`) tracks the
# repo-root VERSION file.  VERSION additionally carries a `bnc-` builder
# prefix (distinguishing bnc-as-builder from the retired bootstrap
# interpreter); the version package omits it (the calling tool prepends
# its own name).  So this compares VERSION with its `bnc-` prefix
# stripped against the package literal — e.g. VERSION `bnc-0.0.7-pre`
# must match `Version = "0.0.7-pre"`.  A release bumps both in lockstep.
#
# Exit code: 1 if they differ (or either can't be read / parsed),
# 0 if they match.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION_FILE="$BINATE_DIR/VERSION"
VERSION_SRC="$BINATE_DIR/pkg/binate/version/version.bn"

if [ ! -f "$VERSION_FILE" ]; then
    echo "version-sync: VERSION file not found at $VERSION_FILE"
    exit 1
fi
if [ ! -f "$VERSION_SRC" ]; then
    echo "version-sync: version source not found at $VERSION_SRC"
    exit 1
fi

want=$(tr -d '[:space:]' < "$VERSION_FILE")
# VERSION carries the `bnc-` builder prefix; the version package omits
# it.  Strip it (if present) so the two name the same release.
want_bare=${want#bnc-}

# Extract the literal from:  var Version *[]readonly char = "<value>"
got=$(grep -E '^var Version[[:space:]].*=[[:space:]]*"' "$VERSION_SRC" \
    | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')

if [ -z "$got" ]; then
    echo "version-sync: could not find the version string literal in $VERSION_SRC"
    echo "  (expected a line like: var Version *[]readonly char = \"...\")"
    exit 1
fi

if [ "$got" != "$want_bare" ]; then
    echo "version-sync: version string out of sync"
    echo "  VERSION file (minus bnc- prefix): $want_bare"
    echo "  pkg/binate/version/version.bn:    $got"
    echo "  update the version-package string to match VERSION (they name the same build)"
    exit 1
fi
