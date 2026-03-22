#!/usr/bin/env bash
# SLO Error Budget Burn Demo -- Automated Runner
# Scenario #128: Error budget burning -> proactive rollback to preserve SLO
#
# Prerequisites:
#   - Kind cluster with overlays/kind/kind-cluster-config.yaml
#   - Prometheus with nginx metrics exporter
#
# Usage: ./scenarios/slo-burn/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-slo"

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

echo "============================================="
echo " SLO Error Budget Burn Demo (#128)"
echo "============================================="
echo ""

# Enable HAPI Prometheus toolset for this scenario (kubernaut#473, #108).
echo "==> Enabling HolmesGPT Prometheus toolset for this scenario..."
enable_prometheus_toolset
echo ""

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for initial deployments to be healthy
echo "==> Step 2: Waiting for deployments..."
kubectl wait --for=condition=Available deployment/api-gateway \
  -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Available deployment/traffic-gen \
  -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Available deployment/blackbox-exporter \
  -n "${NAMESPACE}" --timeout=60s
echo "  api-gateway, traffic-gen, and blackbox-exporter are healthy."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 3: Register workflow in DataStorage (placeholder)
echo "==> Step 3: Workflow registration..."
echo "  TODO: Build and push proactive-rollback-v1 OCI bundle, register via DataStorage API."
echo "  For now, ensure the workflow is pre-seeded in the catalog."
echo ""

# Step 4: Let healthy traffic establish baseline (~30s)
echo "==> Step 4: Establishing healthy traffic baseline (30s)..."
sleep 30
echo "  Baseline established. Error rate should be ~0%."
echo ""

# Step 5: Inject bad config
echo "==> Step 5: Injecting bad deployment (500 errors on /api/)..."
bash "${SCRIPT_DIR}/inject-bad-config.sh"
echo ""

# Step 6: Wait for alert
echo "==> Step 6: Waiting for SLO burn rate alert to fire (~5 min)..."
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo "  The ErrorBudgetBurn alert should appear within 5 minutes."
echo ""

# Step 7: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi

# Step 8: Silence alert to prevent new RRs while SLO burn-rate windows decay.
# After remediation the error rate drops to 0%, but the multi-window burn-rate
# calculation can take 5-30 min to clear. Without a silence the Gateway will
# legitimately create new RRs for the still-firing alert.
echo ""
echo "==> Step 8: Silencing ErrorBudgetBurn alert (10m) to prevent post-remediation RRs..."
silence_alert "ErrorBudgetBurn" "${NAMESPACE}" "10m"
