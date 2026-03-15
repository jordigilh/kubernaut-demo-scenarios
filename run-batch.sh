#!/usr/bin/env bash
set -uo pipefail

export KUBECONFIG=~/.kube/kubernaut-demo-config
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${REPO_ROOT}/batch-results.txt"

> "$RESULTS_FILE"

for SCENARIO in "$@"; do
    SCENARIO_DIR="${REPO_ROOT}/scenarios/${SCENARIO}"
    if [ ! -f "${SCENARIO_DIR}/run.sh" ]; then
        echo "SKIP ${SCENARIO} (no run.sh)" | tee -a "$RESULTS_FILE"
        continue
    fi

    echo ""
    echo "================================================================"
    echo " STARTING: ${SCENARIO}  ($(date '+%H:%M:%S'))"
    echo "================================================================"

    # Cleanup previous scenario
    if [ -f "${SCENARIO_DIR}/cleanup.sh" ]; then
        echo "  -> Cleaning up ${SCENARIO}..."
        bash "${SCENARIO_DIR}/cleanup.sh" 2>&1 | tail -3
    fi

    # Clear stale RRs
    kubectl delete rr --all -n kubernaut-system --wait=false 2>/dev/null || true
    sleep 5

    # Run scenario
    START_TIME=$(date +%s)
    bash "${SCENARIO_DIR}/run.sh" 2>&1
    EXIT_CODE=$?
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))

    if [ $EXIT_CODE -eq 0 ]; then
        RESULT="PASS"
    else
        RESULT="FAIL (exit ${EXIT_CODE})"
    fi

    echo "${RESULT} ${SCENARIO} (${ELAPSED}s)" | tee -a "$RESULTS_FILE"
    echo ""
    echo "================================================================"
    echo " FINISHED: ${SCENARIO} -> ${RESULT} (${ELAPSED}s)"
    echo "================================================================"
done

echo ""
echo "==============================="
echo " BATCH SUMMARY"
echo "==============================="
cat "$RESULTS_FILE"
