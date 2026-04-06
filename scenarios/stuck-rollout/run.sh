#!/usr/bin/env bash
# Stuck Rollout Demo -- Automated Runner
# Scenario #130: Bad image -> stuck rollout -> rollback
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics
#
# Usage: ./scenarios/stuck-rollout/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-rollout"

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
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"
require_demo_ready

echo "============================================="
echo " Stuck Rollout Demo (#130)"
echo "============================================="
echo ""

# Step 0: Clean up stale alerts/RRs from any previous run (#193)
ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for healthy deployment
echo "==> Step 2: Waiting for checkout-api to be ready..."
kubectl wait --for=condition=Available deployment/checkout-api \
  -n "${NAMESPACE}" --timeout=120s
echo "  checkout-api is running (3 replicas with nginx:1.27-alpine)."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 3: Establish baseline
echo "==> Step 3: Establishing baseline (15s)..."
sleep 15
echo ""

# Step 4: Inject bad image
echo "==> Step 4: Injecting non-existent image tag (triggers stuck rollout)..."
bash "${SCRIPT_DIR}/inject-bad-image.sh"
echo ""
echo "  Waiting for new pods to fail image pull..."
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 5: Wait for stuck rollout + alert
echo "==> Step 5: Waiting for rollout to exceed progressDeadlineSeconds (~2 min)..."
echo "  Then the KubeDeploymentRolloutStuck alert fires after 1 min more (~3 min total)."
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

# Step 6: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
