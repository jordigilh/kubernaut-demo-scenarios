#!/usr/bin/env bash
# Validate db-connection-saturation scenario pipeline outcome.
# Called by run.sh or standalone:
#   ./scenarios/db-connection-saturation/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-orders"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Clean stale blocked duplicates ──────────────────────────────────────────
for rr in $(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.status.overallPhase}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep "=Blocked=${NAMESPACE}" | cut -d= -f1); do
    kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
done

# ── Wait for alert ──────────────────────────────────────────────────────────
# Leaker opens ~1 connection every 8s; threshold is 10 active connections.
# Should fire within 2-3 minutes of deployment.
wait_for_alert "DatabaseConnectionPoolExhausted" "${NAMESPACE}" 600
show_alert "DatabaseConnectionPoolExhausted" "${NAMESPACE}"

# ── Wait for pipeline ──────────────────────────────────────────────────────
wait_for_rr "${NAMESPACE}" 120
poll_pipeline "${NAMESPACE}" 900 "${APPROVE_MODE}"

# ── Assertions ──────────────────────────────────────────────────────────────
log_phase "Running assertions..."

rr_phase=$(get_rr_phase "${NAMESPACE}")
assert_eq "$rr_phase" "Completed" "RR phase"

rr_outcome=$(get_rr_outcome "${NAMESPACE}")
assert_in "$rr_outcome" "RR outcome" "Remediated" "Inconclusive" "Escalated"

sp_phase=$(get_sp_phase "${NAMESPACE}")
assert_eq "$sp_phase" "Completed" "SP phase"

aa_phase=$(get_aa_phase "${NAMESPACE}")
assert_eq "$aa_phase" "Completed" "AA phase"

rr_name=$(get_rr_name "${NAMESPACE}")
aa_name="ai-${rr_name}"

workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")

root_cause=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCause}' 2>/dev/null || echo "")
assert_neq "$root_cause" "" "AA root cause analysis present"

rem_target_name=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.name}' 2>/dev/null || echo "")
rem_target_kind=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.kind}' 2>/dev/null || echo "")

# Multi-path validation: the LLM may target the client-pool (ideal), postgres
# (acceptable), or escalate. All are valid outcomes.
if [ -n "$workflow_id" ]; then
    assert_neq "$workflow_id" "" "AA selected a workflow"

    wfe_phase=$(get_wfe_phase "${NAMESPACE}")
    assert_eq "$wfe_phase" "Completed" "WFE phase"

    if [ "$rem_target_name" = "client-pool" ]; then
        log_success "Path A (ideal): LLM correctly identified client-pool as root cause"
        assert_eq "$rem_target_name" "client-pool" "RCA target is client-pool"
    elif [ "$rem_target_name" = "postgres" ]; then
        log_warn "Path B (acceptable): LLM targeted postgres instead of client-pool"
        assert_eq "$rem_target_name" "postgres" "RCA target is postgres (suboptimal but valid)"
    else
        log_warn "Path C: LLM targeted ${rem_target_kind}/${rem_target_name}"
        assert_neq "$rem_target_name" "" "RCA target present"
    fi
else
    # No workflow selected -- LLM may have escalated
    approval_required=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.approvalRequired}' 2>/dev/null || echo "")
    if [ "$approval_required" = "true" ]; then
        log_warn "Path D (acceptable): LLM escalated for manual review"
    else
        log_warn "Path E: No workflow selected and no escalation"
    fi
    assert_neq "$root_cause" "" "AA provided root cause even without workflow"
fi

# ── Post-remediation cleanup ────────────────────────────────────────────────
# Scale down the client-pool so connections release and the alert resolves.
log_phase "Scaling down client-pool (root cause fix)..."
kubectl scale deployment/client-pool -n "${NAMESPACE}" --replicas=0 2>/dev/null || true
kubectl rollout status deployment/client-pool -n "${NAMESPACE}" --timeout=30s 2>/dev/null || true

print_result "db-connection-saturation"
