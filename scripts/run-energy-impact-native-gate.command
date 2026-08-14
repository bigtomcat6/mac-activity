#!/bin/zsh
set -euo pipefail
export LC_ALL=C
export LANG=C

if [[ "$#" -ne 1 ]]; then
  print -u2 "usage: $0 /absolute/evidence-directory"
  exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
repository_status="$(git -C "$repo_root" status --porcelain)"
if [[ -n "$repository_status" ]]; then
  print -u2 "refusing dirty repository: $repo_root"
  exit 70
fi
candidate_sha="$(git -C "$repo_root" rev-parse HEAD)"
requested_scope="${MACACTIVITY_ENERGY_NATIVE_SCOPE:-regularOnly}"
case "$requested_scope" in
  regularOnly|regularAndAccessory) ;;
  *) print -u2 "Invalid MACACTIVITY_ENERGY_NATIVE_SCOPE: $requested_scope"; exit 2 ;;
esac
evidence_dir="$1"

if [[ "${evidence_dir[1]}" != "/" ]]; then
  print -u2 "evidence directory must be absolute"
  exit 64
fi
if [[ -e "$evidence_dir" ]]; then
  print -u2 "refusing to overwrite: $evidence_dir"
  exit 73
fi
mkdir "$evidence_dir"
print -r -- "$candidate_sha" > "$evidence_dir/candidate-sha.txt"

{
  /bin/date -u
  /usr/bin/sw_vers
  /usr/sbin/system_profiler SPHardwareDataType
  /usr/bin/pmset -g batt || true
  /usr/bin/pmset -g custom || true
} > "$evidence_dir/environment.txt" 2>&1

metrics_file="$evidence_dir/metrics.tsv"
: > "$metrics_file"
run_status_file="$evidence_dir/run-status.tsv"
: > "$run_status_file"
overall_status=0

for run in 1 2 3 4 5; do
  log_file="$evidence_dir/run-$run.log"
  set +e
  MACACTIVITY_ENERGY_NATIVE_VALIDATION=1 \
  MACACTIVITY_ENERGY_NATIVE_SCOPE="$requested_scope" \
  CLANG_MODULE_CACHE_PATH=/private/tmp/macactivity-part4-clang-cache \
  swift test \
    --package-path "$repo_root" \
    --filter \
    EnergyImpactNativeValidationTests/testVisibleFacadeBudget \
    > "$log_file" 2>&1
  test_status="$?"
  set -e

  metric_count="$(
    /usr/bin/grep -c '^ENERGY_NATIVE_METRICS ' "$log_file" ||
      true
  )"
  if [[ "$metric_count" -ne 1 ]]; then
    print -u2 \
      "run $run invalid: test=$test_status metrics=$metric_count"
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
      "$run" "metric_count_invalid" "$test_status" \
      "$metric_count" "$log_file" >> "$run_status_file"
    overall_status=1
    continue
  fi

  metric_line="$(
    /usr/bin/grep '^ENERGY_NATIVE_METRICS ' "$log_file"
  )"
  observations="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "observations" { print $2 }'
  )"
  pre_run_catalog_apps="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "pre_run_catalog_apps" { print $2 }'
  )"
  system_snapshot_processes="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "system_snapshot_processes" { print $2 }'
  )"
  p50_ms="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "p50_ms" { print $2 }'
  )"
  p95_ms="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "p95_ms" { print $2 }'
  )"
  cpu_percent="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "cpu_percent" { print $2 }'
  )"
  wall_seconds="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "wall_seconds" { print $2 }'
  )"
  scope="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "scope" { print $2 }'
  )"
  scope_count="$(
    print -r -- "$metric_line" |
      /usr/bin/tr ' ' '\n' |
      /usr/bin/awk -F= '$1 == "scope" { count += 1 } END { print count + 0 }'
  )"

  if [[ "$scope_count" -ne 1 || "$scope" != "$requested_scope" ]]; then
    print -u2 "run $run has invalid scope metric: $scope"
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
      "$run" "scope_invalid" "$test_status" \
      "$metric_count" "$log_file" >> "$run_status_file"
    overall_status=1
    continue
  fi

  if [[ -z "$observations" ||
        -z "$pre_run_catalog_apps" ||
        -z "$system_snapshot_processes" ||
        -z "$p50_ms" ||
        -z "$p95_ms" ||
        -z "$cpu_percent" ||
        -z "$wall_seconds" ]]; then
    print -u2 "run $run has incomplete metrics"
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
      "$run" "incomplete_metrics" "$test_status" \
      "$metric_count" "$log_file" >> "$run_status_file"
    overall_status=1
    continue
  fi

  if ! /usr/bin/awk \
    -v observations="$observations" \
    -v apps="$pre_run_catalog_apps" \
    -v processes="$system_snapshot_processes" \
    -v p50="$p50_ms" \
    -v p95="$p95_ms" \
    -v cpu="$cpu_percent" \
    -v wall="$wall_seconds" \
    'BEGIN {
      unsigned = "^[0-9]+$"
      decimal = "^[0-9]+([.][0-9]+)?$"
      valid = (observations ~ unsigned &&
        apps ~ unsigned &&
        processes ~ unsigned &&
        p50 ~ decimal &&
        p95 ~ decimal &&
        cpu ~ decimal &&
        wall ~ decimal)
      exit !valid
    }'
  then
    print -u2 "run $run has noncanonical metrics"
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
      "$run" "noncanonical_metrics" "$test_status" \
      "$metric_count" "$log_file" >> "$run_status_file"
    overall_status=1
    continue
  fi

  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run" "scope=$scope" "$observations" \
    "$pre_run_catalog_apps" "$system_snapshot_processes" \
    "$p50_ms" "$p95_ms" "$cpu_percent" "$wall_seconds" \
    "$log_file" \
    >> "$metrics_file"

  run_gate_status=PASS
  if [[ "$test_status" -ne 0 ]]; then
    run_gate_status=FAIL
    overall_status=1
  fi
  if [[ "$observations" -ne 21 ]]; then
    run_gate_status=FAIL
    overall_status=1
  fi
  if [[ "$pre_run_catalog_apps" -le 0 ||
        "$system_snapshot_processes" -le 0 ]]; then
    run_gate_status=FAIL
    overall_status=1
  fi
  if ! /usr/bin/awk -v value="$p95_ms" \
    'BEGIN { exit !(value < 100) }'
  then
    run_gate_status=FAIL
    overall_status=1
  fi
  if ! /usr/bin/awk -v value="$cpu_percent" \
    'BEGIN { exit !(value < 0.55) }'
  then
    run_gate_status=FAIL
    overall_status=1
  fi
  if ! /usr/bin/awk -v value="$wall_seconds" \
    'BEGIN { exit !(value >= 60) }'
  then
    run_gate_status=FAIL
    overall_status=1
  fi
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
    "$run" "$run_gate_status" "$test_status" \
    "$metric_count" "$log_file" >> "$run_status_file"
