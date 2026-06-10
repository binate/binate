#!/bin/sh
# binate-paths — emit the standard Binate package search paths for a layout
# base: the `-I` interface path, the `-L` implementation path, and the `bnc`
# `--runtime` C-runtime file.  This is the single source of truth for the
# formula that BUNDLE-HOWTO.md documents and that the build/test scripts and
# the examples repo consume; it ships in a release bundle as `bin/binate-paths`
# so consumers never re-derive the bundle layout by hand.
#
# A "layout base" is a directory holding `ifaces/`, `impls/`, and `runtime/`
# (a release bundle's `lib/`, or a source checkout's root — make-bundle.sh
# copies those trees verbatim, so the relative layout is identical).
#
# Usage:
#   binate-paths [--base DIR] [--prepend PATH]... [--append PATH]...
#                [--iface | --impl | --runtime] [--export]
#
#   --base DIR     The layout base.  Default: self-locate relative to this
#                  script — `<dir>/../lib` (a bundle's bin/) or `<dir>/..`
#                  (a source checkout's scripts/), whichever has an ifaces/.
#   --prepend PATH Prepend PATH to -I and -L (repeatable, order preserved).
#                  A project source root is `--prepend "$root"`.
#   --append PATH  Append PATH to -I and -L (repeatable) — a fallback for a
#                  package the base does not ship.
#   --iface        Print only the -I value.
#   --impl         Print only the -L value.
#   --runtime      Print only the --runtime file (ignores --prepend/--append).
#   (no selector)  Print an eval-able block setting BINATE_I/BINATE_L/BINATE_RT.
#   --export       With the eval block, prefix each line with `export `.
#
# Duplicate path entries collapse to their first occurrence, so a
# `--prepend "$base"` (e.g. a conformance compile_root that equals the base)
# does not double the entry.
#
# Examples:
#   I="$(binate-paths --iface --base "$LIB" --prepend "$ROOT")"
#   eval "$(binate-paths --base "$LIB")"      # sets BINATE_I/_L/_RT
set -e

prog=binate-paths

usage() {
    sed -n '2,/^set -e$/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//; /^set -e$/d'
}

abspath() { CDPATH= cd -- "$1" 2>/dev/null && pwd; }

BASE=""
SELECTOR=""          # iface | impl | runtime | "" (eval block)
EXPORT=""
PREPEND=""           # newline-terminated entries
APPEND=""            # newline-terminated entries

while [ $# -gt 0 ]; do
    case "$1" in
        --base)      BASE="$2"; shift 2 ;;
        --base=*)    BASE="${1#--base=}"; shift ;;
        --prepend)   PREPEND="$PREPEND$2
"; shift 2 ;;
        --prepend=*) PREPEND="$PREPEND${1#--prepend=}
"; shift ;;
        --append)    APPEND="$APPEND$2
"; shift 2 ;;
        --append=*)  APPEND="$APPEND${1#--append=}
"; shift ;;
        --iface)     SELECTOR=iface; shift ;;
        --impl)      SELECTOR=impl; shift ;;
        --runtime)   SELECTOR=runtime; shift ;;
        --export)    EXPORT=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "$prog: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Self-locate the base when not given: a bundle ships this as bin/binate-paths
# (base = ../lib); a checkout runs scripts/binate-paths.sh (base = ..).
if [ -z "$BASE" ]; then
    sd="$(abspath "$(dirname -- "$0")")"
    if [ -d "$sd/../lib/ifaces" ]; then
        BASE="$(abspath "$sd/../lib")"
    elif [ -d "$sd/../ifaces" ]; then
        BASE="$(abspath "$sd/..")"
    else
        echo "$prog: cannot locate a layout base (pass --base DIR)" >&2
        exit 1
    fi
fi
[ -d "$BASE/ifaces" ] || {
    echo "$prog: base '$BASE' has no ifaces/ (not a layout base)" >&2; exit 1; }

# join_dedup: one path per line on stdin -> ':'-joined on stdout, blank lines
# dropped and duplicates removed (first occurrence wins).
join_dedup() {
    awk 'NF && !seen[$0]++ { out = out (n++ ? ":" : "") $0 } END { print out }'
}

build_list() {   # $1 = iface | impl
    {
        printf '%s' "$PREPEND"
        printf '%s\n' "$BASE"
        if [ "$1" = iface ]; then
            printf '%s\n' "$BASE/ifaces/core"
            printf '%s\n' "$BASE/ifaces/stdlib"
        else
            printf '%s\n' "$BASE/impls/core/common"
            printf '%s\n' "$BASE/impls/core/libc"
            printf '%s\n' "$BASE/impls/stdlib/common"
            printf '%s\n' "$BASE/impls/stdlib/libc"
        fi
        printf '%s' "$APPEND"
    } | join_dedup
}

RT="$BASE/runtime/binate_runtime.c"

case "$SELECTOR" in
    iface)   build_list iface ;;
    impl)    build_list impl ;;
    runtime) printf '%s\n' "$RT" ;;
    *)
        I="$(build_list iface)"
        L="$(build_list impl)"
        pfx=""
        [ -n "$EXPORT" ] && pfx="export "
        printf "%sBINATE_I='%s'\n" "$pfx" "$I"
        printf "%sBINATE_L='%s'\n" "$pfx" "$L"
        printf "%sBINATE_RT='%s'\n" "$pfx" "$RT"
        ;;
esac
