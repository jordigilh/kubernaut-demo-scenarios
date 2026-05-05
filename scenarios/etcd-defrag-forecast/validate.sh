#!/usr/bin/env bash
# Validate etcd-defrag-forecast scenario pipeline outcome.
# Tests: predictive etcd defrag with LLM investigation + manual approval + rolling defrag.
#
# Called by run.sh or standalone:
#   ./scenarios/etcd-defrag-forecast/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-etcd-defrag"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alert ──────────────────────────────────────────────────────────
wait_for_alert "EtcdHighFragmentationRatio" "${NAMESPACE}" 600
show_alert "EtcdHighFragmentationRatio" "${NAMESPACE}"

# ── Wait for pipeline ──────────────────────────────────────────────────────
wait_for_rr "${NAMESPACE}" 180
poll_pipeline "${NAMESPACE}" 900 "${APPROVE_MODE}"

# ── Assertions ──────────────────────────────────────────────────────────────
log_phase "Running assertions..."

rr_phase=$(get_rr_phase "${NAMESPACE}")
assert_eq "$rr_phase" "Completed" "RR phase"

rr_outcome=$(get_rr_outcome "${NAMESPACE}")
assert_eq "$rr_outcome" "Remediated" "RR outcome"

sp_phase=$(get_sp_phase "${NAMESPACE}")
assert_eq "$sp_phase" "Completed" "SP phase"

aa_phase=$(get_aa_phase "${NAMESPACE}")
assert_eq "$aa_phase" "Completed" "AA phase"

rr_name=$(get_rr_name "${NAMESPACE}")
aa_name="ai-${rr_name}"

# Verify LLM identified defrag as the action
workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
assert_neq "$workflow_id" "" "AA selected a workflow"

bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
assert_contains "$bundle" "defrag-etcd" "AA selected defrag-etcd workflow"

# Verify manual approval was required (production + critical component)
approval=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.approvalRequired}' 2>/dev/null || echo "")
assert_eq "$approval" "true" "Manual approval was required"

# Verify RCA mentions fragmentation
rca_summary=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.summary}' 2>/dev/null || echo "")
if echo "$rca_summary" | grep -iq "frag\|defrag\|compact\|database size"; then
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1)); _ASSERT_PASS=$((_ASSERT_PASS + 1))
    log_success "[PASS] RCA mentions fragmentation/defrag"
else
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1)); _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
    log_error "[FAIL] RCA does not mention fragmentation (got: ${rca_summary:0:100})"
fi

# Verify RCA target is the etcd StatefulSet
rem_target_kind=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.kind}' 2>/dev/null || echo "")
rem_target_name=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.name}' 2>/dev/null || echo "")
assert_in "$rem_target_kind" "RCA target kind" "StatefulSet" "Pod"
assert_eq "$rem_target_name" "etcd" "RCA target name is etcd"

wfe_phase=$(get_wfe_phase "${NAMESPACE}")
assert_eq "$wfe_phase" "Completed" "WFE phase"

# Post-remediation: verify fragmentation ratio decreased
log_phase "Checking post-defrag fragmentation ratio..."
sleep 15
FRAG_OK=false
for pod in etcd-0 etcd-1 etcd-2; do
    SIZE_INFO=$(kubectl exec "$pod" -n "${NAMESPACE}" -- sh -c \
      "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 endpoint status --write-out=json" 2>/dev/null || echo "{}")
    DB_SIZE=$(echo "$SIZE_INFO" | grep -o '"dbSize":[0-9]*' | head -1 | cut -d: -f2)
    DB_IN_USE=$(echo "$SIZE_INFO" | grep -o '"dbSizeInUse":[0-9]*' | head -1 | cut -d: -f2)
    if [ -n "$DB_SIZE" ] && [ "$DB_SIZE" -gt 0 ]; then
        FRAG_PCT=$(( (DB_SIZE - DB_IN_USE) * 100 / DB_SIZE ))
        log_phase "  ${pod}: fragmentation=${FRAG_PCT}%"
        if [ "$FRAG_PCT" -lt 30 ]; then
            FRAG_OK=true
        fi
    fi
done

if [ "$FRAG_OK" = "true" ]; then
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1)); _ASSERT_PASS=$((_ASSERT_PASS + 1))
    log_success "[PASS] Post-defrag fragmentation < 30% on at least one member"
else
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1)); _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
    log_error "[FAIL] Post-defrag fragmentation still >= 30% on all members"
fi

print_result "etcd-defrag-forecast"
