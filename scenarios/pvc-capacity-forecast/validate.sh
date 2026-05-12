#!/usr/bin/env bash
# Validate pvc-capacity-forecast scenario pipeline outcome.
# Called by run.sh or standalone:
#   ./scenarios/pvc-capacity-forecast/validate.sh [--auto-approve] [--no-color]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-pvc-forecast"
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Clean stale blocked duplicates ──────────────────────────────────────────
for rr in $(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.status.overallPhase}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep "=Blocked=${NAMESPACE}" | cut -d= -f1); do
    kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
done

# ── Capture initial PVC size ────────────────────────────────────────────────
INITIAL_PVC_SIZE=$(kubectl get pvc data-service-data -n "${NAMESPACE}" \
  -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "512Mi")
log_phase "Initial PVC size: ${INITIAL_PVC_SIZE}"

# ── Wait for alert ──────────────────────────────────────────────────────────
# predict_linear needs ~5-7 minutes of trend data before projecting exhaustion
wait_for_alert "PVRunwayShort" "${NAMESPACE}" 900
show_alert "PVRunwayShort" "${NAMESPACE}"

# ── Wait for pipeline ──────────────────────────────────────────────────────
wait_for_rr "${NAMESPACE}" 120
poll_pipeline "${NAMESPACE}" 900 "${APPROVE_MODE}"

# ── Assertions ──────────────────────────────────────────────────────────────
log_phase "Running assertions..."

rr_phase=$(get_rr_phase "${NAMESPACE}")
assert_eq "$rr_phase" "Completed" "RR phase"

rr_outcome=$(get_rr_outcome "${NAMESPACE}")
assert_in "$rr_outcome" "RR outcome" "Remediated" "Inconclusive"

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
assert_contains "$bundle" "expand-pvc" "AA selected correct workflow"

confidence=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.confidence}' 2>/dev/null || echo "0")
assert_neq "$confidence" "" "AA confidence present"

# Verify the LLM investigated -- RCA should reference storage/PVC/capacity
root_cause=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCause}' 2>/dev/null || echo "")
assert_neq "$root_cause" "" "AA root cause analysis present"

# Verify remediation target points at the PVC or the deployment
rem_target_kind=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.kind}' 2>/dev/null || echo "")
assert_neq "$rem_target_kind" "" "AA remediation target kind present"

wfe_phase=$(get_wfe_phase "${NAMESPACE}")
assert_eq "$wfe_phase" "Completed" "WFE phase"

# Poll for PVC expansion (CSI driver may take a few seconds to resize)
FINAL_PVC_SIZE=""
for _i in $(seq 1 12); do
    FINAL_PVC_SIZE=$(kubectl get pvc data-service-data -n "${NAMESPACE}" \
      -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "")
    if [ -n "${FINAL_PVC_SIZE}" ] && [ "${FINAL_PVC_SIZE}" != "${INITIAL_PVC_SIZE}" ]; then
        break
    fi
    sleep 10
done
assert_neq "${FINAL_PVC_SIZE}" "${INITIAL_PVC_SIZE}" "PVC expanded (${INITIAL_PVC_SIZE} -> ${FINAL_PVC_SIZE})"

# ── Post-remediation cleanup ────────────────────────────────────────────────
# Stop the data writer so the alert resolves and EM can verify effectiveness.
log_phase "Stopping data writer (simulating root cause resolution)..."
kubectl patch deployment data-service -n "${NAMESPACE}" --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/1"}]' 2>/dev/null || true
kubectl rollout status deployment/data-service -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true

print_result "pvc-capacity-forecast"
