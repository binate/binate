#!/bin/sh
# Usage: ./scripts/hygiene/bnfmt-format.sh
#
# Checks that every .bn / .bni file in the tree's Binate source is already bnfmt-
# formatted (the self-hosted formatter reflows nothing).  Fails, listing the
# offending files, if any would change.
#
# Scope ($ROOTS): the compiler + tools (pkg/, cmd/), the stdlib impls + interfaces
# (impls/, ifaces/), the perf programs, the selftest example, and the baremetal
# runtime interface.  conformance/ is deliberately EXCLUDED -- it holds intentional
# parse/lexer-error fixtures bnfmt cannot (and must not) parse, plus programs whose
# exact layout is part of what they test.
#
# bnfmt is not yet in the BUILDER bundle, so this builds it from source and caches
# the binary keyed on a hash of bnfmt's build inputs (its own package plus the
# parser/lexer/ast/token/buf it depends on): a run rebuilds only when bnfmt's
# behaviour could actually change, and reuses the cached binary otherwise.
#
# TODO (after the next release, once bnfmt ships in the BUILDER bundle): drop the
# build-and-cache below and fetch the bundled bnfmt via `fetch-builder.sh --tool
# bnfmt`, mirroring lint.sh's `--tool bnlint` (build-from-source as the fallback).
#
# Exit code: 1 if any file is unformatted (or bnfmt fails to build), 0 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$BINATE_DIR" || exit 1

ROOTS="pkg cmd impls ifaces perf examples runtime"

# Portable content hash (macOS ships shasum; Linux ships sha1sum; cksum is the
# POSIX fallback).  Only consistency on one machine matters -- the cache is local.
hashcmd() {
	if command -v shasum >/dev/null 2>&1; then shasum
	elif command -v sha1sum >/dev/null 2>&1; then sha1sum
	else cksum
	fi
}

# Cache key from bnfmt's build inputs.  The trailing `*` on each package pulls in
# both the package directory and its sibling top-level interface (e.g. both
# pkg/binate/ast/ and pkg/binate/ast.bni).  std/strings + stdx/slices are omitted:
# they are stable library code whose contents do not change bnfmt's output.
key=$(find cmd/bnfmt pkg/binate/format* pkg/binate/parser* pkg/binate/lexer* \
		pkg/binate/ast* pkg/binate/token* pkg/binate/buf* \
		\( -name '*.bn' -o -name '*.bni' \) 2>/dev/null | LC_ALL=C sort \
		| xargs cat 2>/dev/null | hashcmd | cut -d' ' -f1)

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/binate/bnfmt"
bnfmt="$cache_dir/bnfmt-$key"

if [ -n "$key" ] && [ -x "$bnfmt" ]; then
	touch "$bnfmt" 2>/dev/null || true   # keep an in-use binary from being pruned
else
	# Build to a temp path (in the cache dir when writable, else a throwaway),
	# then atomically move into place so a concurrent run never sees a partial.
	dest="$bnfmt"
	if [ -z "$key" ] || ! mkdir -p "$cache_dir" 2>/dev/null; then
		dest=""   # no usable cache this run
	fi
	if [ -n "$dest" ]; then
		tmp="$(mktemp "$cache_dir/bnfmt-build.XXXXXX")" || dest=""
	fi
	if [ -z "$dest" ]; then
		tmp="$(mktemp)" || { echo "bnfmt-format: mktemp failed" >&2; exit 1; }
		trap 'rm -f "$tmp"' EXIT
	fi
	if ! "$BINATE_DIR/scripts/build-bnfmt.sh" -o "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		echo "bnfmt-format: failed to build bnfmt (scripts/build-bnfmt.sh)" >&2
		exit 1
	fi
	if [ -n "$dest" ]; then
		mv -f "$tmp" "$bnfmt"
		# Prune cached binaries untouched for a week; an in-use one is kept fresh
		# by the touch above, so this won't evict a concurrent worktree's build.
		find "$cache_dir" -maxdepth 1 -name 'bnfmt-*' -type f -mtime +7 -delete 2>/dev/null || true
	else
		bnfmt="$tmp"
	fi
fi

unformatted=""
for f in $(find $ROOTS \( -name '*.bn' -o -name '*.bni' \) 2>/dev/null | LC_ALL=C sort); do
	"$bnfmt" --check "$f" >/dev/null 2>&1 || unformatted="$unformatted $f"
done

if [ -n "$unformatted" ]; then
	echo "The following files are not bnfmt-formatted"
	echo "(fix: scripts/build-bnfmt.sh -o /tmp/bnfmt && /tmp/bnfmt -w <file>):"
	for f in $unformatted; do echo "  $f"; done
	echo ""
	echo "=== bnfmt-format failed ==="
	exit 1
fi
