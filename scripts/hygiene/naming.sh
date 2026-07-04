#!/bin/sh
# Usage: ./scripts/hygiene/naming.sh
#
# Checks the naming convention from explorations/code-hygiene-check.md §6:
#   Exported symbols (in `.bni`) must start with an uppercase letter.
# Names starting with a lowercase letter or `_` are flagged; both
# patterns are reserved for non-exported / compiler-internal use.
#
# Targets every top-level `func`, `type`, `const`, and enumerator inside
# `const ( ... )` groups in `.bni` files under pkg/.
#
# Some intentional exceptions (C-binding bridges, range sentinels) are
# listed in scripts/hygiene/naming.whitelist as `<path>:<identifier>`
# entries.
#
# Limitations (intentional, first approximation):
# - .bn files are not checked; the rule there is "non-exported names
#   start lowercase" but the cross-file check requires reading the
#   matching .bni, which is more work.
# - `var` declarations are not checked (none currently exist in .bni).
#
# Exit code: 1 if any violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WHITELIST="$SCRIPT_DIR/naming.whitelist"

violations=0

for f in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/ifaces" "$BINATE_DIR/impls" -name '*.bni' -not -path '*/testdata/*' 2>/dev/null | sort); do
    rel=${f#"$BINATE_DIR"/}
    out=$(awk -v rel="$rel" '
        function name_of_func(line,    s) {
            s = line; sub(/^func /, "", s); sub(/[^A-Za-z0-9_].*$/, "", s); return s
        }
        function name_of_type(line,    s) {
            s = line; sub(/^type /, "", s); sub(/[^A-Za-z0-9_].*$/, "", s); return s
        }
        function name_of_const_single(line,    s) {
            s = line; sub(/^const /, "", s); sub(/[^A-Za-z0-9_].*$/, "", s); return s
        }
        function name_of_enumerator(line,    s) {
            s = line; sub(/^[\t ]+/, "", s); sub(/[^A-Za-z0-9_].*$/, "", s); return s
        }
        function flag(kind, name) {
            printf("%s:%d: lowercase %s name in .bni: %s\n", rel, FNR, kind, name)
            e++
        }
        /^func [a-z_]/  {
            name = name_of_func($0)
            if (name != "") flag("func", name)
            next
        }
        /^type [a-z_]/  {
            name = name_of_type($0)
            if (name != "") flag("type", name)
            next
        }
        /^const \(/    { in_grp = 1; next }
        in_grp && /^\)/ { in_grp = 0; next }
        /^const [a-z_]/ {
            name = name_of_const_single($0)
            if (name != "") flag("const", name)
            next
        }
        in_grp && /^[\t ]+[a-z_]/ {
            name = name_of_enumerator($0)
            if (name != "") flag("const enumerator", name)
        }
        END { exit e > 0 ? 1 : 0 }
    ' "$f")

    if [ -z "$out" ]; then continue; fi

    # Apply whitelist: filter out lines whose <path>:<name> is whitelisted.
    if [ -f "$WHITELIST" ]; then
        # Unique-per-run scratch file (mktemp, not a PID-based name) — the
        # `while` runs in a pipe subshell, so its filtered output is captured
        # via a file; that file must not collide with a concurrent run's.
        naming_tmp="$(mktemp "${TMPDIR:-/tmp}/naming-out.XXXXXX")"
        echo "$out" | while IFS= read -r line; do
            # Extract identifier: last word of the line.
            name=$(echo "$line" | awk '{print $NF}')
            key="$rel:$name"
            if ! grep -qxF "$key" "$WHITELIST" 2>/dev/null; then
                echo "$line"
            fi
        done > "$naming_tmp"
        out=$(cat "$naming_tmp")
        rm -f "$naming_tmp"
    fi

    if [ -n "$out" ]; then
        echo "$out"
        n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
        violations=$((violations + n))
    fi
done

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "=== $violations naming violation(s) ==="
    exit 1
fi
