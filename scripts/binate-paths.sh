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
#                [--target KEY] [--iface | --impl | --runtime] [--export]
#
#   --base DIR     The layout base.  Default: self-locate relative to this
#                  script — `<dir>/../lib` (a bundle's bin/) or `<dir>/..`
#                  (a source checkout's scripts/), whichever has an ifaces/.
#   --prepend PATH Prepend PATH to -I and -L (repeatable, order preserved).
#                  A project source root is `--prepend "$root"`.
#   --append PATH  Append PATH to -I and -L (repeatable) — a fallback for a
#                  package the base does not ship.
#   --target KEY   Select the per-target interface tree for KEY:
#                  ifaces/targets/KEY (e.g. pkg/builtins/build) prepended to
#                  -I.  KEY is a bnc --target key (e.g. arm32-linux), or
#                  "host"/omitted to auto-detect the host via uname.  Pass the
#                  SAME key you pass to `bnc --target` so the per-target tree
#                  matches the codegen layout.  Per-target package *impls* are
#                  now expressed via #[build(...)] in the common tree, not a
#                  separate impls/targets dir.  --runtime is unaffected.
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
TARGET=""            # bnc --target key, "host", or "" (auto-detect)

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
        --target)    TARGET="$2"; shift 2 ;;
        --target=*)  TARGET="${1#--target=}"; shift ;;
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

# Resolve the per-target metadata tree (pkg/builtins/build) into TARGET_DIR,
# the directory to prepend to -I (empty when none applies).  An explicit
# --target KEY must name an existing ifaces/targets/KEY (typos are a hard
# error); "host"/omitted auto-detects via uname and silently yields no tree
# on an unrecognised host (so a `pkg/builtins/build` import fails with a
# clear not-found rather than the wrong layout).
TARGET_DIR=""        # ifaces/targets/<key>, prepended to -I
TARGET_EXTRA=""      # newline-list of dirs prepended to BOTH -I and -L

# set_target_extras adds any per-target impl/interface search dirs BEYOND the
# generic ifaces/targets/<key> interface tree — prepended to both -I and -L so
# they win over the libc-host defaults (first-match-wins in the loader).
# arm32-baremetal needs its bootstrap impl (impls/core/baremetal — bootstrap is
# still path-selected, not #[build]-gated) and its semihost interface +
# link-file dir (runtime/baremetal_arm32) ahead of the default impls/core/libc.
# bnc no longer synthesizes these (it has no notion of a binate root);
# binate-paths is the single source of these paths.
set_target_extras() {
    case "$1" in
        arm32-baremetal)
            TARGET_EXTRA="$BASE/impls/core/baremetal
$BASE/runtime/baremetal_arm32" ;;
    esac
}

resolve_target() {
    rt_key="$TARGET"
    if [ -z "$rt_key" ] || [ "$rt_key" = host ]; then
        case "$(uname -s 2>/dev/null)" in
            Darwin) rt_os=darwin ;;
            Linux)  rt_os=linux ;;
            *)      rt_os="" ;;
        esac
        case "$(uname -m 2>/dev/null)" in
            arm64|aarch64) rt_arch=aarch64 ;;
            x86_64|amd64)  rt_arch=x86_64 ;;
            *)             rt_arch="" ;;
        esac
        [ -n "$rt_os" ] && [ -n "$rt_arch" ] || return 0
        rt_key="$rt_arch-$rt_os"
        [ -d "$BASE/ifaces/targets/$rt_key" ] && \
            TARGET_DIR="$BASE/ifaces/targets/$rt_key"
        set_target_extras "$rt_key"
        return 0
    fi
    if [ ! -d "$BASE/ifaces/targets/$rt_key" ]; then
        echo "$prog: unknown --target '$rt_key' (no $BASE/ifaces/targets/$rt_key)" >&2
        exit 1
    fi
    TARGET_DIR="$BASE/ifaces/targets/$rt_key"
    set_target_extras "$rt_key"
}
resolve_target

# join_dedup: one path per line on stdin -> ':'-joined on stdout, blank lines
# dropped and duplicates removed (first occurrence wins).
join_dedup() {
    awk 'NF && !seen[$0]++ { out = out (n++ ? ":" : "") $0 } END { print out }'
}

build_list() {   # $1 = iface | impl
    {
        printf '%s' "$PREPEND"
        if [ "$1" = iface ] && [ -n "$TARGET_DIR" ]; then
            printf '%s\n' "$TARGET_DIR"
        fi
        [ -n "$TARGET_EXTRA" ] && printf '%s\n' "$TARGET_EXTRA"
        printf '%s\n' "$BASE"
        if [ "$1" = iface ]; then
            printf '%s\n' "$BASE/ifaces/core"
            printf '%s\n' "$BASE/ifaces/stdlib"
        else
            printf '%s\n' "$BASE/impls/core/common"
            printf '%s\n' "$BASE/impls/core/libc"
            printf '%s\n' "$BASE/impls/stdlib/common"
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
