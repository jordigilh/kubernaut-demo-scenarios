#!/usr/bin/env bash
# parallel-ocp-validation.sh — Run OCP scenarios in two parallel groups using
# the proven overnight-ocp-validation.sh, with comprehensive preflight and
# disk-pressure-emptydir last.
#
# Usage:
#   nohup bash scripts/parallel-ocp-validation.sh 2>&1 | tee parallel-run.log &
#
# Groups:
#   A (13 scenarios): crashloop, crashloop-helm, stuck-rollout, memory-leak,
#                     resource-contention, hpa-maxed, duplicate-alert-suppression,
#                     operator-oomkill-informer, db-connection-saturation,
#                     image-pull-failure, rbac-failure, red-herring-noise,
#                     severity-misdirection
#   B (13 scenarios): network-policy-block, statefulset-pvc-failure,
#                     resource-quota-exhaustion, cert-failure, slo-burn,
#                     orphaned-pvc-no-action, concurrent-cross-namespace,
#                     mesh-routing-failure, pending-taint,
#                     cascading-service-failure, cross-namespace-dependency,
#                     route-misconfiguration, scc-violation
#   Excluded: autoscale (Kind-only), node-notready (Kind-only),
#             mesh-routing-failure (no Istio), disk-pressure-emptydir (no Gitea/AWX),
#             gitops-drift (no Gitea)
#   Solo (after both): pdb-deadlock, etcd-defrag-forecast,
#                      pvc-capacity-forecast, operator-health, build-failure
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

RESULTS_DIR="${REPO_ROOT}/parallel-results-${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

GROUP_A="crashloop,crashloop-helm,stuck-rollout,memory-leak,resource-contention,hpa-maxed,duplicate-alert-suppression,operator-oomkill-informer,db-connection-saturation,image-pull-failure,rbac-failure,red-herring-noise,severity-misdirection"
GROUP_B="network-policy-block,statefulset-pvc-failure,resource-quota-exhaustion,cert-failure,slo-burn,orphaned-pvc-no-action,concurrent-cross-namespace,pending-taint,cascading-service-failure,cross-namespace-dependency,route-misconfiguration,scc-violation"

echo "============================================="
echo " v1.5 Parallel OCP Regression Validation"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="
echo ""
echo "  Results dir: ${RESULTS_DIR}"
echo "  Group A: ${GROUP_A//,/, }"
echo "  Group B: ${GROUP_B//,/, }"
echo "  Solo:    pdb-deadlock, etcd-defrag-forecast,"
echo "           pvc-capacity-forecast, operator-health, build-failure"
echo ""

# ── 1. Preflight ─────────────────────────────────────────────────────────────

echo "==> Phase 1: Preflight checks..."
if ! bash "${SCRIPT_DIR}/rc5-preflight.sh" 2>&1 | tee "${RESULTS_DIR}/preflight.log"; then
    echo ""
    echo "PREFLIGHT FAILED — aborting parallel validation."
    echo "Review: ${RESULTS_DIR}/preflight.log"
    exit 1
fi
echo ""

# ── 2. Export batch guard ─────────────────────────────────────────────────────
# Preflight already ran enable_prometheus_toolset and force_production_approval.
# This env var makes scenario run.sh scripts skip those calls to avoid
# concurrent controller restarts.

export KUBERNAUT_BATCH_SETUP_DONE=1

# Bump wait/poll timeouts for parallel runs: batched alert payloads can
# delay gateway RR creation and LLM concurrency extends pipeline time.
export WAIT_FOR_RR_TIMEOUT=300
export POLL_PIPELINE_TIMEOUT=1200

# ── 3. Launch parallel groups ─────────────────────────────────────────────────

echo "==> Phase 2: Launching Group A and Group B in parallel..."
echo "    Started: $(date -u '+%H:%M:%S UTC')"
echo ""

bash "${SCRIPT_DIR}/overnight-ocp-validation.sh" \
    --skip-seed "--only=${GROUP_A}" \
    > "${RESULTS_DIR}/group-a.log" 2>&1 &
