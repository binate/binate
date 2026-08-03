#!/bin/sh
# Usage: ./perf/summarize.sh <results-dir>
#
# Aggregates per-mode perf-test output files (`<mode>.txt`) from
# <results-dir> into markdown tables on stdout: one table each for the
# TOTAL (compile+run), COMPILE, and RUN timings.  So the summary carries
# both the end-to-end cost (compile+run — the apples-to-apples against an
# interpreted mode's run, now that compiled fixtures pull in real stdlib)
# AND the separate compile / run breakdown (run-only stays the useful
# comparison among compiled modes).  Each table is a test×mode grid; a
# cell shows the timing for a PASS, the status (COMPILE_ERROR / FAIL / SKIP)
# for a non-PASS, or an em dash when the test is absent for that mode.
#
# Used by the perf-tests CI workflow's summary job. The output is fed into
# $GITHUB_STEP_SUMMARY so the workflow run page renders it inline.

set -e

RESULTS_DIR="${1:-perf-out}"
if [ ! -d "$RESULTS_DIR" ]; then
    echo "summarize.sh: no results dir at $RESULTS_DIR" >&2
    exit 1
fi

# Modes are the basenames of the `.txt` files, sorted.
modes=$(ls "$RESULTS_DIR" | grep '\.txt$' | sed 's/\.txt$//' | sort)
if [ -z "$modes" ]; then
    echo "summarize.sh: no <mode>.txt files in $RESULTS_DIR" >&2
    exit 1
fi

# Tests are the union of test names across all modes, in lexical order.
# Each results file has lines of the form:
#   <mode>  <name>  compile=<s>  run=<s>  total=<s>  [STATUS]
# (a COMPILE_ERROR line has only compile=; a SKIP line has neither.)
all_tests=$(awk '
    /^[a-zA-Z0-9_-]+ +[0-9]+_/ { print $2 }
' "$RESULTS_DIR"/*.txt | sort -u)

# emit_table <heading> <field>
# Renders a test×mode markdown table whose cells are the given field
# (compile / run / total).  A PASS cell shows the timing; a non-PASS cell
# shows its status; a test absent for a mode shows an em dash.
emit_table() {
    heading="$1"
    field="$2"
    printf '### %s\n\n' "$heading"
    printf '| test |'
    for m in $modes; do printf ' %s |' "$m"; done
    printf '\n'
    printf '| --- |'
    for m in $modes; do printf ' --- |'; done
    printf '\n'
    for t in $all_tests; do
        printf '| %s |' "$t"
        for m in $modes; do
            cell=$(awk -v t="$t" -v field="$field" '
                $2 == t {
                    status = ""
                    if (match($0, /\[[A-Z_]+\]/)) {
                        status = substr($0, RSTART + 1, RLENGTH - 2)
                    } else if ($3 == "SKIP") {
                        # A skip line is `<mode> <name> SKIP (reason)` — no
                        # bracketed status and no timing fields.
                        status = "SKIP"
                    }
                    val = ""
                    if (match($0, field "=[^ ]+")) {
                        val = substr($0, RSTART + length(field) + 1,
                                     RLENGTH - length(field) - 1)
                    }
                    if (status == "PASS") { print val }
                    else if (status == "") { print "?" }
                    else { print status }
                    exit
                }
            ' "$RESULTS_DIR/$m.txt")
            if [ -z "$cell" ]; then
                # Test entirely absent from this mode's results.
                cell="—"
            fi
            printf ' %s |' "$cell"
        done
        printf '\n'
    done
    printf '\n'
}

{
    printf '## Perf summary\n\n'
    printf 'Timings in seconds. **Total** = compile + run (end-to-end, comparable to an '
    printf 'interpreted-mode run); **Compile** and **Run** are the separate breakdown.\n\n'
    emit_table 'Total (compile + run)' total
    emit_table 'Compile' compile
    emit_table 'Run' run

    # Per-mode trailing notes: the `=== <mode>: N failure(s)` tail line, if
    # present, so the summary surfaces failures.
    failures_shown=0
    for m in $modes; do
        tail=$(grep '^=== ' "$RESULTS_DIR/$m.txt" 2>/dev/null || true)
        if [ -n "$tail" ]; then
            if [ "$failures_shown" -eq 0 ]; then
                printf '### Failures\n\n'
                failures_shown=1
            fi
            printf -- '- **%s**: %s\n' "$m" "$tail"
        fi
    done
} | cat
