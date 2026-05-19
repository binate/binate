#!/bin/sh
# Runner: boot — the BUILDER_VERSION binary runs -test directly.
# (BUILDER_VERSION currently names the bootstrap interpreter; once
# bnc-X.Y.Z releases ship, this runner will be renamed `builder`.)
#
# The `cd /` before the builder invocation matters: the bootstrap
# CLI's `-test` mode does `os.Stat(arg)` and routes a package-path
# argument that happens to match an existing directory under CWD
# (e.g. `pkg/ir` from the binate repo root) to its directory-test
# code path instead of the package-test code path.  Pre-fetcher we
# always ran with CWD = the bootstrap repo where no such directory
# existed; running from binate-dir hits the ambiguity.  `cd /`
# moves CWD to a directory that has no `pkg/...` entries.

runner_setup() {
    BOOT_BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
}

runner_test() {
    pkg="$1"
    (cd / && "$BOOT_BUILDER" -test -root "$BINATE_DIR" "$pkg")
}

runner_cleanup() {
    : # nothing to clean up
}
