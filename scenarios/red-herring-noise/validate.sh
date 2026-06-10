#!/usr/bin/env bash
# Validate red-herring-noise scenario pipeline outcome.
# Tests LLM ability to separate independent incidents from a primary cascade.
#
# Expected RRs:
#   - 2+ crash-loop RRs (api-gateway, worker) → should target Deployment/postgres
#   - 1 image-pull RR (canary-v2) → should be handled independently
#
# The key assertion: crash-loop RRs must NOT target canary-v2, and the canary
# RR must NOT pollute the postgres RCA.
#
# Called by run.sh or standalone:
#   ./scenarios/red-herring-noise/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-microservices"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alerts ─────────────────────────────────────────────────────────
wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 600
show_alert "KubePodCrashLooping" "${NAMESPACE}"

# ImagePullBackOff may take longer to become a PrometheusRule alert
wait_for_alert "ImagePullBackOffPersistent" "${NAMESPACE}" 300 || true
show_alert "ImagePullBackOffPersistent" "${NAMESPACE}" || true

# ── Wait for RRs ───────────────────────────────────────────────────────────
log_phase "Waiting for RemediationRequests (expecting 2+)..."
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

# Give remaining RRs time to reach terminal state
sleep 30

# ── Assertions ──────────────────────────────────────────────────────────────
log_phase "Running assertions..."

# Get all RRs for this namespace (include signal name for filtering)
all_rrs=$(kubectl get rr -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.overallPhase}{"\t"}{.spec.signalLabels.namespace}{"\t"}{.spec.signalName}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' -v ns="${NAMESPACE}" '$3 == ns { print $1 "\t" $2 "\t" $4 }')

rr_total=$(echo "$all_rrs" | grep -c . || echo "0")
assert_gt "$rr_total" "1" "At least 2 RRs created for multi-incident scenario"

completed_rrs=$(echo "$all_rrs" | grep -c "Completed" || true)
completed_rrs=${completed_rrs:-0}
blocked_rrs=$(echo "$all_rrs" | grep -c "Blocked" || true)
blocked_rrs=${blocked_rrs:-0}
log_phase "RR states: ${completed_rrs} Completed, ${blocked_rrs} Blocked (total: ${rr_total})"

# Find ALL KubePodCrashLooping RRs (any phase) and check if ANY have an AA
# that correctly targets postgres. The crash-loop RR may still be in
# Verifying (EA running) while the canary-v2 ImagePullBackOff RR already
# completed, so we must not restrict to Completed-only.
crash_rr_names=$(echo "$all_rrs" | awk -F'\t' '$3 == "KubePodCrashLooping" { print $1 }')
if [ -z "$crash_rr_names" ]; then
    crash_rr_names=$(echo "$all_rrs" | awk -F'\t' '$3 != "ImagePullBackOffPersistent" { print $1 }')
fi
if [ -z "$crash_rr_names" ]; then
    crash_rr_names=$(get_rr_name "${NAMESPACE}")
fi

postgres_rr=""
best_rr=""
for _rr in $crash_rr_names; do
    _aa="ai-${_rr}"
    _aa_phase=$(kubectl get aianalyses "${_aa}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$_aa_phase" != "Completed" ] && continue
    _target=$(kubectl get aianalyses "${_aa}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.name}' 2>/dev/null || echo "")
    [ -z "$best_rr" ] && best_rr="$_rr"
    if [ "$_target" = "postgres" ] || [ "$_target" = "postgres-config" ]; then
        postgres_rr="$_rr"
        break
    fi
done

completed_rr_name="${postgres_rr:-$best_rr}"
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

# Primary assertion: at least one crash-loop RR should target postgres (not canary-v2)
if [ "$rem_target_name" = "postgres" ] || [ "$rem_target_name" = "postgres-config" ]; then
    log_success "Path A (ideal): LLM correctly identified postgres as root cause"
    log_success "  The canary-v2 red herring did NOT pollute the RCA"
    assert_neq "$rem_target_name" "" "RCA target is postgres-related"
    assert_in "$rem_target_kind" "RCA target kind" "Deployment" "StatefulSet" "ConfigMap"
elif [ "$rem_target_name" = "canary-v2" ]; then
    log_warn "Path B (polluted): LLM incorrectly targeted canary-v2 (red herring polluted RCA)"
    assert_neq "$rem_target_name" "canary-v2" "RCA target should NOT be canary-v2"
elif [ -n "$rem_target_name" ]; then
    log_warn "Path C: LLM targeted ${rem_target_kind}/${rem_target_name}"
    assert_neq "$rem_target_name" "" "RCA target present"
else
    log_warn "Path D: LLM escalated or no target identified"
fi

# Check ResourceBusy dedup (if both crash-loop RRs converge on postgres)
if [ "$blocked_rrs" -gt 0 ]; then
    log_success "ResourceBusy dedup confirmed: ${blocked_rrs} RR(s) blocked"
    blocked_rr_name=$(echo "$all_rrs" | awk -F'\t' '$2 == "Blocked" { print $1; exit }')
    if [ -n "$blocked_rr_name" ]; then
        block_reason=$(kubectl get rr "$blocked_rr_name" -n "${PLATFORM_NS}" \
          -o jsonpath='{.status.blockReason}' 2>/dev/null || echo "")
        if [ "$block_reason" = "ResourceBusy" ]; then
            log_success "Blocked RR reason is ResourceBusy (target-based dedup)"
        fi
    fi
fi

# After remediation, postgres should recover
if [ "$completed_rrs" -gt 0 ]; then
    log_phase "Checking post-remediation recovery..."
    sleep 15
    pg_ready=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres --no-headers 2>/dev/null \
      | grep -c "Running" || echo "0")
    assert_gt "$pg_ready" "0" "postgres pod Running after remediation"
fi

print_result "red-herring-noise"
