#!/usr/bin/env bash
# PDB Deadlock Demo -- Automated Runner
# Scenario #124: Overly restrictive PDB blocks node drain -> relax PDB
#
# Prerequisites:
#   - Kind or OCP cluster with worker nodes
#   - Prometheus with kube-state-metrics
#
# Usage: ./scenarios/pdb-deadlock/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-pdb"

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
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

enable_prometheus_toolset
force_production_approval

echo "============================================="
echo " PDB Deadlock Demo (#124)"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 0: Ensure worker nodes have the kubernaut.ai/managed=true label
# The deployment uses nodeSelector: kubernaut.ai/managed=true. On OCP this
# label is not present by default; on Kind setup-demo-cluster.sh handles it.
MANAGED_WORKERS=$(kubectl get nodes -l kubernaut.ai/managed=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$MANAGED_WORKERS" -lt 2 ]; then
  echo "==> Labelling worker nodes with kubernaut.ai/managed=true..."
  for node in $(kubectl get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
    kubectl label node "$node" kubernaut.ai/managed=true --overwrite
    echo "  Labelled $node"
  done
fi

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for healthy deployment
echo "==> Step 2: Waiting for payment-service to be ready on worker node..."
kubectl wait --for=condition=Available deployment/payment-service \
  -n "${NAMESPACE}" --timeout=120s
echo "  payment-service is running (2 replicas on worker node)."
kubectl get pods -n "${NAMESPACE}" -o wide
kubectl get pdb -n "${NAMESPACE}"
echo ""

# Step 3: Establish baseline
echo "==> Step 3: Establishing baseline (15s)..."
sleep 15
echo "  PDB shows: ALLOWED DISRUPTIONS = 0 (this is the problem)."
echo ""

# Step 4: Drain worker node (will be blocked by PDB)
echo "==> Step 4: Draining worker node (blocked by PDB)..."
bash "${SCRIPT_DIR}/inject-drain.sh"
echo ""

# Step 5: Wait for alert
echo "==> Step 5: Waiting for PDB deadlock alert to fire (~3 min)..."
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo "  The KubePodDisruptionBudgetAtLimit alert fires when allowed disruptions = 0 for 3 min."
echo ""

# Step 6: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi

# Step 7: Post-maintenance -- uncordon worker and verify recovery
echo "==> Step 7: Post-maintenance -- uncordoning worker node..."
WORKER_NODE=$(kubectl get nodes -l kubernaut.ai/managed=true \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${WORKER_NODE}" ]; then
  kubectl uncordon "${WORKER_NODE}"
  echo "  Worker node ${WORKER_NODE} uncordoned."
else
  echo "  WARNING: No worker node found with label kubernaut.ai/managed=true"
fi

echo "  Waiting for all pods to be ready (60s timeout)..."
kubectl wait --for=condition=Available deployment/payment-service \
  -n "${NAMESPACE}" --timeout=60s
echo ""
echo "==> Final state:"
kubectl get nodes
kubectl get pdb -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
echo "============================================="
echo " PDB Deadlock Demo -- COMPLETE"
echo "============================================="
