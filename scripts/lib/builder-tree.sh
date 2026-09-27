# Shared helper: compute the BUILDER-compiled tree.  Source this file; it only
# defines functions.
#
# The BUILDER-compiled tree is cmd/bnc plus every package in its transitive import
# closure whose source the gen1 build (scripts/lib/build-compilers.sh) takes from
# THIS tree.  gen1 searches the tree root and ifaces/toolchain first and then the
# pinned BUILDER's bundle; the tree's own stdlib (ifaces/stdlib, impls/stdlib) is not
# on that search path at all.  So an import is tree-sourced iff <tree>/<pkg>.bni,
# <tree>/ifaces/toolchain/<pkg>.bni or a <tree>/<pkg>/ directory exists, and every
# tree-sourced package must stay compilable by the BUILDER against its own bundle.
# A bundle-sourced package (the stdlib, pkg/builtins) ends the walk: its imports
# resolve inside the bundle.
#
# Test files are left out of the walk (the BUILDER never compiles tests).  Files
# gated by #[build] are followed for every target, so the set can only
# over-approximate what one gen1 build compiles.

# builder_tree_packages <binate-dir>: print the BUILDER-compiled tree's package
# paths (cmd/bnc, pkg/binate/...), one per line, sorted.
builder_tree_packages() {
    _bt_root=$1
    _bt_seen=" "
    _bt_queue="cmd/bnc"
    while [ -n "$_bt_queue" ]; do
        # shellcheck disable=SC2086  # word-splitting the space-separated queue
        set -- $_bt_queue
        _bt_cur=$1
        shift
        _bt_queue="$*"
        case "$_bt_seen" in *" $_bt_cur "*) continue ;; esac
        _bt_seen="$_bt_seen$_bt_cur "
        for _bt_imp in $(_bt_pkg_files "$_bt_root" "$_bt_cur" | _bt_imports | sort -u); do
            _bt_tree_sourced "$_bt_root" "$_bt_imp" || continue
            case "$_bt_seen" in *" $_bt_imp "*) ;; *) _bt_queue="$_bt_queue $_bt_imp" ;; esac
        done
    done
    # shellcheck disable=SC2086
    printf '%s\n' $_bt_seen | sort
}

# _bt_pkg_files <binate-dir> <pkg>: the package's interface file(s) and non-test
# implementation files.
_bt_pkg_files() {
    [ -f "$1/$2.bni" ] && echo "$1/$2.bni"
    [ -f "$1/ifaces/toolchain/$2.bni" ] && echo "$1/ifaces/toolchain/$2.bni"
    if [ -d "$1/$2" ]; then
        find "$1/$2" -maxdepth 1 -type f -name '*.bn' ! -name '*_test.bn'
    fi
}

# _bt_tree_sourced <binate-dir> <pkg>: succeed iff gen1 resolves <pkg> from the tree.
_bt_tree_sourced() {
    [ -f "$1/$2.bni" ] || [ -f "$1/ifaces/toolchain/$2.bni" ] || [ -d "$1/$2" ]
}

# _bt_imports: read file paths on stdin and print every "pkg/..." import in them,
# handling the single-line `import "pkg/X"`, aliased `import a "pkg/X"`, and grouped
# `import ( ... )` forms (the same extraction as scripts/hygiene/pkg-tiers.sh).
_bt_imports() {
    xargs awk '
        FNR == 1 { in_group = 0 }
        /^import[ \t]*\(/ { in_group = 1; next }
        in_group && /^\)/ { in_group = 0; next }
        in_group {
            if (match($0, /"pkg\/[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2)
            next
        }
        /^import[ \t]/ {
            if (match($0, /"pkg\/[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2)
        }
    '
}
