#!/usr/bin/env bash
# Validate memory-escalation scenario (#168) pipeline outcome.
# OOMKill -> increase limits -> OOMKill again -> escalation after N cycles.
#
# This scenario runs multiple cycles. We validate that:
# 1. The first cycle completes (Remediated with IncreaseMemoryLimits)
# 2. Eventually a Blocked/Skipped RR appears (ConsecutiveFailures escalation)
#
# Called by run-scenario.sh or standalone:
#   ./scenarios/memory-escalation/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-memory-escalation"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alert ──────────────────────────────────────────────────────────

wait_for_alert "ContainerOOMKilling" "${NAMESPACE}" 480
show_alert "ContainerOOMKilling" "${NAMESPACE}"

# ── Wait for first cycle pipeline ──────────────────────────────────────────

wait_for_rr "${NAMESPACE}" 120

# Capture the first RR name before poll_pipeline (a second RR may be created
# mid-cycle, confusing _find_rr_name which uses tail -1).
rr_name=$(get_rr_name "${NAMESPACE}")
aa_name="ai-${rr_name}"

# poll_pipeline may exit non-zero in multi-cycle scenarios when a second RR
# appears mid-flight (confuses internal _find_rr_name). Tolerate this since
# we verify the first RR's state explicitly in the assertions below.
poll_pipeline "${NAMESPACE}" 600 "${APPROVE_MODE}" || true

# ── Assertions for first cycle ──────────────────────────────────────────────

log_phase "Running first-cycle assertions..."

rr_phase=$(kubectl get rr "$rr_name" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.overallPhase}' 2>/dev/null || echo "")
assert_eq "$rr_phase" "Completed" "First RR phase"

rr_outcome=$(kubectl get rr "$rr_name" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.outcome}' 2>/dev/null || echo "")
if [ "$rr_outcome" = "Remediated" ] || [ "$rr_outcome" = "Inconclusive" ]; then
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1))
    _ASSERT_PASS=$((_ASSERT_PASS + 1))
    printf '           %s[PASS]%s First RR outcome = %s (Remediated or Inconclusive both valid)\n' \
        "$_c_green" "$_c_reset" "$rr_outcome"
else
    assert_eq "$rr_outcome" "Remediated" "First RR outcome"
fi
workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
assert_neq "$workflow_id" "" "AA selected a workflow"

bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
if echo "$bundle" | grep -q "increase-memory-limits-job"; then
    FIRST_WORKFLOW="increase-memory-limits"
    assert_contains "$bundle" "increase-memory-limits-job" "AA selected IncreaseMemoryLimits workflow"
elif echo "$bundle" | grep -q "graceful-restart-job"; then
    FIRST_WORKFLOW="graceful-restart"
    assert_contains "$bundle" "graceful-restart-job" "AA selected GracefulRestart workflow (alternate valid path)"
else
    FIRST_WORKFLOW="unknown"
    assert_contains "$bundle" "increase-memory-limits-job" "AA selected expected workflow"
fi

# ── Wait for escalation (subsequent cycles) ──────────────────────────────────
# The workload will OOMKill again. After 2-3 cycles, the RO should block.

log_phase "Waiting for escalation (Blocked RR after 3-4 cycles, timeout 1800s)..."
ESCALATION_TIMEOUT=1800
ESCALATION_ELAPSED=0

while [ "$ESCALATION_ELAPSED" -lt "$ESCALATION_TIMEOUT" ]; do
    # Check for Blocked/Failed phase, or Completed with ManualReviewRequired
    # (v1.2.0 transitions ManualReviewRequired to Completed, not Failed)
    blocked_rr=$(kubectl get rr -n "${PLATFORM_NS}" \
      -o jsonpath='{range .items[*]}{.metadata.name}={.status.overallPhase}={.status.outcome}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
      | grep -E "=(Blocked|Failed)=(ManualReviewRequired)?=${NAMESPACE}|=Completed=ManualReviewRequired=${NAMESPACE}" | head -1 | cut -d= -f1 || true)

    escalated_rr=$(kubectl get rr -n "${PLATFORM_NS}" \
      -o jsonpath='{range .items[*]}{.metadata.name}={.status.outcome}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
      | grep "=ManualReviewRequired=${NAMESPACE}" | head -1 | cut -d= -f1 || true)

    if [ -n "$escalated_rr" ]; then
        esc_reason=$(kubectl get rr "$escalated_rr" -n "${PLATFORM_NS}" \
          -o jsonpath='{.status.blockReason}' 2>/dev/null || echo "escalation")
        log_success "Escalation detected: RR ${escalated_rr} escalated to ManualReviewRequired (reason: ${esc_reason})"
        break
    fi

    if [ -n "$blocked_rr" ]; then
        block_reason=$(kubectl get rr "$blocked_rr" -n "${PLATFORM_NS}" \
          -o jsonpath='{.status.blockReason}' 2>/dev/null || echo "unknown")
        log_success "Escalation detected: RR ${blocked_rr} blocked (reason: ${block_reason})"
        break
    fi

    # Auto-approve intermediate RARs so subsequent cycles can progress
    if [ "${APPROVE_MODE}" = "--auto-approve" ]; then
        awaiting_rrs=$(kubectl get rr -n "${PLATFORM_NS}" \
          -o jsonpath='{range .items[*]}{.metadata.name}={.status.overallPhase}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
          | grep "=AwaitingApproval=${NAMESPACE}" | cut -d= -f1 || true)
        for awaiting_rr in $awaiting_rrs; do
            rar_decision=$(kubectl get remediationapprovalrequest "rar-${awaiting_rr}" \
              -n "${PLATFORM_NS}" -o jsonpath='{.status.decision}' 2>/dev/null || true)
            if [ "$rar_decision" != "Approved" ]; then
                auto_approve_rar "$awaiting_rr" || true
            fi
        done
    fi

    sleep 15
    ESCALATION_ELAPSED=$((ESCALATION_ELAPSED + 15))
    if [ $((ESCALATION_ELAPSED % 60)) -eq 0 ]; then
        log_phase "Still waiting for escalation... (${ESCALATION_ELAPSED}s)"
    fi
done

# ── Escalation assertions ──────────────────────────────────────────────────

log_phase "Running escalation assertions..."

escalated_count=$(kubectl get rr -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.status.outcome}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
  | { grep "^ManualReviewRequired=" || true; } | { grep "=${NAMESPACE}$" || true; } | wc -l | tr -d ' ')
blocked_count=$(kubectl get rr -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.status.overallPhase}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
  | { grep "^Blocked=" || true; } | { grep "=${NAMESPACE}$" || true; } | wc -l | tr -d ' ')
total_escalated=$(( ${escalated_count:-0} + ${blocked_count:-0} ))

total_rr=$(kubectl get rr -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
  | { grep "^${NAMESPACE}$" || true; } | wc -l | tr -d ' ')
assert_gt "${total_rr:-0}" "1" "Multiple RRs created (multi-cycle)"

assert_gt "${total_escalated}" "0" "At least 1 escalated RR (Blocked or ManualReviewRequired)"

# ── Post-escalation root cause fix ──────────────────────────────────────────
# Scale workload to 0 so OOMKills stop and alerts resolve naturally.
log_phase "Scaling ml-worker to 0 (root cause fix after escalation)..."
kubectl scale deployment/ml-worker -n "${NAMESPACE}" --replicas=0 2>/dev/null || true

print_result "memory-escalation"
