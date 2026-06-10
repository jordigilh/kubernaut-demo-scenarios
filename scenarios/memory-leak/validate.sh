#!/usr/bin/env bash
# Validate memory-leak scenario (#129) pipeline outcome.
# Called by run-scenario.sh or standalone:
#   ./scenarios/memory-leak/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-telemetry"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Clean stale blocked duplicates ──────────────────────────────────────────
# If the alert re-fires after a prior successful remediation, blocked
# duplicate RRs can confuse _find_rr_name (which picks the newest).
# Remove any Blocked RRs before starting the validation.

for rr in $(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.status.overallPhase}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep "=Blocked=${NAMESPACE}" | cut -d= -f1); do
    kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
done

# ── Wait for alert ──────────────────────────────────────────────────────────
# predict_linear needs ~5-7 minutes of trend data before projecting OOM

wait_for_alert "ContainerMemoryExhaustionPredicted" "${NAMESPACE}" 600
show_alert "ContainerMemoryExhaustionPredicted" "${NAMESPACE}"

# ── Wait for pipeline ──────────────────────────────────────────────────────

wait_for_rr "${NAMESPACE}" 120
_poll_rc=0
poll_pipeline "${NAMESPACE}" 720 "${APPROVE_MODE}" || _poll_rc=$?

# ── Assertions ──────────────────────────────────────────────────────────────

log_phase "Running assertions..."

rr_phase=$(get_rr_phase "${NAMESPACE}")
rr_name=$(get_rr_name "${NAMESPACE}")
aa_name="ai-${rr_name}"

# The platform routes low-confidence selections to Failed (not
# ManualReviewRequired) when needsHumanReview=true. All three terminal
# states are valid for this scenario.
assert_in "$rr_phase" "RR phase" "Completed" "ManualReviewRequired" "Failed"

sp_phase=$(get_sp_phase "${NAMESPACE}")
assert_eq "$sp_phase" "Completed" "SP phase"

aa_phase=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

human_reason=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.humanReviewReason}' 2>/dev/null || echo "")

if [ "$rr_phase" = "Failed" ] && [ "$human_reason" = "low_confidence" ]; then
    # LLM confidence was below threshold — platform rejected the workflow.
    # This is a valid production outcome: the LLM identified the correct
    # mitigation but wasn't confident enough to execute it autonomously.
    log_phase "RR failed due to low_confidence — valid production outcome"

    workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
    if [ -n "$workflow_id" ]; then
        bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
          -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
        assert_contains "$bundle" "graceful-restart-job" "AA selected correct workflow (low confidence)"
    fi

    assert_eq "$human_reason" "low_confidence" "Rejection reason is low_confidence"

elif [ "$rr_phase" = "ManualReviewRequired" ]; then
    log_phase "RR escalated to ManualReviewRequired (low confidence) — valid outcome"

    workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
    if [ -n "$workflow_id" ]; then
        bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
          -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
        assert_contains "$bundle" "graceful-restart-job" "AA selected correct workflow (escalated)"
    fi

    human_reason=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.humanReviewReason}' 2>/dev/null || echo "")
    assert_eq "$human_reason" "low_confidence" "Escalation reason is low_confidence"
else
    assert_eq "$aa_phase" "Completed" "AA phase"

    rr_outcome=$(get_rr_outcome "${NAMESPACE}")
    assert_in "$rr_outcome" "RR outcome" "Remediated" "Inconclusive"

    workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
    assert_neq "$workflow_id" "" "AA selected a workflow"

    bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
    assert_contains "$bundle" "graceful-restart-job" "AA selected correct workflow"

    confidence=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.selectedWorkflow.confidence}' 2>/dev/null || echo "0")
    assert_neq "$confidence" "" "AA confidence present"

    wfe_phase=$(get_wfe_phase "${NAMESPACE}")
    assert_eq "$wfe_phase" "Completed" "WFE phase"

    for _i in $(seq 1 6); do
      rollout_rev=$(kubectl rollout history deployment/data-service -n "${NAMESPACE}" 2>/dev/null \
        | grep -c "^[0-9]" || echo "0")
      [ "$rollout_rev" -gt 1 ] && break
      sleep 5
    done
    assert_gt "$rollout_rev" "1" "Deployment has >1 revision (restart occurred)"
fi

# ── Post-remediation root cause fix ─────────────────────────────────────────
# Remove data-processor sidecar so memory stops growing and the alert resolves naturally.
log_phase "Removing data-processor sidecar (root cause fix)..."
kubectl patch deployment data-service -n "${NAMESPACE}" --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/1"}]' 2>/dev/null || true
kubectl rollout status deployment/data-service -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true

print_result "memory-leak"
