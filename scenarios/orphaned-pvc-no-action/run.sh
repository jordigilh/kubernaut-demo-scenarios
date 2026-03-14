#!/usr/bin/env bash
# Orphaned PVC Demo -- No Action Required
# Scenario #122: Orphaned PVCs alert -> LLM determines no remediation needed
#
# KEY: No workflow is seeded in DataStorage for this scenario. Orphaned PVCs
# are housekeeping, not a real operational issue. The LLM evaluates the alert,
# correctly identifies it as benign dangling resources, and sets the AIAnalysis
# outcome to WorkflowNotNeeded. The RO then marks the RR as NoActionRequired.
#
# Prerequisites:
#   - Kind cluster (kubernaut-demo) with platform installed
#   - Prometheus with kube-state-metrics
#   - StorageClass "standard" available (default in Kind)
#
# Usage: ./scenarios/orphaned-pvc-no-action/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-orphaned-pvc"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready

# NOTE: We intentionally do NOT seed a workflow for this scenario.
# Orphaned PVCs are housekeeping, not a critical issue. The LLM should
# correctly identify this as benign and conclude no action is needed.
#
# B15: On shared clusters (OCP), the cleanup-pvc-v1 workflow may have been
# seeded globally by another scenario. Its presence causes the LLM to see
# CleanupPVC as an available action type, creating an ambiguous state that
# prevents the "not actionable" conclusion. We temporarily remove it.
if kubectl get remediationworkflow cleanup-pvc-v1 -n "${PLATFORM_NS}" &>/dev/null; then
    echo "==> B15: Removing cleanup-pvc-v1 workflow (will restore in cleanup.sh)..."
    kubectl delete remediationworkflow cleanup-pvc-v1 -n "${PLATFORM_NS}"
    sleep 5
fi

echo "============================================="
echo " Orphaned PVC Demo (#122)"
echo " Dangling Resources -> NoActionRequired"
echo "============================================="
echo ""

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for healthy deployment
echo "==> Step 2: Waiting for data-processor to be ready..."
kubectl wait --for=condition=Available deployment/data-processor \
  -n "${NAMESPACE}" --timeout=120s
echo "  data-processor is running."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 4: Inject orphaned PVCs
echo "==> Step 4: Creating orphaned PVCs from simulated batch jobs..."
bash "${SCRIPT_DIR}/inject-orphan-pvcs.sh"
echo ""

echo "==> Step 4: Fault injected. Waiting for KubePersistentVolumeClaimOrphaned alert (~2 min)."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
