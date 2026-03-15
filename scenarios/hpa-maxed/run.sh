#!/usr/bin/env bash
# HPA Maxed Out Demo -- Automated Runner
# Scenario #123: HPA at ceiling -> temporarily raise maxReplicas
#
# Prerequisites:
#   - Kind cluster with overlays/kind/kind-cluster-config.yaml
#   - Prometheus with kube-state-metrics
#   - metrics-server installed (for HPA CPU metrics)
#
# Usage: ./scenarios/hpa-maxed/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-hpa"

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

echo "============================================="
echo " HPA Maxed Out Demo (#123)"
echo "============================================="
echo ""

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for healthy deployment
echo "==> Step 2: Waiting for api-frontend to be ready..."
kubectl wait --for=condition=Available deployment/api-frontend \
  -n "${NAMESPACE}" --timeout=120s
echo "  api-frontend is running."
kubectl get pods -n "${NAMESPACE}"
kubectl get hpa -n "${NAMESPACE}"
echo ""

# Step 3: Establish baseline
echo "==> Step 3: Establishing baseline (15s)..."
sleep 15
echo ""

# Step 4: Inject CPU load
echo "==> Step 4: Generating CPU load to push HPA to ceiling..."
bash "${SCRIPT_DIR}/inject-load.sh"
echo ""

# Step 5: Wait for alert
echo "==> Step 5: Waiting for HPA to reach maxReplicas and alert to fire (~3-5 min)..."
echo "  Watch HPA: kubectl get hpa -n ${NAMESPACE} -w"
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

# Step 6: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
