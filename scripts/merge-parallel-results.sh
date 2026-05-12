#!/usr/bin/env bash
# merge-parallel-results.sh — Merge results from parallel group runs into a
# single summary table with pass/fail, confidence, workflow, and duration.
#
# Usage:
#   bash scripts/merge-parallel-results.sh <results-dir>
#
# Expects:
#   <results-dir>/group-a.log
#   <results-dir>/group-b.log
#   <results-dir>/solo-pdb.log           (optional)
#   <results-dir>/solo-diskpressure.log  (optional)
set -uo pipefail

RESULTS_DIR="${1:?Usage: merge-parallel-results.sh <results-dir>}"

if [ ! -d "$RESULTS_DIR" ]; then
    echo "ERROR: Results directory not found: $RESULTS_DIR" >&2
    exit 1
fi

ALL_SCENARIOS=(
    crashloop crashloop-helm stuck-rollout memory-leak memory-escalation
    resource-contention hpa-maxed autoscale duplicate-alert-suppression
    network-policy-block statefulset-pvc-failure resource-quota-exhaustion
    cert-failure slo-burn orphaned-pvc-no-action concurrent-cross-namespace
    mesh-routing-failure pending-taint
    pdb-deadlock disk-pressure-emptydir
)

declare -A scenario_status
declare -A scenario_conf
declare -A scenario_wf
declare -A scenario_time
declare -A scenario_group

passed=0
failed=0
skipped=0

parse_log() {
    local log_file="$1" group_name="$2"
    [ -f "$log_file" ] || return 0
    local in_summary=false

    while IFS= read -r line; do
        # Detect summary table section (to pick up confidence for failed scenarios)
        if echo "$line" | grep -qE 'SCENARIO\s+RESULT\s+CONFIDENCE'; then
            in_summary=true
            continue
        fi

        if [ "$in_summary" = true ]; then
            # Summary table rows: "  scenario-name     PASS     0.97       —"
            local sum_scenario sum_status sum_conf sum_wf
            sum_scenario=$(echo "$line" | awk '{print $1}')
            sum_status=$(echo "$line" | awk '{print $2}')

            # Skip separator lines and empty lines
            if [ -z "$sum_scenario" ] || echo "$sum_scenario" | grep -qE '^[═─]'; then
                continue
            fi
            # End of table
            if echo "$line" | grep -qE '(Results:|Finished:|Pass rate)'; then
                in_summary=false
                continue
            fi

            # Only update confidence if we don't already have one from the inline PASS line
            if [ "${sum_status}" = "PASS" ] || [ "${sum_status}" = "FAIL" ]; then
                sum_conf=$(echo "$line" | awk '{print $3}')
                sum_wf=$(echo "$line" | awk '{print $4}')
                [ -z "$sum_conf" ] || [ "$sum_conf" = "—" ] || \
                    [ -n "${scenario_conf[$sum_scenario]:-}" ] && [ "${scenario_conf[$sum_scenario]:-}" != "—" ] || \
                    scenario_conf[$sum_scenario]="$sum_conf"
            fi
            continue
        fi

        # Match inline result lines: "  PASS  crashloop  (936s)  confidence=0.97  workflow=—"
        #                          or "  FAIL  crashloop  exit=1 (925s)"
        if echo "$line" | grep -qE '^\s+(PASS|FAIL)\s+\S+'; then
            local status scenario elapsed conf wf

            status=$(echo "$line" | awk '{print $1}')
            scenario=$(echo "$line" | awk '{print $2}')

            elapsed=$(echo "$line" | grep -oE '\([0-9]+s\)' | tr -d '()s' || echo "—")
            conf=$(echo "$line" | grep -oE 'confidence=[0-9.]+' | cut -d= -f2 || echo "—")
            wf=$(echo "$line" | grep -oE 'workflow=[^ ]+' | cut -d= -f2 || echo "—")

            [ -z "$conf" ] && conf="—"
            [ -z "$wf" ] && wf="—"
            [ -z "$elapsed" ] && elapsed="—"

            scenario_status[$scenario]="$status"
            scenario_conf[$scenario]="$conf"
            scenario_wf[$scenario]="$wf"
            scenario_time[$scenario]="$elapsed"
            scenario_group[$scenario]="$group_name"

            if [ "$status" = "PASS" ]; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
            fi
        fi

        # Match SKIP lines: "  SKIP  node-notready: Kind-only scenario"
        if echo "$line" | grep -qE '^\s+SKIP\s+\S+'; then
            local scenario
            scenario=$(echo "$line" | awk '{print $2}' | tr -d ':')
            scenario_status[$scenario]="SKIP"
            scenario_group[$scenario]="$group_name"
            skipped=$((skipped + 1))
        fi
    done < "$log_file"
}

parse_log "${RESULTS_DIR}/group-a.log" "A"
parse_log "${RESULTS_DIR}/group-b.log" "B"
parse_log "${RESULTS_DIR}/solo-pdb.log" "Solo"
parse_log "${RESULTS_DIR}/solo-diskpressure.log" "Solo"

total_run=$((passed + failed))

echo ""
echo "$(printf '═%.0s' {1..90})"
echo "  RC5 PARALLEL VALIDATION — MERGED SUMMARY"
echo "$(printf '═%.0s' {1..90})"
echo ""
echo "  Passed:  ${passed}"
echo "  Failed:  ${failed}"
echo "  Skipped: ${skipped}"
echo "  Total:   ${#ALL_SCENARIOS[@]}"
echo ""

printf "  %-35s %-6s %-5s %-10s %-8s %s\n" "SCENARIO" "GROUP" "STAT" "CONFIDENCE" "TIME(s)" "WORKFLOW"
printf "  %-35s %-6s %-5s %-10s %-8s %s\n" \
    "$(printf '─%.0s' {1..35})" "$(printf '─%.0s' {1..6})" "$(printf '─%.0s' {1..5})" \
    "$(printf '─%.0s' {1..10})" "$(printf '─%.0s' {1..8})" "$(printf '─%.0s' {1..20})"

for scenario in "${ALL_SCENARIOS[@]}"; do
    local_status="${scenario_status[$scenario]:-—}"
    local_conf="${scenario_conf[$scenario]:-—}"
    local_wf="${scenario_wf[$scenario]:-—}"
    local_time="${scenario_time[$scenario]:-—}"
    local_group="${scenario_group[$scenario]:-—}"

    printf "  %-35s %-6s %-5s %-10s %-8s %s\n" \
        "$scenario" "$local_group" "$local_status" "$local_conf" "$local_time" "$local_wf"
done

echo ""

if [ $total_run -gt 0 ]; then
    rate=$(awk "BEGIN { printf \"%.0f\", 100*${passed}/${total_run} }")
    echo "  Pass rate: ${passed}/${total_run} (${rate}%)"
    if [ $rate -ge 90 ]; then
        echo "  Release gate: PASS (>= 90%)"
    else
        echo "  Release gate: FAIL (< 90%)"
    fi
    echo ""
fi

# List failures
if [ $failed -gt 0 ]; then
    echo "  FAILED SCENARIOS:"
    for scenario in "${ALL_SCENARIOS[@]}"; do
        if [ "${scenario_status[$scenario]:-}" = "FAIL" ]; then
            echo "    - ${scenario} (Group ${scenario_group[$scenario]:-?})"
        fi
    done
    echo ""
fi
