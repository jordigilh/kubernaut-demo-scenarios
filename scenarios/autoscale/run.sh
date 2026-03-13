#!/usr/bin/env bash
# Cluster Autoscaling Demo -- Automated Runner
# Scenario #126: Pods stuck Pending -> provision new Kind node via kubeadm join
#
# Prerequisites:
#   - Kind cluster with overlays/kind/kind-cluster-config.yaml
#   - Podman available on host
#
# Usage: ./scenarios/autoscale/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-autoscale"
PROVISIONER_PID=""

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
# shellcheck source=../../scripts/monitoring-helper.sh
source "${SCRIPT_DIR}/../../scripts/monitoring-helper.sh"
require_infra metrics-server

cleanup_provisioner() {
  if [ -n "$PROVISIONER_PID" ]; then
    echo "==> Stopping provisioner agent (PID: $PROVISIONER_PID)..."
    kill "$PROVISIONER_PID" 2>/dev/null || true
  fi
}
trap cleanup_provisioner EXIT

echo "============================================="
echo " Cluster Autoscaling Demo (#126)"
echo "============================================="
echo ""

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for initial deployment to be ready (2 replicas)
echo "==> Step 2: Waiting for initial deployment (2 replicas)..."
kubectl wait --for=condition=Available deployment/web-cluster \
  -n "${NAMESPACE}" --timeout=120s
echo "  web-cluster is healthy with 2 replicas."
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""

# Step 3: Register workflow in DataStorage (placeholder)
echo "==> Step 3: Workflow registration..."
echo "  TODO: Build and push provision-node-v1 OCI bundle, register via DataStorage API."
echo "  For now, ensure the workflow is pre-seeded in the catalog."
echo ""

# Step 4: Start the host-side provisioner agent in background
echo "==> Step 4: Starting provisioner agent..."
bash "${SCRIPT_DIR}/provisioner.sh" &
PROVISIONER_PID=$!
echo "  Provisioner running (PID: $PROVISIONER_PID)"
echo ""

# Step 5: Inject failure -- scale beyond node capacity
echo "==> Step 5: Injecting failure (scaling to 8 replicas)..."
kubectl scale deployment/web-cluster --replicas=8 -n "${NAMESPACE}"
echo "  Scaled to 8 replicas. With 8x512Mi = 4GB requested, worker node cannot fit all."
echo ""

# Step 6: Show pending pods
echo "==> Step 6: Waiting 15s for pods to enter Pending state..."
sleep 15
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""

# Step 7: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
