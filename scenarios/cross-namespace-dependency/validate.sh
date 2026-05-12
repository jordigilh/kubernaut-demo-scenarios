#!/usr/bin/env bash
# Validate cross-namespace-dependency scenario pipeline outcome.
# Tests LLM ability to trace RCA across namespace boundaries:
# alert fires in demo-xns-app, root cause is Deployment/postgres in demo-xns-infra.
#
# Called by run.sh or standalone:
#   ./scenarios/cross-namespace-dependency/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_NS="demo-xns-infra"
APP_NS="demo-xns-app"
NAMESPACE="${APP_NS}"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alerts ─────────────────────────────────────────────────────────
wait_for_alert "KubePodCrashLooping" "${APP_NS}" 600
show_alert "KubePodCrashLooping" "${APP_NS}"

# ── Wait for RR ─────────────────────────────────────────────────────────────
wait_for_rr "${APP_NS}" 180
poll_pipeline "${APP_NS}" 900 "${APPROVE_MODE}"

# ── Assertions ──────────────────────────────────────────────────────────────
log_phase "Running assertions..."

rr_phase=$(get_rr_phase "${APP_NS}")
assert_eq "$rr_phase" "Completed" "RR phase"

rr_outcome=$(get_rr_outcome "${APP_NS}")
assert_in "$rr_outcome" "RR outcome" "Remediated" "Inconclusive" "Escalated"

sp_phase=$(get_sp_phase "${APP_NS}")
assert_eq "$sp_phase" "Completed" "SP phase"

aa_phase=$(get_aa_phase "${APP_NS}")
assert_eq "$aa_phase" "Completed" "AA phase"

rr_name=$(get_rr_name "${APP_NS}")
aa_name="ai-${rr_name}"

root_cause=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCause}' 2>/dev/null || echo "")
assert_neq "$root_cause" "" "AA root cause analysis present"

rem_target_name=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.name}' 2>/dev/null || echo "")
rem_target_kind=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.kind}' 2>/dev/null || echo "")
rem_target_ns=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.namespace}' 2>/dev/null || echo "")

# Primary assertion: RCA target is postgres in the infrastructure namespace
if [ "$rem_target_name" = "postgres" ] && [ "$rem_target_ns" = "${INFRA_NS}" ]; then
    log_success "Path A (ideal): LLM traced cross-namespace to ${INFRA_NS}/Deployment/postgres"
    assert_eq "$rem_target_name" "postgres" "RCA target name is postgres"
    assert_eq "$rem_target_ns" "${INFRA_NS}" "RCA target namespace is ${INFRA_NS} (cross-namespace trace)"
    assert_in "$rem_target_kind" "RCA target kind" "Deployment" "StatefulSet"
elif [ "$rem_target_name" = "postgres" ]; then
    log_warn "Path B (partial): LLM identified postgres but namespace may be missing or incorrect (got: ${rem_target_ns})"
    assert_eq "$rem_target_name" "postgres" "RCA target name is postgres"
elif [ -n "$rem_target_name" ]; then
    log_warn "Path C: LLM targeted ${rem_target_kind}/${rem_target_name} in ${rem_target_ns:-unknown}"
    assert_neq "$rem_target_name" "" "RCA target present"
else
    log_warn "Path D: LLM escalated or no target identified"
fi

# Verify WFE if pipeline completed with remediation
if [ "$rr_outcome" = "Remediated" ]; then
    wfe_phase=$(get_wfe_phase "${APP_NS}")
    assert_eq "$wfe_phase" "Completed" "WFE phase"

    # After remediation, postgres should recover
    log_phase "Checking post-remediation recovery..."
    sleep 15
    pg_ready=$(kubectl get pods -n "${INFRA_NS}" -l app=postgres --no-headers 2>/dev/null \
      | grep -c "Running" || echo "0")
    assert_gt "$pg_ready" "0" "postgres pod Running in ${INFRA_NS} after remediation"
fi

print_result "cross-namespace-dependency"
