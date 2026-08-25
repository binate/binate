#!/bin/sh
# Runner: builder-comp-int-int — Compiled bni interprets cmd/bni, which runs --test via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_test() {
    pkg="$1"
    _I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
    _L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
    # SKIP_FILTER (per-test .skip) and TEST_SHARD_* (per-test .split sharding) are
    # set by run.sh; both are forwarded to cmd/bni --test as extra flags (word-split
    # intended — they carry no spaces).
    extra=""
    [ -n "$SKIP_FILTER" ] && extra="$extra --skip $SKIP_FILTER"
    [ -n "$TEST_SHARD_COUNT" ] && extra="$extra --shard-index $TEST_SHARD_IDX --shard-count $TEST_SHARD_COUNT"
    # shellcheck disable=SC2086
    "$COMPILED_INTERP" -I "$_I" -L "$_L" -main-dir "$BINATE_DIR/cmd/bni" -- \
        --test "$pkg" $extra -I "$_I" -L "$_L"
}

# runner_test_batch runs MANY packages in ONE cmd/bni invocation, so cmd/bni
# loads + lowers its shared dependency tree ONCE rather than re-doing it per
# package — the double-VM lane's dominant per-shard floor.  $1 is the
# space-separated package list; $2 is a package-qualified --skip spec
# (pkg:pattern,… — see bni's skipMatchesAny) or empty.  Sharding applies to the
# COMBINED test set via --shard-index/--shard-count (even load across shards).
# cmd/bni emits a per-package `ok`/`FAIL`/`?` line, which run.sh parses.
runner_test_batch() {
    pkgs="$1"
    skips="$2"
    _I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
    _L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
    tflags=""
    for p in $pkgs; do tflags="$tflags --test $p"; done
    [ -n "$skips" ] && tflags="$tflags --skip $skips"
    [ "$SHARD_COUNT" -gt 0 ] && tflags="$tflags --shard-index $SHARD_IDX --shard-count $SHARD_COUNT"
    # shellcheck disable=SC2086
    "$COMPILED_INTERP" -I "$_I" -L "$_L" -main-dir "$BINATE_DIR/cmd/bni" -- \
        $tflags -I "$_I" -L "$_L"
}

runner_cleanup() { cleanup_compilers; }
