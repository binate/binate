#!/bin/sh
# Usage: ./conformance/run.sh bootstrap|selfhost|compiled
# Runs conformance tests against the specified backend.

MODE="$1"
if [ -z "$MODE" ]; then
    echo "Usage: $0 bootstrap|selfhost|compiled"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/../bootstrap" && pwd)"

passed=0
failed=0
failures=""

for bn in "$SCRIPT_DIR"/*.bn; do
    [ -f "$bn" ] || continue
    name="$(basename "$bn" .bn)"
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
            tmpll="/tmp/binate_conform_${name}.ll"
            tmpbin="/tmp/binate_conform_${name}"
            actual=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/compile.bn" -- "$bn" > "$tmpll" 2>&1) || true
            if [ -s "$tmpll" ]; then
                if clang -w -o "$tmpbin" "$tmpll" "$BINATE_DIR/runtime/binate_runtime.c" 2>/dev/null; then
                    actual=$("$tmpbin" 2>&1) || true
                else
                    actual="COMPILE_ERROR: clang failed"
                fi
            else
                actual="COMPILE_ERROR: no LLVM IR produced: $actual"
            fi
            rm -f "$tmpll" "$tmpbin"
            ;;
        *)
            echo "Unknown mode: $MODE (use bootstrap|selfhost|compiled)"
            exit 1
            ;;
    esac

    expected_content="$(cat "$expected")"
    if [ "$actual" = "$expected_content" ]; then
        echo "PASS: $name"
        passed=$((passed + 1))
    else
        echo "FAIL: $name"
        echo "  expected: $(head -3 "$expected")"
        echo "  actual:   $(echo "$actual" | head -3)"
        failed=$((failed + 1))
        failures="$failures $name"
    fi
done

echo ""
echo "=== Summary: $passed passed, $failed failed ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
