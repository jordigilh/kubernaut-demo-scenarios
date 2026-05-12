#!/usr/bin/env bash
# Validate image-pull-failure scenario pipeline outcome.
# Called by run-scenario.sh or standalone:
#   ./scenarios/image-pull-failure/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-imagepull"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

for rr in $(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.status.overallPhase}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep "=Blocked=${NAMESPACE}" | cut -d= -f1); do
    kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
done

wait_for_alert "ImagePullBackOffPersistent" "${NAMESPACE}" 480
show_alert "ImagePullBackOffPersistent" "${NAMESPACE}"

wait_for_rr "${NAMESPACE}" 120
poll_pipeline "${NAMESPACE}" 600 "${APPROVE_MODE}"

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

workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
assert_neq "$workflow_id" "" "AA selected a workflow"

bundle=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || echo "")
assert_contains "$bundle" "refresh-pull-secret-job" "AA selected correct workflow"

confidence=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.confidence}' 2>/dev/null || echo "")
assert_neq "$confidence" "" "AA confidence present"

wfe_phase=$(get_wfe_phase "${NAMESPACE}")
assert_eq "$wfe_phase" "Completed" "WFE phase"

healthy_pods=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | grep -c "Running" || true)
assert_gt "${healthy_pods:-0}" "0" "At least 1 healthy Running pod"

stuck_pull=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | grep -c "ImagePullBackOff" || true)
assert_eq "${stuck_pull:-0}" "0" "No pods in ImagePullBackOff"

print_result "image-pull-failure"