done

valid_count="$(
  /usr/bin/awk 'END { print NR }' "$metrics_file"
)"
if [[ "$valid_count" -ne 5 ]]; then
  overall_status=1
fi

summary_file="$evidence_dir/summary.txt"
{
  print "run status test_status metric_count log"
  /usr/bin/awk -F '\t' \
    '{ print $1, $2, $3, $4, $5 }' "$run_status_file"
} > "$summary_file"
if [[ "$valid_count" -eq 5 ]]; then
  /usr/bin/cut -f8 "$metrics_file" |
    /usr/bin/sort -n > "$evidence_dir/cpu-sorted.txt"
  median="$(
    /usr/bin/sed -n '3p' "$evidence_dir/cpu-sorted.txt"
  )"
  maximum="$(
    /usr/bin/tail -n 1 "$evidence_dir/cpu-sorted.txt"
  )"
  sorted_values="$(
    /usr/bin/paste -s -d, "$evidence_dir/cpu-sorted.txt"
  )"
  if ! /usr/bin/awk -v value="$median" \
    'BEGIN { exit !(value < 0.5) }'
  then
    overall_status=1
  fi

  {
    print "ENERGY_NATIVE_GATE median_cpu_percent=$median maximum_cpu_percent=$maximum"
    print "sorted_cpu_percent=$sorted_values"
    print "run scope observations pre_run_catalog_apps system_snapshot_processes p50_ms p95_ms cpu_percent wall_seconds log"
    /usr/bin/awk -F '\t' \
      '{ print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10 }' \
      "$metrics_file"
  } | /usr/bin/tee -a "$summary_file"
else
  print "ENERGY_NATIVE_GATE invalid_run_count=$valid_count" |
    /usr/bin/tee -a "$summary_file"
fi

final_sha="$(git -C "$repo_root" rev-parse HEAD)"
final_status="$(git -C "$repo_root" status --porcelain)"
if [[ "$final_sha" != "$candidate_sha" || -n "$final_status" ]]; then
  print -u2 "candidate changed during native gate"
  overall_status=1
fi

if [[ "$overall_status" -ne 0 ]]; then
  print "ENERGY_NATIVE_GATE FAIL evidence=$evidence_dir" |
    /usr/bin/tee -a "$summary_file" >&2
  exit 1
fi

print "ENERGY_NATIVE_GATE PASS evidence=$evidence_dir" |
  /usr/bin/tee -a "$summary_file"
