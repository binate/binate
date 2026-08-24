#!/bin/sh
# Runner: builder-comp-comp-int — Gen1-compiled bytecode VM runs --test natively.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_interp "$GEN1_COMPILER"; }

runner_test() {
    pkg="$1"
    _I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
    _L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
    # SKIP_FILTER (per-test .skip) and TEST_SHARD_* (per-test .split sharding) are
    # set by run.sh; both are forwarded to bni --test as extra flags (word-split
    # intended — they carry no spaces).
    extra=""
    [ -n "$SKIP_FILTER" ] && extra="$extra --skip $SKIP_FILTER"
    [ -n "$TEST_SHARD_COUNT" ] && extra="$extra --shard-index $TEST_SHARD_IDX --shard-count $TEST_SHARD_COUNT"
    # shellcheck disable=SC2086
    "$COMPILED_INTERP" --test "$pkg" $extra -I "$_I" -L "$_L"
}

runner_cleanup() { cleanup_compilers; }
