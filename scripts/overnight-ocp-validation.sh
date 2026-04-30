#!/usr/bin/env bash
# overnight-ocp-validation.sh — Run all OCP-capable scenarios, capture golden
# transcripts, clean up, and produce a summary. Designed for unattended overnight runs.
#
# Usage:
#   nohup bash scripts/overnight-ocp-validation.sh 2>&1 | tee overnight-run.log &
#
# The script:
#   1. Waits for any in-flight disk-pressure-emptydir run to finish
#   2. Runs each scenario: run.sh --auto-approve → capture-eval.sh --wait → cleanup.sh
#   3. Batch-captures golden transcripts via capture-golden-transcripts.sh
#   4. Writes a summary table to overnight-results-<timestamp>.txt
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCENARIOS_DIR="${REPO_ROOT}/scenarios"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_FILE="${REPO_ROOT}/overnight-results-${TIMESTAMP}.txt"
LOGS_DIR="${REPO_ROOT}/overnight-logs-${TIMESTAMP}"
TRANSCRIPTS_DIR="${REPO_ROOT}/golden-transcripts"
mkdir -p "${LOGS_DIR}" "${TRANSCRIPTS_DIR}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

# shellcheck source=platform-helper.sh
source "${SCRIPT_DIR}/platform-helper.sh"

SKIP_SEED=false
for arg in "$@"; do
  case "$arg" in
    --skip-seed) SKIP_SEED=true ;;
  esac
done

if [ "$SKIP_SEED" = true ]; then
  echo "==> Skipping seed (--skip-seed): workflows already present"
  _warn_slow_ksm_scrape
else
  require_demo_ready
fi

# Scenario execution order — disk-pressure-emptydir runs first (special timing),
# then all standard scenarios. node-notready is Kind-only and auto-skips on OCP.
SCENARIO_ORDER=(
  disk-pressure-emptydir
  crashloop
  crashloop-helm
  stuck-rollout
  memory-leak
  memory-escalation
  resource-contention
  pdb-deadlock
  pending-taint
  network-policy-block
  hpa-maxed
  autoscale
  orphaned-pvc-no-action
  statefulset-pvc-failure
  resource-quota-exhaustion
  duplicate-alert-suppression
  concurrent-cross-namespace
  cert-failure
  slo-burn
  gitops-drift
  mesh-routing-failure
  node-notready
)

ONLY_LIST=""
for arg in "$@"; do
  case "$arg" in
    --only=*) ONLY_LIST="${arg#*=}" ;;
  esac
done

should_run() {
  local name="$1"
  if [ -n "$ONLY_LIST" ]; then
    echo ",$ONLY_LIST," | grep -q ",$name," && return 0 || return 1
  fi
  return 0
}

passed=0
failed=0
skipped=0
declare -A results
declare -A confidences
declare -A workflows

header() {
  printf '\n%s\n  %s\n%s\n' \
    "$(printf '═%.0s' {1..72})" "$1" "$(printf '═%.0s' {1..72})"
}

log_both() {
  echo "$1" | tee -a "${RESULTS_FILE}"
}

capture_transcript() {
  local scenario="$1"
  local log_file="$2"
  echo "  Capturing golden transcript..." | tee -a "${RESULTS_FILE}"
  set +e
  bash "${SCRIPT_DIR}/capture-eval.sh" --wait --output "${TRANSCRIPTS_DIR}" \
    >> "${log_file}" 2>&1
  local cap_exit=$?
  set -e
  if [ $cap_exit -eq 0 ]; then
    echo "  Golden transcript captured." | tee -a "${RESULTS_FILE}"
  else
    echo "  WARN: transcript capture failed (exit=${cap_exit})" | tee -a "${RESULTS_FILE}"
  fi
}

