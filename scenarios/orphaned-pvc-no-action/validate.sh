#!/usr/bin/env bash
# Validate orphaned-pvc-no-action scenario (#60, #122) pipeline outcome.
#
# Three valid paths (LLM is non-deterministic):
#   A) LLM says not actionable       → NoActionRequired, PVCs remain
#   B) LLM selects CleanupPVC + warns → has_warnings Rego → AwaitingApproval
#   C) LLM selects CleanupPVC        → executes cleanup   → Remediated, PVCs gone
#
# Called by run-scenario.sh or standalone:
#   ./scenarios/orphaned-pvc-no-action/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-orphaned-pvc"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alert ──────────────────────────────────────────────────────────

wait_for_alert "KubePersistentVolumeClaimOrphaned" "${NAMESPACE}" 480
show_alert "KubePersistentVolumeClaimOrphaned" "${NAMESPACE}"

# ── Wait for pipeline ──────────────────────────────────────────────────────

wait_for_rr "${NAMESPACE}" 120
poll_pipeline "${NAMESPACE}" 480 "${APPROVE_MODE}"

# ── Determine which path the LLM took ──────────────────────────────────────

log_phase "Running assertions..."

rr_phase=$(get_rr_phase "${NAMESPACE}")
rr_outcome=$(get_rr_outcome "${NAMESPACE}")

aa_workflow_id=$(kubectl get aianalyses "ai-$(get_rr_name "${NAMESPACE}")" \
  -n "${PLATFORM_NS}" -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")

sp_phase=$(get_sp_phase "${NAMESPACE}")
assert_eq "$sp_phase" "Completed" "SP phase"

aa_phase=$(get_aa_phase "${NAMESPACE}")
assert_eq "$aa_phase" "Completed" "AA phase"

assert_eq "$rr_phase" "Completed" "RR phase"

if [ -z "${aa_workflow_id}" ]; then
    # Path A: LLM determined no action needed
    log_phase "Path A detected: LLM said not actionable → NoActionRequired"

    assert_eq "$rr_outcome" "NoActionRequired" "RR outcome"

    pvc_count=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "$pvc_count" "5" "Orphaned PVCs still present (no-action path)"

    wfe_phase=$(get_wfe_phase "${NAMESPACE}")
    assert_eq "$wfe_phase" "" "WFE should not exist"

    ea_phase=$(get_ea_phase "${NAMESPACE}")
    assert_eq "$ea_phase" "" "EA should not exist"

elif [ "$rr_outcome" = "Remediated" ]; then
    # Path C: LLM selected CleanupPVC without warnings, workflow executed
    log_phase "Path C detected: LLM selected CleanupPVC → Remediated"

    pvc_count=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "$pvc_count" "0" "Orphaned PVCs cleaned by workflow"

    wfe_phase=$(get_wfe_phase "${NAMESPACE}")
    assert_eq "$wfe_phase" "Completed" "WFE phase"

    ea_phase=$(get_ea_phase "${NAMESPACE}")
    assert_eq "$ea_phase" "Completed" "EA phase"

else
    # Path B: LLM selected workflow but warned — has_warnings Rego fires
    log_phase "Path B detected: LLM selected workflow with warnings → AwaitingApproval"

    assert_in "$rr_outcome" "RR outcome" "" "NoActionRequired" "Remediated"

    approval_reason=$(kubectl get aianalyses "ai-$(get_rr_name "${NAMESPACE}")" \
      -n "${PLATFORM_NS}" -o jsonpath='{.status.approvalReason}' 2>/dev/null || echo "")

    if [ -n "$approval_reason" ]; then
        assert_contains "$approval_reason" "no remediation warranted" "Approval reason reflects LLM warning signal"
    fi
fi

print_result "orphaned-pvc-no-action"
