#!/usr/bin/env bash
# Validate cascading-service-failure scenario pipeline outcome.
# Tests RO target-based dedup: two RRs converge on same RemediationTarget
# (Deployment/postgres) → ResourceBusy blocks the second → one WFE runs.
#
# Called by run.sh or standalone:
#   ./scenarios/cascading-service-failure/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-fulfillment"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alerts ─────────────────────────────────────────────────────────
# Two KubePodCrashLooping alerts expected (one per dependent app).
wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 600
show_alert "KubePodCrashLooping" "${NAMESPACE}"

# ── Wait for both RRs ──────────────────────────────────────────────────────
# Two RRs should be created -- one for each crashing app.
log_phase "Waiting for RemediationRequests (expecting 2)..."

# Wait for at least one RR first
wait_for_rr "${NAMESPACE}" 180

# Poll until we see 2 RRs or timeout
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

# ── Poll pipelines ──────────────────────────────────────────────────────────
# Poll the first (non-blocked) RR's pipeline. The second may be Blocked
# immediately after AI Analysis or may spin in Analyzing until the first
# WFE completes.
poll_pipeline "${NAMESPACE}" 900 "${APPROVE_MODE}"

# Give the second RR time to reach its terminal state
sleep 30

# ── Assertions ──────────────────────────────────────────────────────────────
log_phase "Running assertions..."

# Get all RRs for this namespace
all_rrs=$(kubectl get rr -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.overallPhase}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' -v ns="${NAMESPACE}" '$3 == ns { print $1 "\t" $2 }')

rr_total=$(echo "$all_rrs" | grep -c . || echo "0")
assert_gt "$rr_total" "1" "At least 2 RRs created for cascading failure"

# Count non-blocked (Completed) and blocked RRs
completed_rrs=$(echo "$all_rrs" | grep -c "Completed" || echo "0")
blocked_rrs=$(echo "$all_rrs" | grep -c "Blocked" || echo "0")

log_phase "RR states: ${completed_rrs} Completed, ${blocked_rrs} Blocked (total: ${rr_total})"

# Primary assertion: at least one completed, at least one blocked with ResourceBusy
assert_gt "$completed_rrs" "0" "At least 1 RR Completed (remediation executed)"

if [ "$blocked_rrs" -gt 0 ]; then
    # Ideal path: ResourceBusy dedup worked
    log_success "ResourceBusy dedup confirmed: ${blocked_rrs} RR(s) blocked"

    # Verify the block reason is ResourceBusy
    blocked_rr_name=$(echo "$all_rrs" | awk -F'\t' '$2 == "Blocked" { print $1; exit }')
    if [ -n "$blocked_rr_name" ]; then
        block_reason=$(kubectl get rr "$blocked_rr_name" -n "${PLATFORM_NS}" \
          -o jsonpath='{.status.blockReason}' 2>/dev/null || echo "")
        assert_eq "$block_reason" "ResourceBusy" "Blocked RR reason is ResourceBusy"
    fi
else
    # Acceptable fallback: both completed (LLM picked different targets)
    log_warn "No Blocked RRs -- LLM may have identified different targets for each app"
fi

# Verify AI Analysis identified postgres as root cause for the completed RR
rr_name=$(get_rr_name "${NAMESPACE}")
aa_name="ai-${rr_name}"

aa_phase=$(get_aa_phase "${NAMESPACE}")
assert_eq "$aa_phase" "Completed" "AA phase"

rem_target_name=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.name}' 2>/dev/null || echo "")
rem_target_kind=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.kind}' 2>/dev/null || echo "")

assert_in "$rem_target_name" "AA RCA target name" "postgres" "postgres-config"
assert_in "$rem_target_kind" "AA RCA target kind" "Deployment" "StatefulSet" "ConfigMap"

# Verify WFE targeted postgres
wfe_phase=$(get_wfe_phase "${NAMESPACE}")
assert_eq "$wfe_phase" "Completed" "WFE phase"

# Exactly 1 WFE should exist (dedup prevents the second)
wfe_count=$(kubectl get wfe -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.spec.targetResource}{"\n"}{end}' 2>/dev/null \
  | grep -c "${NAMESPACE}" || echo "0")
assert_eq "$wfe_count" "1" "Exactly 1 WFE created (dedup prevented second)"

# After remediation, postgres should recover and apps should stop crash-looping
log_phase "Checking post-remediation recovery..."
sleep 15
pg_ready=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres --no-headers 2>/dev/null \
  | grep -c "Running" || echo "0")
assert_gt "$pg_ready" "0" "postgres pod Running after remediation"

print_result "cascading-service-failure"