PID_A=$!
echo "  Group A PID=${PID_A}"

bash "${SCRIPT_DIR}/overnight-ocp-validation.sh" \
    --skip-seed "--only=${GROUP_B}" \
    > "${RESULTS_DIR}/group-b.log" 2>&1 &
PID_B=$!
echo "  Group B PID=${PID_B}"

echo ""
echo "  Waiting for both groups to complete..."
echo "  Monitor: tail -f ${RESULTS_DIR}/group-a.log"
echo "           tail -f ${RESULTS_DIR}/group-b.log"
echo ""

set +e
wait $PID_A
EXIT_A=$?
echo "  Group A finished: exit=${EXIT_A} at $(date -u '+%H:%M:%S UTC')"

wait $PID_B
EXIT_B=$?
echo "  Group B finished: exit=${EXIT_B} at $(date -u '+%H:%M:%S UTC')"
set -e

echo ""

# ── 4. Solo scenarios ─────────────────────────────────────────────────────────

echo "==> Phase 3: Solo scenarios (after both groups)..."

# Let AlertManager settle between groups and solo
sleep 30

echo "  Running pdb-deadlock..."
bash "${SCRIPT_DIR}/overnight-ocp-validation.sh" \
    --skip-seed "--only=pdb-deadlock" \
    > "${RESULTS_DIR}/solo-pdb.log" 2>&1
EXIT_PDB=$?
echo "  pdb-deadlock finished: exit=${EXIT_PDB}"

sleep 15

SOLO_SCENARIOS=(etcd-defrag-forecast pvc-capacity-forecast operator-health build-failure)
SOLO_EXIT=0
for solo in "${SOLO_SCENARIOS[@]}"; do
    echo "  Running ${solo}..."
    bash "${SCRIPT_DIR}/overnight-ocp-validation.sh" \
        --skip-seed "--only=${solo}" \
        > "${RESULTS_DIR}/solo-${solo}.log" 2>&1
    _exit=$?
    echo "  ${solo} finished: exit=${_exit}"
    [ $_exit -ne 0 ] && SOLO_EXIT=1
    sleep 15
done

echo ""

# ── 5. Merge results ─────────────────────────────────────────────────────────

echo "==> Phase 4: Merging results..."
bash "${SCRIPT_DIR}/merge-parallel-results.sh" "${RESULTS_DIR}" | tee "${RESULTS_DIR}/summary.txt"

echo ""

# ── 6. Eval report ───────────────────────────────────────────────────────────

echo "==> Phase 5: Running eval report..."
echo ""

set +e
python3 "${SCRIPT_DIR}/eval_report.py" --transcripts "${REPO_ROOT}/golden-transcripts/" \
    2>&1 | tee "${RESULTS_DIR}/eval-report.txt"

echo ""
echo "--- Cross-version comparison ---"
echo ""
python3 "${SCRIPT_DIR}/eval_report.py" --compare v1.3.2 v1.4.0-rc5 \
    2>&1 | tee "${RESULTS_DIR}/compare-v1.3.2-vs-rc5.txt"
set -e

echo ""
echo "============================================="
echo " Parallel Validation Complete"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="
echo ""
echo "  Results:    ${RESULTS_DIR}/summary.txt"
echo "  Eval:       ${RESULTS_DIR}/eval-report.txt"
echo "  Comparison: ${RESULTS_DIR}/compare-v1.3.2-vs-rc5.txt"
echo "  Group logs: ${RESULTS_DIR}/group-a.log"
echo "              ${RESULTS_DIR}/group-b.log"
echo ""

# Exit non-zero if any group had failures
if [ $EXIT_A -ne 0 ] || [ $EXIT_B -ne 0 ] || [ $EXIT_PDB -ne 0 ] || [ $SOLO_EXIT -ne 0 ]; then
    echo "  Some scenarios failed. Review logs for details."
    exit 1
fi
