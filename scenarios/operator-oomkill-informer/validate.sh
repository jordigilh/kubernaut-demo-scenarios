#!/usr/bin/env bash
# Validate operator-oomkill-informer scenario pipeline outcome.
# OOMKill from informer cache flooding -> IncreaseMemoryLimits -> operator recovers.
#
# Called by run.sh or standalone:
#   ./scenarios/operator-oomkill-informer/validate.sh [--auto-approve]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-controllers"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alert ──────────────────────────────────────────────────────────

wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 480
show_alert "KubePodCrashLooping" "${NAMESPACE}"

# ── Wait for pipeline ──────────────────────────────────────────────────────

wait_for_rr "${NAMESPACE}" 120
_poll_rc=0
poll_pipeline "${NAMESPACE}" 720 "${APPROVE_MODE}" || _poll_rc=$?

# ── Assertions ──────────────────────────────────────────────────────────────

log_phase "Running assertions..."

rr_phase=$(get_rr_phase "${NAMESPACE}")
rr_name=$(get_rr_name "${NAMESPACE}")
aa_name="ai-${rr_name}"

assert_in "$rr_phase" "RR phase" "Completed" "ManualReviewRequired" "Failed"

sp_phase=$(get_sp_phase "${NAMESPACE}")
assert_eq "$sp_phase" "Completed" "SP phase"

aa_phase=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

human_reason=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.humanReviewReason}' 2>/dev/null || echo "")

if [ "$rr_phase" = "Failed" ] && [ "$human_reason" = "low_confidence" ]; then
    log_phase "RR failed due to low_confidence — valid production outcome"

    workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
    if [ -n "$workflow_id" ]; then
        bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
          -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
        assert_contains "$bundle" "increase-memory-limits-job" "AA selected correct workflow (low confidence)"
    fi

elif [ "$rr_phase" = "ManualReviewRequired" ]; then
    log_phase "RR escalated to ManualReviewRequired — valid outcome"

    workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
    if [ -n "$workflow_id" ]; then
        bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
          -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
        assert_contains "$bundle" "increase-memory-limits-job" "AA selected correct workflow (escalated)"
    fi

else
    assert_eq "$aa_phase" "Completed" "AA phase"

    rr_outcome=$(get_rr_outcome "${NAMESPACE}")
    assert_in "$rr_outcome" "RR outcome" "Remediated" "Inconclusive"

    workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
    assert_neq "$workflow_id" "" "AA selected a workflow"

    bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
    assert_contains "$bundle" "increase-memory-limits-job" "AA selected IncreaseMemoryLimits workflow"

    confidence=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.confidence}' 2>/dev/null || echo "0")
    assert_neq "$confidence" "" "AA confidence present"

    wfe_phase=$(get_wfe_phase "${NAMESPACE}")
    assert_eq "$wfe_phase" "Completed" "WFE phase"
fi

# ── Post-remediation: remove ConfigMap flood so operator stabilizes ────────
log_phase "Removing ConfigMap flood (root cause fix)..."
kubectl delete configmaps -n "${NAMESPACE}" -l "" --field-selector='metadata.name!=kube-root-ca.crt' \
  --ignore-not-found 2>/dev/null || true
for i in $(seq 1 100); do
    kubectl delete configmap "app-config-${i}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null &
    [ $((i % 20)) -eq 0 ] && wait
done
wait

print_result "operator-oomkill-informer"