extract_confidence() {
  local rr_name
  rr_name=$(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$rr_name" ]; then
    kubectl exec -n "${PLATFORM_NS}" deploy/postgresql -- \
      psql -U kubernaut -d kubernaut -t -A -c "
        SELECT (event_data->'response_data'->>'confidence')::text
        FROM audit_events
        WHERE correlation_id = '${rr_name}'
          AND event_type = 'aiagent.response.complete'
        ORDER BY event_timestamp DESC LIMIT 1
      " 2>/dev/null || echo ""
  fi
}

extract_workflow() {
  local rr_name
  rr_name=$(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$rr_name" ]; then
    kubectl exec -n "${PLATFORM_NS}" deploy/postgresql -- \
      psql -U kubernaut -d kubernaut -t -A -c "
        SELECT event_data->'response_data'->>'workflowId'
        FROM audit_events
        WHERE correlation_id = '${rr_name}'
          AND event_type = 'aiagent.response.complete'
        ORDER BY event_timestamp DESC LIMIT 1
      " 2>/dev/null || echo ""
  fi
}

# ── Header ──────────────────────────────────────────────────────────────────
{
  echo "Kubernaut OCP Overnight Validation Run"
  echo "Started:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Cluster:  $(kubectl config current-context 2>/dev/null)"
  echo "Platform: OCP"
  echo "KA image: $(kubectl get pod -n ${PLATFORM_NS} -l app=kubernaut-agent -o jsonpath='{.items[0].status.containerStatuses[0].image}' 2>/dev/null || echo 'unknown')"
  echo "Nodes:    $(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo ""
} | tee "${RESULTS_FILE}"

# ── Run scenarios ───────────────────────────────────────────────────────────
for scenario in "${SCENARIO_ORDER[@]}"; do
  scenario_dir="${SCENARIOS_DIR}/${scenario}"
  log_file="${LOGS_DIR}/${scenario}.log"

  if ! should_run "$scenario"; then
    results[$scenario]="SKIPPED (not in --only)"
    skipped=$((skipped + 1))
    continue
  fi

  if [ ! -f "${scenario_dir}/run.sh" ]; then
    results[$scenario]="SKIPPED (no run.sh)"
    skipped=$((skipped + 1))
    log_both "  SKIP  ${scenario}: no run.sh"
    continue
  fi

  header "RUNNING: ${scenario}" | tee -a "${RESULTS_FILE}"
  log_both "  Started: $(date -u '+%H:%M:%S UTC')"
  start_ts=$(date +%s)

  # Run the scenario with auto-approve
  set +e
  bash "${scenario_dir}/run.sh" --auto-approve > "${log_file}" 2>&1
  run_exit=$?
  set -e

  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))

  # Extract confidence and workflow before cleanup
  conf=$(extract_confidence)
  wf=$(extract_workflow)
  confidences[$scenario]="${conf:-—}"
  workflows[$scenario]="${wf:-—}"

  if [ $run_exit -eq 0 ]; then
    results[$scenario]="PASS (${elapsed}s)"
    passed=$((passed + 1))
    log_both "  PASS  ${scenario}  (${elapsed}s)  confidence=${conf:-—}  workflow=${wf:-—}"

    # Capture golden transcript
    capture_transcript "$scenario" "$log_file"
  elif [ $run_exit -eq 1 ] && grep -q "Kind-only\|OCP_SKIP\|SKIP.*OCP" "${log_file}" 2>/dev/null; then
    results[$scenario]="SKIPPED (Kind-only)"
    skipped=$((skipped + 1))
    log_both "  SKIP  ${scenario}: Kind-only scenario"
  else
    results[$scenario]="FAIL exit=${run_exit} (${elapsed}s)"
    failed=$((failed + 1))
    log_both "  FAIL  ${scenario}  exit=${run_exit} (${elapsed}s)"
    log_both "  Log: ${log_file}"
    echo "  --- last 25 lines ---" | tee -a "${RESULTS_FILE}"
    tail -25 "${log_file}" | sed 's/^/  | /' | tee -a "${RESULTS_FILE}"
    echo "  ---" | tee -a "${RESULTS_FILE}"

    # Still try to capture transcript for failed scenarios (may have partial data)
    capture_transcript "$scenario" "$log_file"
  fi

  # Cleanup
  log_both "  Cleaning up ${scenario}..."
  if [ -f "${scenario_dir}/cleanup.sh" ]; then
    set +e
    bash "${scenario_dir}/cleanup.sh" >> "${log_file}" 2>&1
    cleanup_exit=$?
    set -e
    if [ $cleanup_exit -ne 0 ]; then
      log_both "  WARN: cleanup failed (exit=${cleanup_exit})"
    fi
  fi

  log_both "  Finished: $(date -u '+%H:%M:%S UTC')"

  # Let AlertManager settle between scenarios
  sleep 15
done

# ── Batch golden transcript capture (safety net) ───────────────────────────
header "BATCH GOLDEN TRANSCRIPT CAPTURE" | tee -a "${RESULTS_FILE}"
set +e
bash "${SCRIPT_DIR}/capture-golden-transcripts.sh" 2>&1 | tee -a "${RESULTS_FILE}"
set -e

# ── Summary ─────────────────────────────────────────────────────────────────
{
  echo ""
  echo "$(printf '═%.0s' {1..72})"
  echo "  OCP VALIDATION SUMMARY"
  echo "$(printf '═%.0s' {1..72})"
  echo ""
  echo "  Passed:  ${passed}"
  echo "  Failed:  ${failed}"
  echo "  Skipped: ${skipped}"
  echo "  Total:   ${#SCENARIO_ORDER[@]}"
  echo ""
  printf "  %-35s %-12s %-10s %s\n" "SCENARIO" "RESULT" "CONFIDENCE" "WORKFLOW"
  printf "  %-35s %-12s %-10s %s\n" "$(printf '─%.0s' {1..35})" "$(printf '─%.0s' {1..12})" "$(printf '─%.0s' {1..10})" "$(printf '─%.0s' {1..30})"
  for scenario in "${SCENARIO_ORDER[@]}"; do
    local_result="${results[$scenario]:-NOT_RUN}"
    local_conf="${confidences[$scenario]:-—}"
    local_wf="${workflows[$scenario]:-—}"
    # Extract pass/fail/skip prefix
    case "$local_result" in
      PASS*)  status="PASS" ;;
      FAIL*)  status="FAIL" ;;
      SKIP*)  status="SKIP" ;;
      *)      status="—" ;;
    esac
    printf "  %-35s %-12s %-10s %s\n" "$scenario" "$status" "$local_conf" "$local_wf"
  done
  echo ""
  echo "  Results:     ${RESULTS_FILE}"
  echo "  Logs:        ${LOGS_DIR}/"
  echo "  Transcripts: ${TRANSCRIPTS_DIR}/"
  echo ""
  echo "  Finished: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo ""

  # Pass rate
  total_run=$((passed + failed))
  if [ $total_run -gt 0 ]; then
    rate=$(awk "BEGIN { printf \"%.0f\", 100*${passed}/${total_run} }")
    echo "  Pass rate: ${passed}/${total_run} (${rate}%)"
    if [ $rate -ge 90 ]; then
      echo "  Release gate: PASS (>= 90%)"
    else
      echo "  Release gate: FAIL (< 90%)"
    fi
  fi
} | tee -a "${RESULTS_FILE}"
