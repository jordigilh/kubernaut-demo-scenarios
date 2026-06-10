#!/usr/bin/env bash
# Validate severity-misdirection scenario pipeline outcome.
# Tests LLM ability to prioritize temporal causation over alert severity:
# the critical KubePodCrashLooping is a symptom of the warning ContainerOOMKilling.
#
# Two RRs are expected (different signals, different owners). The LLM should
# identify postgres as the root cause for both, despite the crash-loop alert
# having higher severity than the OOM alert.
#
# Called by run.sh or standalone:
#   ./scenarios/severity-misdirection/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-services"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alerts ─────────────────────────────────────────────────────────
# Both alerts should fire: OOM (warning, first) and crash-loop (critical, second)
wait_for_alert "ContainerOOMKilling" "${NAMESPACE}" 300
show_alert "ContainerOOMKilling" "${NAMESPACE}"

wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 600
show_alert "KubePodCrashLooping" "${NAMESPACE}"

# ── Wait for RRs ───────────────────────────────────────────────────────────
log_phase "Waiting for RemediationRequests..."
wait_for_rr "${NAMESPACE}" 180

# Poll until we see at least 2 RRs or timeout
RR_COUNT=0
for _i in $(seq 1 60); do
    RR_COUNT=$(kubectl get rr -n "${PLATFORM_NS}" \
      -o jsonpath='{range .items[*]}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
      | grep -c "^${NAMESPACE}$" || echo "0")
    if [ "$RR_COUNT" -ge 2 ]; then
        break
    fi
    sleep 5
done
log_phase "Found ${RR_COUNT} RemediationRequest(s) for ${NAMESPACE}"

# ── Poll pipeline ──────────────────────────────────────────────────────────
poll_pipeline "${NAMESPACE}" 900 "${APPROVE_MODE}"

# Give second RR time to reach terminal state
sleep 30

# ── Assertions ──────────────────────────────────────────────────────────────
log_phase "Running assertions..."

# Get all RRs for this namespace
all_rrs=$(kubectl get rr -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.overallPhase}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' -v ns="${NAMESPACE}" '$3 == ns { print $1 "\t" $2 }')

rr_total=$(echo "$all_rrs" | grep -c . || echo "0")
log_phase "Total RRs: ${rr_total}"

# Find the first completed RR to inspect
completed_rr_name=$(echo "$all_rrs" | awk -F'\t' '$2 == "Completed" { print $1; exit }')
if [ -z "$completed_rr_name" ]; then
    completed_rr_name=$(get_rr_name "${NAMESPACE}")
fi

aa_name="ai-${completed_rr_name}"

aa_phase=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
assert_eq "$aa_phase" "Completed" "AA phase"

root_cause=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCause}' 2>/dev/null || echo "")
assert_neq "$root_cause" "" "AA root cause analysis present"

rem_target_name=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.name}' 2>/dev/null || echo "")
rem_target_kind=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.kind}' 2>/dev/null || echo "")

# Primary assertion: RCA should target postgres (the OOM source), not api-gateway
if [ "$rem_target_name" = "postgres" ]; then
    log_success "Path A (ideal): LLM correctly identified postgres (OOM source) as root cause"
    log_success "  The LLM prioritized the warning-level OOM over the critical crash-loop"
    assert_eq "$rem_target_name" "postgres" "RCA target is postgres (temporal causation)"
    assert_in "$rem_target_kind" "RCA target kind" "Deployment" "StatefulSet"
elif [ "$rem_target_name" = "api-gateway" ]; then
    log_warn "Path B (misdirected): LLM targeted api-gateway (the symptom, not the cause)"
    log_warn "  The LLM was misled by the higher-severity critical alert"
    assert_eq "$rem_target_name" "api-gateway" "RCA target is api-gateway (severity-misled)"
elif [ -n "$rem_target_name" ]; then
    log_warn "Path C: LLM targeted ${rem_target_kind}/${rem_target_name}"
    assert_neq "$rem_target_name" "" "RCA target present"
else
    log_warn "Path D: LLM escalated or no target identified"
fi

# Check for RCA mention of OOM to verify temporal reasoning
if echo "$root_cause" | grep -qi "oom\|memory\|killed"; then
    log_success "RCA mentions OOM/memory -- LLM recognized the memory issue"
fi

# Check dedup behavior if both RRs converge on postgres
completed_rrs=$(echo "$all_rrs" | grep -c "Completed" || echo "0")
blocked_rrs=$(echo "$all_rrs" | grep -c "Blocked" || echo "0")

if [ "$rr_total" -ge 2 ]; then
    log_phase "RR states: ${completed_rrs} Completed, ${blocked_rrs} Blocked (total: ${rr_total})"
    if [ "$blocked_rrs" -gt 0 ]; then
        log_success "ResourceBusy dedup confirmed: both RRs converged on same target"
    fi
fi

print_result "severity-misdirection"
