#!/bin/bash
# summary.sh <dir>: every job's results.tsv under <dir> in one table
# (<dir>/all-results.tsv), the counts and every failed check on stdout and in
# the run's summary page. Exit 1 if any check failed or a job left no results.
set -uo pipefail
D="$1"
ALL="$D/all-results.tsv"
printf 'image\tphase\tcheck\tresult\tdetail\n' > "$ALL"
n=0
while IFS= read -r f; do tail -n +2 "$f" >> "$ALL"; n=$((n + 1)); done < <(find "$D" -name results.tsv | sort)
pass="$(awk -F'\t' 'NR>1 && $4=="PASS"' "$ALL" | wc -l)"
fail="$(awk -F'\t' 'NR>1 && $4=="FAIL"' "$ALL" | wc -l)"
info="$(awk -F'\t' 'NR>1 && $4=="INFO"' "$ALL" | wc -l)"
{
  echo "## ARM64 hardware test"
  echo
  echo "$n result files: **PASS $pass, FAIL $fail**, INFO $info"
  echo
  if [ "$fail" -gt 0 ]; then
    echo "| where | phase | check | detail |"; echo "|---|---|---|---|"
    awk -F'\t' 'NR>1 && $4=="FAIL" { d = substr($5, 1, 300); gsub(/\|/, "/", d); printf "| %s | %s | %s | %s |\n", $1, $2, $3, d }' "$ALL"
  fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
[ "$n" -gt 0 ] && [ "$fail" -eq 0 ]
