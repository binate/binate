#!/bin/sh
# Usage: ./conformance/run.sh bootstrap|selfhost|compiled [filter...]
# Runs conformance tests against the specified backend.
# Optional filters select tests by substring match (e.g. "040" or "recursive").

MODE="$1"
if [ -z "$MODE" ]; then
    echo "Usage: $0 bootstrap|selfhost|compiled [filter...]"
    exit 1
fi
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/../bootstrap" && pwd)"

passed=0
failed=0
skipped=0
failures=""

for bn in "$SCRIPT_DIR"/*.bn; do
    [ -f "$bn" ] || continue
    name="$(basename "$bn" .bn)"

    # Apply filters: if any filter args given, name must match at least one
    if [ $# -gt 0 ]; then
        match=0
        for f in "$@"; do
            case "$name" in *"$f"*) match=1; break;; esac
        done
        if [ "$match" -eq 0 ]; then
            skipped=$((skipped + 1))
            continue
        fi
    fi
    expected="$SCRIPT_DIR/${name}.expected"
    if [ ! -f "$expected" ]; then
        echo "SKIP: $name (no .expected file)"
        continue
    fi

    case "$MODE" in
        bootstrap)
            actual=$(cd "$BOOTSTRAP_DIR" && go run . "$bn" 2>&1) || true
            ;;
        selfhost)
            actual=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/main.bn" -- "$bn" 2>&1) || true
            ;;
        compiled)
            tmpbin="/tmp/binate_conform_${name}"
            compile_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/compile.bn" -- -o "$tmpbin" "$bn" 2>&1) || true
            if [ -x "$tmpbin" ]; then
                actual=$("$tmpbin" 2>&1) || true
            else
                actual="COMPILE_ERROR: $compile_out"
            fi
            rm -f "$tmpbin"
            ;;
        *)
            echo "Unknown mode: $MODE (use bootstrap|selfhost|compiled)"
            exit 1
            ;;
    esac

    expected_content="$(cat "$expected")"
    known_fail="$SCRIPT_DIR/${name}.xfail.${MODE}"
    if [ "$actual" = "$expected_content" ]; then
        echo "PASS: $name"
        passed=$((passed + 1))
    elif [ -f "$known_fail" ]; then
        echo "XFAIL: $name (known failure: $(cat "$known_fail"))"
        skipped=$((skipped + 1))
    else
        echo "FAIL: $name"
        echo "  expected: $(head -3 "$expected")"
        echo "  actual:   $(echo "$actual" | head -3)"
        failed=$((failed + 1))
        failures="$failures $name"
    fi
done

echo ""
echo "=== Summary: $passed passed, $failed failed, $skipped skipped ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
