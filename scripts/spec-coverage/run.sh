#!/bin/sh
# Spec-conformance coverage report.
#
# Cross-references the spec's declared rule-IDs (the vendored `rule-ids.txt`
# snapshot, exported from docs by docs/scripts/extract-rule-ids.py) against the
# `.rules` sidecars of the spec tests under conformance/spec/, and reports the
# bidirectional coverage findings (plan-spec-tests.md §5):
#
#   - per-chapter and overall coverage %  (covered denominator / total)
#   - GAPS:     denominator rule-IDs with no spec test            (informational)
#   - DANGLING: a .rules sidecar cites a rule-ID the spec doesn't declare (error)
#   - UNTAGGED: a spec test with no .rules sidecar                (error)
#
# The "denominator" is the positive + constraint + constraint-candidate buckets;
# framework + untestable rules are excluded (they are not test targets).
#
# This is the STATIC half: it does not run the tests. Per-mode pass/xfail status
# (§5.3) and the Annex-C JSON (§5.5) are folded in by a later `--run` increment.
#
# Usage:
#   scripts/spec-coverage/run.sh [-v] [--rule-ids PATH] [--json PATH] [--chapter NN]
#
#   -v             list the gap rule-IDs (not just the count)
#   --rule-ids P   read the rule-ID inventory from P (default: vendored copy)
#   --json P       also write the machine-readable coverage JSON to P
#   --chapter NN   restrict the report to chapter files matching NN (e.g. 13)
#
# Exit status: nonzero if there are DANGLING citations or UNTAGGED tests (both
# authoring errors); GAPS alone do not fail (driving them down is Phase B's job).

VERBOSE=0
JSON_OUT=""
CHAPTER=""

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
SPEC_DIR="$REPO_ROOT/conformance/spec"
RULE_IDS="$SCRIPT_DIR/rule-ids.txt"
# Best-effort staleness check against a sibling docs checkout, if present.
DOCS_RULE_IDS="${BINATE_DOCS:-$REPO_ROOT/../docs}/spec/rule-ids.txt"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose)  VERBOSE=1; shift ;;
        --rule-ids)    RULE_IDS="$2"; shift 2 ;;
        --json)        JSON_OUT="$2"; shift 2 ;;
        --chapter)     CHAPTER="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "spec-coverage: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ ! -f "$RULE_IDS" ]; then
    echo "spec-coverage: rule-ID inventory not found: $RULE_IDS" >&2
    echo "  (regenerate with docs/scripts/extract-rule-ids.py and vendor the copy)" >&2
    exit 2
fi
if [ -f "$DOCS_RULE_IDS" ] && ! cmp -s "$RULE_IDS" "$DOCS_RULE_IDS"; then
    echo "spec-coverage: warning: vendored rule-ids.txt differs from docs" >&2
    echo "  ($DOCS_RULE_IDS) — refresh: python3 docs/scripts/extract-rule-ids.py && cp it here" >&2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/spec-cov.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# A chapter-file filter for the rule inventory (col 3 = source file).
chap_match='.'
[ -n "$CHAPTER" ] && chap_match="^$CHAPTER"

# --- declared / denominator sets (id<TAB>bucket<TAB>source), from the inventory.
grep -v '^#' "$RULE_IDS" | awk -F'\t' -v c="$chap_match" \
    'NF>=3 && $3 ~ c {print $1"\t"$2"\t"$3}' > "$TMP/decl"
awk -F'\t' '{print $1}' "$TMP/decl" | sort -u > "$TMP/declared"
# id<TAB>source for the denominator buckets only.
awk -F'\t' '$2=="positive"||$2=="constraint"||$2=="constraint-candidate" \
    {print $1"\t"$3}' "$TMP/decl" | sort -u > "$TMP/denom_src"
awk -F'\t' '{print $1}' "$TMP/denom_src" > "$TMP/denominator"

# --- cited set: every rule-ID named in a .rules sidecar (one per line; '#'
# comments and blank lines ignored). Restrict to the chapter dir when filtering.
find_root="$SPEC_DIR"
[ -n "$CHAPTER" ] && find_root=$(ls -d "$SPEC_DIR/$CHAPTER"* 2>/dev/null | head -1)
: > "$TMP/cited"
if [ -n "$find_root" ] && [ -d "$find_root" ]; then
    find "$find_root" -name '*.rules' -type f 2>/dev/null | while IFS= read -r f; do
        sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$f"
    done | grep -v '^$' | sort -u > "$TMP/cited"
fi

# --- the four set findings.
comm -23 "$TMP/cited" "$TMP/declared"   > "$TMP/dangling"     # cited, not declared
comm -23 "$TMP/denominator" "$TMP/cited" > "$TMP/gap"         # denom, not cited
n_declared=$(wc -l < "$TMP/declared" | tr -d ' ')
n_denom=$(wc -l < "$TMP/denominator" | tr -d ' ')
n_cited=$(wc -l < "$TMP/cited" | tr -d ' ')
n_dangling=$(wc -l < "$TMP/dangling" | tr -d ' ')
n_gap=$(wc -l < "$TMP/gap" | tr -d ' ')
n_covered=$((n_denom - n_gap))

