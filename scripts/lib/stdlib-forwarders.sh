# Shared helper for the hygiene checks that reason about stdlib compat forwarders.
# Source this file; it only defines functions.
#
# A PURE FORWARDER (spec §16.5.2: `pkg.expose`, `pkg.expose.dep`) is a package whose
# .bni holds nothing but its package clause and `expose "P"` declarations — no
# declarations of its own — and which has no implementation directory (spec §16.1: a
# directory of .bn files; one holding only subpackage directories is not).  It emits no
# code, storage, initializer, or reflection descriptor entries of its own: every
# member a consumer reaches through it IS P's entity.  The stdlib uses pure
# forwarders only as temporary compat aliases, left at a package's old path when the
# package moves, so existing importers keep resolving while they migrate.

# is_pure_forwarder <binate-dir> <bni-path> <pkg-path>: succeed iff the stdlib package
# <pkg-path> (e.g. pkg/std/vec), whose interface file is <bni-path>, is a pure
# forwarder.  Any top-level declaration (an annotation always precedes one, so the
# declaration keywords suffice) or a .bn file directly in impls/stdlib/<pkg-path>/ (the
# loader's test for an implementation directory, which skips dot-files) makes the
# package a real one (possibly an aggregator that also exposes others).
is_pure_forwarder() {
    grep -q '^expose "' "$2" || return 1
    if grep -Eq '^(import|type|var|const|func|interface|impl)([[:space:](]|$)' "$2"; then
        return 1
    fi
    if find "$1/impls/stdlib/$3" -maxdepth 1 -type f -name '*.bn' ! -name '.*' 2>/dev/null \
        | grep -q .; then
        return 1
    fi
    return 0
}
