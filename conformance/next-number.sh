#!/bin/sh
# Usage: ./conformance/next-number.sh [--gap]
#
# Print the next free conformance test number (an NNN prefix, zero-padded to
# at least 3 digits; naturally 4 digits once the suite passes 999).
#
# A "test" is either a single-file test (NNN_<name>.bn with a sibling
# .expected or .error) or a multi-file test (NNN_<name>/ directory).
# Build artifacts and other strays in conformance/ are ignored — only
# those two shapes count, matching scripts/hygiene/conformance-test-
# numbers.sh.
#
# Policy:
#   default  next number after the current maximum.  Monotonic; never
#            reuses a number left by a deleted/retired test.
#   --gap    the lowest unused number instead (compact numbering — reuses
#            gaps).  Use when you deliberately want to fill a hole.
#
# Exit code: 1 on error (e.g. numbers exhausted past 9999), 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFORMANCE_DIR="$SCRIPT_DIR"

MODE="max"
if [ "$1" = "--gap" ]; then
    MODE="gap"
elif [ -n "$1" ]; then
    echo "next-number.sh: unknown argument: $1" >&2
    echo "usage: $0 [--gap]" >&2
    exit 1
fi

# Collect the set of in-use numbers (one per line), sorted & unique.
used_numbers() {
    {
        for bn in "$CONFORMANCE_DIR"/[0-9][0-9][0-9]*_*.bn; do
            [ -f "$bn" ] || continue
            name="$(basename "$bn" .bn)"
            if [ -f "$CONFORMANCE_DIR/${name}.expected" ] || \
               [ -f "$CONFORMANCE_DIR/${name}.error" ]; then
                echo "${name%%_*}"
            fi
        done
        for dir in "$CONFORMANCE_DIR"/[0-9][0-9][0-9]*_*/; do
            [ -d "$dir" ] || continue
            name="$(basename "$dir")"
            echo "${name%%_*}"
        done
    } | sort -nu   # numeric: 1000 must sort ABOVE 999, not lexically below it
}

NUMS="$(used_numbers)"
if [ -z "$NUMS" ]; then
    echo "001"
    exit 0
fi

# Strip leading zeros for arithmetic (guard against octal interpretation).
dec() { echo "$1" | sed 's/^0*//; s/^$/0/'; }

if [ "$MODE" = "max" ]; then
    max="$(echo "$NUMS" | tail -1)"
    next=$(( $(dec "$max") + 1 ))
else
    # Lowest unused number, scanning up from 1.
    next=1
    for n in $NUMS; do
        d="$(dec "$n")"
        if [ "$d" -gt "$next" ]; then
            break
        fi
        if [ "$d" -eq "$next" ]; then
            next=$((next + 1))
        fi
    done
fi

if [ "$next" -gt 9999 ]; then
    echo "next-number.sh: no free number available (next would be $next)" >&2
    exit 1
fi

# %03d gives a minimum width of 3 (so 42 -> 042) while letting 4-digit numbers
# print at their natural width (1000 -> 1000).
printf "%03d\n" "$next"
