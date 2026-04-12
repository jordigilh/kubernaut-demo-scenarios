#!/usr/bin/env bash
# Validate disk-pressure-emptydir scenario (#324) pipeline outcome.
# PredictedDiskPressure (proactive, BR-SP-106) -> SP normalizes to DiskPressure ->
# AI Analysis selects MigrateEmptyDirToPVC -> RAR ->
# AWX playbook migrates emptyDir to PVC via GitOps -> EA verifies.
#
# Called by run-scenario.sh or standalone:
#   ./scenarios/disk-pressure-emptydir/validate.sh [--auto-approve]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-diskpressure"
PIPELINE_TIMEOUT=1200
APPROVE_MODE="${1:---auto-approve}"

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

# ── Wait for alert ──────────────────────────────────────────────────────────

wait_for_alert "PredictedDiskPressure" "" 600
show_alert "PredictedDiskPressure" ""

# ── Wait for RR and poll pipeline ───────────────────────────────────────────

wait_for_rr "${NAMESPACE}" 180
poll_pipeline "${NAMESPACE}" "${PIPELINE_TIMEOUT}" "${APPROVE_MODE}"

# ── Assertions ──────────────────────────────────────────────────────────────

log_phase "Running assertions..."

rr_phase=$(get_rr_phase "${NAMESPACE}")
assert_eq "$rr_phase" "Completed" "RR phase"

rr_outcome=$(get_rr_outcome "${NAMESPACE}")
assert_eq "$rr_outcome" "Remediated" "RR outcome"

rr_name=$(get_rr_name "${NAMESPACE}")
aa_name="ai-${rr_name}"
workflow_id=$(kubectl get aianalyses "${aa_name}" -n "${PLATFORM_NS}" \
  -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || echo "")
assert_neq "$workflow_id" "" "AA selected a workflow"

# Resolve the workflow name from the selected workflowId.
# The workflowId is the platform's internal ID stored in status.workflowId,
# not the Kubernetes metadata.uid.
wf_name=$(kubectl get remediationworkflows -n "${PLATFORM_NS}" \
  -o jsonpath="{.items[?(@.status.workflowId==\"${workflow_id}\")].metadata.name}" 2>/dev/null || true)
if [ -z "$wf_name" ]; then
    wf_name=$(kubectl get remediationworkflows -n kubernaut-workflows \
      -o jsonpath="{.items[?(@.status.workflowId==\"${workflow_id}\")].metadata.name}" 2>/dev/null || true)
fi
assert_contains "${wf_name}" "migrate-emptydir-to-pvc" "AA selected correct workflow"

# Verify the workflow execution used the ansible engine
wfe_name=$(kubectl get wfe -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.kubernaut\.ai/source-namespace}{"\n"}{end}' 2>/dev/null \
  | grep "=${NAMESPACE}$" | head -1 | cut -d= -f1 || true)
if [ -n "$wfe_name" ]; then
    wfe_engine=$(kubectl get wfe "${wfe_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.spec.workflowRef.engine}' 2>/dev/null || echo "")
    assert_eq "$wfe_engine" "ansible" "WFE engine"
fi

# Verify DiskPressure never materialized (proactive) or resolved (fallback reactive)
node_pressure=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="DiskPressure")].status}{"\n"}{end}' 2>/dev/null \
  | grep -c "True" || true)
assert_eq "${node_pressure}" "0" "No nodes with DiskPressure"

# Verify PostgreSQL is now using PVC
pvc_exists=$(kubectl get pvc postgres-data -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l || true)
assert_gt "${pvc_exists}" "0" "PVC postgres-data exists"

# Verify PostgreSQL pod is running
healthy_pods=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres-emptydir --no-headers 2>/dev/null \
  | grep -c "Running" || true)
assert_gt "${healthy_pods:-0}" "0" "At least 1 healthy Running postgres pod"

# Verify data survived migration
row_count=$(kubectl exec -n "${NAMESPACE}" deploy/postgres-emptydir -- \
  psql -U postgres -d postgres -t -c "SELECT count(*) FROM events;" 2>/dev/null \
  | tr -d ' ' || echo "0")
assert_gt "${row_count}" "0" "Database has rows after migration (data survived)"

print_result "disk-pressure-emptydir"
