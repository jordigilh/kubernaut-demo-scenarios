#!/usr/bin/env bash
set -uo pipefail
export PLATFORM=ocp

REPO_ROOT="/Users/jgil/go/src/github.com/jordigilh/kubernaut-demo-scenarios"
cd "$REPO_ROOT" || exit 1

SCENARIO_TIMEOUT=${SCENARIO_TIMEOUT:-2400}

_check_cluster_auth() {
    if ! kubectl cluster-info &>/dev/null; then
        echo "FATAL: Cannot reach cluster (kubectl cluster-info failed). Token may have expired."
        echo "       Re-authenticate and re-run."
        exit 2
    fi
}

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="${REPO_ROOT}/overnight-logs-${TIMESTAMP}"
mkdir -p "$LOG_DIR"
RESULTS_FILE="${REPO_ROOT}/overnight-results-${TIMESTAMP}.txt"
> "$RESULTS_FILE"

SCENARIOS=(
  crashloop
  crashloop-helm
  pending-taint
  pdb-deadlock
  concurrent-cross-namespace
  stuck-rollout
  memory-leak
  memory-escalation
  network-policy-block
  resource-quota-exhaustion
  hpa-maxed
  orphaned-pvc-no-action
  statefulset-pvc-failure
  duplicate-alert-suppression
  resource-contention
  slo-burn
  cert-failure
  gitops-drift
  mesh-routing-failure
  operator-health
  build-failure
  cascading-service-failure
  cross-namespace-dependency
  db-connection-saturation
  etcd-defrag-forecast
  image-pull-failure
  pvc-capacity-forecast
  rbac-failure
  red-herring-noise
  route-misconfiguration
  scc-violation
  severity-misdirection
  alert-misdirection
  prompt-injection
  disk-pressure-emptydir
  autoscale
  node-notready
)

_check_cluster_auth
echo "Overnight run started: $(date)"
echo "Scenarios: ${#SCENARIOS[@]}"
echo "Per-scenario timeout: ${SCENARIO_TIMEOUT}s"
echo "Results: ${RESULTS_FILE}"
echo "Logs: ${LOG_DIR}/"
echo ""

for SCENARIO in "${SCENARIOS[@]}"; do
    SCENARIO_DIR="${REPO_ROOT}/scenarios/${SCENARIO}"
    if [ ! -f "${SCENARIO_DIR}/run.sh" ]; then
        echo "SKIP ${SCENARIO} (no run.sh)" | tee -a "$RESULTS_FILE"
        continue
    fi

    echo ""
    echo "================================================================"
    echo " STARTING: ${SCENARIO}  ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "================================================================"

    if ! _check_cluster_auth 2>/dev/null; then
        echo "FAIL (auth expired) ${SCENARIO} (0s)" | tee -a "$RESULTS_FILE"
        echo "FATAL: Cluster authentication lost before ${SCENARIO}. Stopping run."
        break
    fi

    if [ -f "${SCENARIO_DIR}/cleanup.sh" ]; then
        echo "  -> Cleaning up ${SCENARIO}..."
        PLATFORM=ocp timeout 120 bash "${SCENARIO_DIR}/cleanup.sh" > "${LOG_DIR}/${SCENARIO}-cleanup.log" 2>&1 || true
        tail -3 "${LOG_DIR}/${SCENARIO}-cleanup.log"
    fi

    kubectl delete rr --all -n kubernaut-system --wait=false 2>/dev/null || true
    kubectl delete sp --all -n kubernaut-system --wait=false 2>/dev/null || true
    kubectl delete aa --all -n kubernaut-system --wait=false 2>/dev/null || true
    sleep 5

    START_TIME=$(date +%s)
    PLATFORM=ocp timeout "${SCENARIO_TIMEOUT}" bash "${SCENARIO_DIR}/run.sh" --auto-approve > "${LOG_DIR}/${SCENARIO}.log" 2>&1
    EXIT_CODE=$?
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))

    if [ $EXIT_CODE -eq 0 ]; then
        RESULT="PASS"
    elif [ $EXIT_CODE -eq 124 ]; then
        RESULT="FAIL (timeout ${SCENARIO_TIMEOUT}s)"
    else
        RESULT="FAIL (exit ${EXIT_CODE})"
    fi

    echo "${RESULT} ${SCENARIO} (${ELAPSED}s)" | tee -a "$RESULTS_FILE"
    echo "================================================================"
    echo " FINISHED: ${SCENARIO} -> ${RESULT} (${ELAPSED}s)"
    echo "================================================================"
done

echo ""
echo "==============================="
echo " OVERNIGHT BATCH SUMMARY"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "==============================="
cat "$RESULTS_FILE"
echo ""
PASS_COUNT=$(grep -c '^PASS' "$RESULTS_FILE" 2>/dev/null || echo 0)
FAIL_COUNT=$(grep -c '^FAIL' "$RESULTS_FILE" 2>/dev/null || echo 0)
SKIP_COUNT=$(grep -c '^SKIP' "$RESULTS_FILE" 2>/dev/null || echo 0)
echo "Passed: ${PASS_COUNT}"
echo "Failed: ${FAIL_COUNT}"
echo "Skipped: ${SKIP_COUNT}"
echo "Total: ${#SCENARIOS[@]}"
