#!/bin/sh
# Runner: boot-comp — the BUILDER_VERSION binary interprets bnc, which
# compiles tests to a binary.  (BUILDER_VERSION currently names the
# bootstrap interpreter.)

runner_setup() {
    BOOT_BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
}

runner_test() {
    pkg="$1"
    # bnc --test compiles and prints the test binary path. Per-pkg
    # build dir keeps intermediates (and the binary, which lives
    # under <build-dir> in --build-dir mode) isolated from concurrent
    # test runs.
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    # cd / so neither bootstrap nor bnc's CLI auto-routes the package
    # path arg to its directory-test mode via os.Stat lookup against
    # the caller's CWD; see runners/boot.sh for the full rationale.
    testbin=$(cd / && "$BOOT_BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --test -I "$BINATE_DIR" -L "$BINATE_DIR" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        rm -rf "$bdir"
        return 1
    fi
    "$testbin" 2>&1
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() {
    : # nothing to clean up
}
