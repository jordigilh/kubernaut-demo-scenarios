#!/usr/bin/env bash
# ImagePullBackOff Demo -- Automated Runner
# Expired ImagePullSecret -> ImagePullBackOff -> RefreshImagePullSecret
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics scraping
#
# Usage: ./scenarios/image-pull-failure/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-imagepull"

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
echo " ImagePullBackOff Remediation Demo"
echo " Expired credentials -> ImagePullBackOff"
echo " -> RefreshImagePullSecret"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Waiting for deployment to be healthy..."
kubectl wait --for=condition=Available deployment/inventory-api \
  -n "${NAMESPACE}" --timeout=120s
echo "  inventory-api is running with a valid ImagePullSecret."
kubectl get pods -n "${NAMESPACE}"
echo ""

echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""

echo "==> Step 4: Injecting expired credentials (delete ImagePullSecret)..."
bash "${SCRIPT_DIR}/inject-expired-credentials.sh"
echo ""

echo "==> Step 5: Waiting for ImagePullBackOff and alert (~2 min)..."
echo "  The kubelet cannot find the referenced registry-credentials secret."
echo ""
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""
sleep 30
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
