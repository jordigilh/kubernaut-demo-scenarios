#!/usr/bin/env bash
# Validate slo-burn scenario (#151) pipeline outcome.
# Called by run-scenario.sh or standalone:
#   ./scenarios/slo-burn/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-slo"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Clean stale blocked duplicates ──────────────────────────────────────────

for rr in $(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.status.overallPhase}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep "=Blocked=${NAMESPACE}" | cut -d= -f1); do
    kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
done

# ── Wait for alert ──────────────────────────────────────────────────────────

wait_for_alert "ErrorBudgetBurn" "${NAMESPACE}" 480
show_alert "ErrorBudgetBurn" "${NAMESPACE}"

# ── Wait for pipeline ──────────────────────────────────────────────────────

wait_for_rr "${NAMESPACE}" 120

# Pin the RR name now (before duplicates can appear from re-firing alerts).
RR_NAME=$(get_rr_name "${NAMESPACE}")
poll_pipeline "${NAMESPACE}" 600 "${APPROVE_MODE}"

# ── Assertions ──────────────────────────────────────────────────────────────
# Use the pinned RR_NAME to avoid picking up a duplicate RR that may have
# been created while the burn-rate recording rule window was still decaying.

log_phase "Running assertions..."

rr_phase=$(kubectl get remediationrequests "$RR_NAME" -n "$PLATFORM_NS" \
  -o jsonpath='{.status.overallPhase}' 2>/dev/null || echo "")
assert_eq "$rr_phase" "Completed" "RR phase"

rr_outcome=$(kubectl get remediationrequests "$RR_NAME" -n "$PLATFORM_NS" \
  -o jsonpath='{.status.outcome}' 2>/dev/null || echo "")
assert_eq "$rr_outcome" "Remediated" "RR outcome"

sp_name="sp-${RR_NAME}"
sp_phase=$(kubectl get signalprocessings "$sp_name" -n "$PLATFORM_NS" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
assert_eq "$sp_phase" "Completed" "SP phase"

aa_name="ai-${RR_NAME}"
aa_phase=$(kubectl get aianalyses "$aa_name" -n "$PLATFORM_NS" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
assert_eq "$aa_phase" "Completed" "AA phase"

workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
assert_neq "$workflow_id" "" "AA selected a workflow"

bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
assert_contains "$bundle" "rollback" "AA selected rollback workflow"

confidence=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.confidence}' 2>/dev/null || echo "")
assert_neq "$confidence" "" "AA confidence present"

wfe_name="we-${RR_NAME}"
wfe_phase=$(kubectl get workflowexecutions "$wfe_name" -n "$PLATFORM_NS" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
assert_eq "$wfe_phase" "Completed" "WFE phase"

# Verify rollback occurred (deployment should have >1 revision)
rollout_rev=$(kubectl rollout history deployment/api-gateway -n "${NAMESPACE}" 2>/dev/null \
  | grep -c "^[0-9]" || echo "0")
assert_gt "$rollout_rev" "1" "Deployment has >1 revision (rollback occurred)"

healthy_pods=$(kubectl get pods -n "${NAMESPACE}" -l app=api-gateway --no-headers 2>/dev/null \
  | grep -c "Running" || true)
assert_gt "${healthy_pods:-0}" "0" "At least 1 healthy api-gateway pod Running"

print_result "slo-burn"
