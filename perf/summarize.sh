#!/bin/sh
# Usage: ./perf/summarize.sh <results-dir>
#
# Aggregates per-mode perf-test output files (`<mode>.txt`) from
# <results-dir> into a single markdown table on stdout. Each row is
# a test; each column is a mode. Cell shows the `run=` timing, or
# `SKIP` / `COMPILE_ERROR` / `FAIL` for non-OK statuses.
#
# Used by the perf-tests CI workflow's summary job. The output is
# fed into $GITHUB_STEP_SUMMARY so the workflow run page renders it
# inline.

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

# Tests are the union of test names across all modes, in lexical
# order. Each results file has lines of the form:
#   <mode>  <name>  compile=<s>  run=<s>  [STATUS]
# (status is PASS / FAIL / COMPILE_ERROR; skipped tests show up
# differently — see the `[SKIP]` arm below).
all_tests=$(awk '
    /^[a-zA-Z0-9_-]+ +[0-9]+_/ { print $2 }
' "$RESULTS_DIR"/*.txt | sort -u)

# Build a header. The first column is the test name; one column per mode.
{
    printf '## Perf summary\n\n'
    printf '| test |'
    for m in $modes; do printf ' %s |' "$m"; done
    printf '\n'
    printf '| --- |'
    for m in $modes; do printf ' --- |'; done
    printf '\n'

    # Row per test.
    for t in $all_tests; do
        printf '| %s |' "$t"
        for m in $modes; do
            cell=$(awk -v t="$t" '
                $2 == t {
                    # Extract status (last bracketed token) and run= field.
                    line = $0
                    # Strip everything after the leading "compile=" prefix into fields.
                    # Layout: <mode> <name> compile=<s> run=<s> [STATUS]
                    status = ""
                    if (match(line, /\[[A-Z_]+\]/)) {
                        status = substr(line, RSTART+1, RLENGTH-2)
                    }
                    runs = ""
                    if (match(line, /run=[^ ]+/)) {
                        runs = substr(line, RSTART+4, RLENGTH-4)
                    }
                    if (status == "PASS") { print runs }
                    else if (status == "") { print "?" }
                    else { print status " " runs }
                    exit
                }
            ' "$RESULTS_DIR/$m.txt")
            if [ -z "$cell" ]; then
                # Mode-specific skip (NNN_name.skip.<mode> file)
                # or otherwise absent — show a dash.
                cell="—"
            fi
            printf ' %s |' "$cell"
        done
        printf '\n'
    done

    printf '\n'

    # Per-mode trailing notes: include the `=== <mode>: N failure(s)`
    # tail line if present, so the summary surfaces failures.
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
