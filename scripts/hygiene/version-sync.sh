#!/bin/sh
# Usage: ./scripts/hygiene/version-sync.sh
#
# Checks that the version string baked into the pkg/binate/version
# package (version/version.bn's `var version ... = "..."`) is identical
# to the repo-root VERSION file.  Both name the same build identifier
# (e.g. `bnc-0.0.7-pre`); a release bumps VERSION and must bump the
# version-package string in lockstep, or a tool's `--version` output
# (via version.Format) would report a stale identifier.
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

# Extract the literal from:  var version *[]readonly char = "<value>"
got=$(grep -E '^var version[[:space:]].*=[[:space:]]*"' "$VERSION_SRC" \
    | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')

if [ -z "$got" ]; then
    echo "version-sync: could not find the version string literal in $VERSION_SRC"
    echo "  (expected a line like: var version *[]readonly char = \"...\")"
    exit 1
fi

if [ "$got" != "$want" ]; then
    echo "version-sync: version string out of sync"
    echo "  VERSION file:                  $want"
    echo "  pkg/binate/version/version.bn: $got"
    echo "  update the version-package string to match VERSION (they name the same build)"
    exit 1
fi