# --- enumerate spec tests + the ones missing a .rules sidecar (UNTAGGED).
# A test is a NNN_*.bn at chapter level, or a NNN_*/ multi-package dir (main.bn).
: > "$TMP/tests"; : > "$TMP/untagged"
if [ -n "$find_root" ] && [ -d "$find_root" ]; then
    # single-file tests: chapter/NNN_name.bn  -> sidecar chapter/NNN_name.rules
    find "$find_root" -type f -name '*.bn' ! -path '*/pkg/*' 2>/dev/null \
        | grep -E '/[0-9]+_[^/]*\.bn$' | while IFS= read -r bn; do
            case "$bn" in */main.bn) continue ;; esac   # multi-pkg handled below
            echo "$bn" >> "$TMP/tests"
            [ -f "${bn%.bn}.rules" ] || echo "${bn%.bn}.bn" >> "$TMP/untagged"
        done
    # multi-package tests: chapter/NNN_name/main.bn -> sidecar .../NNN_name.rules
    find "$find_root" -type f -name 'main.bn' 2>/dev/null | while IFS= read -r m; do
        d=$(dirname "$m"); base=$(basename "$d")
        echo "$d/" >> "$TMP/tests"
        [ -f "$d/$base.rules" ] || echo "$d/" >> "$TMP/untagged"
    done
fi
n_tests=$(wc -l < "$TMP/tests" | tr -d ' ')
n_untagged=$(wc -l < "$TMP/untagged" | tr -d ' ')

pct() { # covered total -> "NN%" (or "—" when total is 0)
    if [ "$2" -eq 0 ]; then echo "—"; else echo "$(( $1 * 100 / $2 ))%"; fi
}

# --- report.
echo "Spec coverage (static — citations <-> rule-IDs; tests not run)"
echo "  inventory: $n_declared declared, $n_denom in denominator${CHAPTER:+ (chapter $CHAPTER)}"
echo "  spec tests: $n_tests found, $((n_tests - n_untagged)) with a .rules sidecar"
echo
echo "Per-chapter coverage (covered / denominator):"
# covered-per-source: mark a denom id covered iff it appears in cited.
awk -F'\t' '
    FNR==NR { tot[$2]++; src[$1]=$2; next }
    ($1 in src) { cov[src[$1]]++ }
    END { for (s in tot) printf "%s\t%d\t%d\n", s, cov[s]+0, tot[s] }
' "$TMP/denom_src" "$TMP/cited" | sort | while IFS="$(printf '\t')" read -r s c t; do
    printf '  %-42s %4d / %-4d %s\n' "$s" "$c" "$t" "$(pct "$c" "$t")"
done
printf '  %-42s %4d / %-4d %s\n' "TOTAL" "$n_covered" "$n_denom" "$(pct "$n_covered" "$n_denom")"
echo

echo "GAPS (denominator rule-IDs with no spec test): $n_gap"
if [ "$VERBOSE" -eq 1 ] && [ "$n_gap" -gt 0 ]; then
    sed 's/^/  /' "$TMP/gap"
fi
echo "DANGLING (.rules cite an undeclared rule-ID): $n_dangling"
[ "$n_dangling" -gt 0 ] && sed 's/^/  /' "$TMP/dangling"
echo "UNTAGGED (spec test with no .rules sidecar): $n_untagged"
[ "$n_untagged" -gt 0 ] && sed "s#^$REPO_ROOT/##; s/^/  /" "$TMP/untagged"

# --- optional JSON (rule-IDs have no JSON-special chars, so emit directly).
if [ -n "$JSON_OUT" ]; then
    {
        echo '{'
        printf '  "denominator": %d, "covered": %d, "gaps": %d, "dangling": %d, "untagged": %d,\n' \
            "$n_denom" "$n_covered" "$n_gap" "$n_dangling" "$n_untagged"
        echo '  "rules": ['
        # id, bucket, source, covered(bool)
        awk -F'\t' '
            FNR==NR { cited[$1]=1; next }
            $2=="positive"||$2=="constraint"||$2=="constraint-candidate" {
                cov = ($1 in cited) ? "true" : "false"
                rows[++n] = sprintf("    {\"id\": \"%s\", \"bucket\": \"%s\", \"source\": \"%s\", \"covered\": %s}", $1, $2, $3, cov)
            }
            END { for (i=1;i<=n;i++) printf "%s%s\n", rows[i], (i<n?",":"") }
        ' "$TMP/cited" "$TMP/decl"
        echo '  ]'
        echo '}'
    } > "$JSON_OUT"
    echo
    echo "wrote $JSON_OUT"
fi

# Authoring errors fail the run; gaps are expected progress, not failures.
[ "$n_dangling" -eq 0 ] && [ "$n_untagged" -eq 0 ]
