#!/usr/bin/env bash
# Validate concurrent-cross-namespace scenario (#172) pipeline outcome.
# Two namespaces with different risk tolerance -> different workflow selections.
#
# Called by run-scenario.sh or standalone:
#   ./scenarios/concurrent-cross-namespace/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_ALPHA="demo-team-alpha"
NS_BETA="demo-team-beta"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Clean stale blocked duplicates ──────────────────────────────────────────

for _ns in "${NS_ALPHA}" "${NS_BETA}"; do
    for rr in $(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.status.overallPhase}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep "=Blocked=${_ns}" | cut -d= -f1); do
        kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
    done
done

# ── Wait for alerts ──────────────────────────────────────────────────────────

wait_for_alert "KubePodCrashLooping" "${NS_ALPHA}" 480
show_alert "KubePodCrashLooping" "${NS_ALPHA}"

# ── Wait for both RRs and approve Beta early so pipelines run in parallel ────
# Beta's alert fires later than Alpha (staggered injection + for: 3m + OCP
# scrape intervals), so give it more time.

log_phase "Waiting for both RemediationRequests..."
wait_for_rr "${NS_ALPHA}" 120
wait_for_rr "${NS_BETA}" 360

# Alpha (staging) is auto-approved by Rego policy — no action needed.
# Beta (production) requires manual approval — approve now so it doesn't
# block behind Alpha's EM verification window.
if [ "${APPROVE_MODE}" = "--auto-approve" ]; then
    log_phase "Pre-approving Team Beta RAR (production requires manual approval)..."
    _beta_rr=$(get_rr_name "${NS_BETA}")
    # Wait for the RAR to appear (RO creates it after AI Analysis)
    for _i in $(seq 1 60); do
        beta_phase=$(get_rr_phase "${NS_BETA}")
        if [ "$beta_phase" = "AwaitingApproval" ]; then
            auto_approve_rar "${_beta_rr}"
            break
        fi
        sleep 5
    done
fi

log_phase "Polling Team Alpha pipeline..."
poll_pipeline "${NS_ALPHA}" 600 "${APPROVE_MODE}"

log_phase "Polling Team Beta pipeline..."
poll_pipeline "${NS_BETA}" 600 "${APPROVE_MODE}"

# ── Assertions ──────────────────────────────────────────────────────────────

log_phase "Running assertions..."

alpha_phase=$(get_rr_phase "${NS_ALPHA}")
assert_eq "$alpha_phase" "Completed" "Alpha RR phase"

alpha_outcome=$(get_rr_outcome "${NS_ALPHA}")
assert_eq "$alpha_outcome" "Remediated" "Alpha RR outcome"

beta_phase=$(get_rr_phase "${NS_BETA}")
assert_eq "$beta_phase" "Completed" "Beta RR phase"

beta_outcome=$(get_rr_outcome "${NS_BETA}")
assert_eq "$beta_outcome" "Remediated" "Beta RR outcome"

alpha_rr=$(get_rr_name "${NS_ALPHA}")
alpha_workflow=$(kubectl get aianalyses "ai-${alpha_rr}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")

beta_rr=$(get_rr_name "${NS_BETA}")
beta_workflow=$(kubectl get aianalyses "ai-${beta_rr}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")

assert_neq "$alpha_workflow" "" "Alpha AA selected a workflow"
assert_neq "$beta_workflow" "" "Beta AA selected a workflow"
assert_neq "$alpha_workflow" "$beta_workflow" "Different workflows selected (risk-based)"

alpha_bundle=$(kubectl get aianalyses "ai-${alpha_rr}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
beta_bundle=$(kubectl get aianalyses "ai-${beta_rr}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")

assert_contains "$alpha_bundle" "hotfix-config-job" "Alpha selected hotfix-config workflow (high risk tolerance)"
assert_contains "$beta_bundle" "hotfix-config-job" "Beta selected hotfix-config-production workflow (low risk tolerance)"

log_info "Alpha workflow: ${alpha_workflow} (${alpha_bundle##*/})"
log_info "Beta workflow:  ${beta_workflow} (${beta_bundle##*/})"

# Mixed approval mode assertions (issue #4):
# Alpha (staging) should be auto-approved by Rego; Beta (production) should require manual approval.
alpha_approval=$(kubectl get aianalyses "ai-${alpha_rr}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.approvalRequired}' 2>/dev/null || echo "")
beta_approval=$(kubectl get aianalyses "ai-${beta_rr}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.approvalRequired}' 2>/dev/null || echo "")

assert_eq "$alpha_approval" "false" "Alpha auto-approved (staging, Rego policy)"
assert_eq "$beta_approval" "true" "Beta required manual approval (production, Rego policy)"

log_info "Alpha approval required: ${alpha_approval}"
log_info "Beta approval required:  ${beta_approval}"

print_result "concurrent-cross-namespace"
