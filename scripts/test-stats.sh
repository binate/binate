#!/bin/sh
# Usage: ./scripts/test-stats.sh [mode...]
#
# Reports the number of tests and xfails for each mode, for both
# conformance and unit tests. If no modes are specified, uses every
# mode listed in scripts/modesets/all.
#
# Counts are computed statically (no tests are actually run).
#
# Conformance: counts single-file tests (*.bn directly in conformance/)
# and multi-file tests (NNN_*/ directories). Xfails counted from
# <name>.xfail.<mode> files.
#
# Unit tests: counts packages (directories containing *_test.bn) under
# pkg/ and cmd/. Xfails counted from <pkg-with-dashes>.xfail.<mode>
# files in scripts/unittest/.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFORMANCE_DIR="$BINATE_DIR/conformance"
UNITTEST_DIR="$SCRIPT_DIR/unittest"

# Determine modes
if [ $# -gt 0 ]; then
    MODES="$*"
else
    MODES=$(grep -v '^#' "$SCRIPT_DIR/modesets/all" | grep -v '^$' | tr '\n' ' ')
fi

# Count conformance tests (static — doesn't run anything).
# Single-file: *.bn directly in conformance/ with a .expected or .error sibling.
# Multi-file: NNN_*/ directories.
conformance_total=0
for bn in "$CONFORMANCE_DIR"/[0-9][0-9][0-9]_*.bn; do
    [ -f "$bn" ] || continue
    name="$(basename "$bn" .bn)"
    if [ -f "$CONFORMANCE_DIR/${name}.expected" ] || \
       [ -f "$CONFORMANCE_DIR/${name}.error" ]; then
        conformance_total=$((conformance_total + 1))
    fi
done
for dir in "$CONFORMANCE_DIR"/[0-9][0-9][0-9]_*/; do
    [ -d "$dir" ] || continue
    conformance_total=$((conformance_total + 1))
done

# Count unit-test packages: directories with any *_test.bn file.
unittest_total=0
for dir in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" -name '*_test.bn' \
        2>/dev/null | xargs -n1 dirname | sort -u); do
    unittest_total=$((unittest_total + 1))
done

# Table header
printf "%-24s %12s %8s  %12s %8s\n" \
    "Mode" "Conformance" "(xfail)" "Unit tests" "(xfail)"
printf "%-24s %12s %8s  %12s %8s\n" \
    "----" "-----------" "-------" "----------" "-------"

for mode in $MODES; do
    # Conformance xfails: <name>.xfail.<mode>
    conf_xfail=$(ls "$CONFORMANCE_DIR"/*.xfail."$mode" 2>/dev/null | wc -l | tr -d ' ')

    # Unit-test xfails: <pkg-dashed>.xfail.<mode>
    unit_xfail=$(ls "$UNITTEST_DIR"/*.xfail."$mode" 2>/dev/null | wc -l | tr -d ' ')

    printf "%-24s %12s %8s  %12s %8s\n" \
        "$mode" "$conformance_total" "$conf_xfail" "$unittest_total" "$unit_xfail"
done
