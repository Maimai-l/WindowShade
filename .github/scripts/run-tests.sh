#!/bin/bash
# Run each tests/run-*.sh on its own and report the results as a table.
# Scripts that need a signed build or an unlocked GUI session are skipped.
set -uo pipefail
cd "$(dirname "$0")/../.."
logs=.build/ci-logs
mkdir -p "$logs"
skip=" run-glance-probe.sh run-perf-check.sh "
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
failed=0
{
  echo "| Runner | Result | Seconds |"
  echo "|---|---|---|"
} >> "$summary"
for script in tests/run-*.sh; do
  name=$(basename "$script")
  if [[ "$skip" == *" $name "* ]]; then
    echo "| $name | skipped (needs signed build) | |" >> "$summary"
    continue
  fi
  echo "::group::$name"
  start=$(date +%s)
  if perl -e 'alarm 900; exec @ARGV' bash "$script" > "$logs/$name.log" 2>&1; then
    result=pass
  else
    result="fail ($?)"
    failed=$((failed + 1))
  fi
  tail -40 "$logs/$name.log"
  echo "::endgroup::"
  echo "| $name | $result | $(( $(date +%s) - start )) |" >> "$summary"
done
echo "$failed runner(s) failed" | tee -a "$summary"
exit $(( failed > 0 ))
