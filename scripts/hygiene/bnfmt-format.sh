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
# bnfmt is fetched from the CHECK_TOOLS_VERSION bundle when that release ships one
# (`fetch-builder.sh --check-tools --tool bnfmt`, mirroring lint.sh's bnlint fetch).
# CHECK_TOOLS_VERSION may be a pre-release ahead of the BUILDER (see
# plan-check-tools-version.md).  The current CHECK_TOOLS_VERSION ships a bnfmt, so
# the bundled binary is used directly.  A bundle WITHOUT a bnfmt
# (as bnc-0.0.10 was) falls back to building bnfmt from source and caching the
# binary keyed on a hash of its build inputs (its own package plus the
# parser/lexer/ast/token/buf it depends on): that run rebuilds only when bnfmt's
# behaviour could change, and reuses the cached binary otherwise.  This from-source
# path is dormant while CHECK_TOOLS_VERSION points at a bundle that ships bnfmt.
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

# Prefer the bundled bnfmt from CHECK_TOOLS_VERSION when available (a bnc-* bundle
# that ships bnfmt).  --check-tools resolves the CHECK-TOOLS release, which may be a
# pre-release ahead of the BUILDER (see plan-check-tools-version.md).  Bundles
# without a bnfmt (e.g. bnc-0.0.10) make the fetcher exit non-zero;
# then bnfmt stays empty and the from-source build + cache below runs.  This whole
# from-source path drops out once CHECK_TOOLS_VERSION ships a bnfmt.
bnfmt="$("$BINATE_DIR/scripts/fetch-builder.sh" --check-tools --tool bnfmt 2>/dev/null || true)"
if [ -z "$bnfmt" ] || [ ! -x "$bnfmt" ]; then
	# Cache key from bnfmt's build inputs.  The trailing `*` on each package pulls
	# in both the package directory and its sibling top-level interface (e.g. both
	# pkg/binate/ast/ and pkg/binate/ast.bni).  std/strings + stdx/slices are
	# omitted: stable library code whose contents do not change bnfmt's output.
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
			# Prune cached binaries untouched for a week; an in-use one is kept
			# fresh by the touch above, so this won't evict a concurrent build.
			find "$cache_dir" -maxdepth 1 -name 'bnfmt-*' -type f -mtime +7 -delete 2>/dev/null || true
		else
			bnfmt="$tmp"
		fi
	fi
fi

# One `bnfmt --check` over ALL in-scope files, instead of a fork per file (~1,500
# execs).  bnfmt processes every file -- one file's failure does not skip the rest
# -- and names each offending file on stderr as `<path>: not formatted` (or, for an
# unparseable file, `<path>: <error>`), exiting non-zero if any failed.  The file
# set is tens of KB of paths, far under ARG_MAX, so a single invocation suffices.
files="$(find $ROOTS \( -name '*.bn' -o -name '*.bni' \) 2>/dev/null | LC_ALL=C sort)"

# The single invocation below relies on unquoted word-splitting of $files, which
# is safe only because Binate source paths carry no whitespace or shell-glob
# character.  Enforce that precondition loudly: a mis-split path would reach bnfmt
# as fragments it cannot open, and bnfmt treats an unopenable file as empty (=
# "already formatted") -- so a stray path would be silently DROPPED and the check
# would pass over an unchecked file.  Also fail on an empty set (a broken checkout)
# rather than invoke bnfmt with no paths (whose usage error would be mis-read as an
# offending file named "usage").
if [ -z "$files" ]; then
	echo "bnfmt-format: found no .bn/.bni files under: $ROOTS" >&2
	exit 1
fi
if printf '%s\n' "$files" | grep -qE '[[:blank:]]|[][*?]'; then
	echo "bnfmt-format: a source path contains whitespace or a shell-glob character;" >&2
	echo "the batched word-split cannot pass it safely.  Offending path(s):" >&2
	printf '%s\n' "$files" | grep -nE '[[:blank:]]|[][*?]' >&2
	exit 1
fi

errfile="$(mktemp)" || { echo "bnfmt-format: mktemp failed" >&2; exit 1; }

# $files is a newline-separated list of colon-free, glob-free paths; the intended
# word-splitting passes them all as separate arguments (matching the old loop).
"$bnfmt" --check $files 2>"$errfile" >/dev/null
status=$?

if [ "$status" -eq 0 ]; then
	rm -f "$errfile"
	exit 0
fi

# Non-zero exit: at least one file is unformatted or unparseable.  Every stderr
# line is `<path>: <reason>`; the path is the text before the first `: ` (in-tree
# paths contain no colon).  Dedup -- a parse error can emit several lines per file.
unformatted="$(sed 's/: .*//' "$errfile" | LC_ALL=C sort -u | sed '/^$/d')"

if [ -z "$unformatted" ]; then
	# Non-zero exit but no `<path>:` lines to parse: an unexpected bnfmt failure.
	echo "bnfmt-format: bnfmt --check failed unexpectedly:" >&2
	cat "$errfile" >&2
	rm -f "$errfile"
	exit 1
fi
rm -f "$errfile"

echo "The following files are not bnfmt-formatted"
echo "(fix: scripts/build-bnfmt.sh -o /tmp/bnfmt && /tmp/bnfmt -w <file>):"
for f in $unformatted; do echo "  $f"; done
echo ""
echo "=== bnfmt-format failed ==="
exit 1
