#!/usr/bin/env bash
# CrashLoopBackOff Helm Demo -- Automated Runner
# Scenario #135: Helm-managed bad config -> CrashLoopBackOff -> helm rollback
#
# Prerequisites:
#   - Kind cluster with Kubernaut services
#   - Helm 3 installed
#   - Prometheus with kube-state-metrics
#
# Usage: ./scenarios/crashloop-helm/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-crashloop-helm"

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

echo "============================================="
echo " Helm CrashLoopBackOff Remediation Demo (#135)"
echo "============================================="
echo ""

# Step 0: Clean up stale alerts/RRs from any previous run (#193)
ensure_clean_slate "${NAMESPACE}"

# Step 1: Pre-create namespace with kubernaut labels, then install via Helm.
# The namespace is created outside the chart to avoid the Helm 3 conflict where
# --create-namespace + a Namespace template both try to create the same object (#122).
echo "==> Step 1: Installing workload via Helm chart..."
kubectl apply -f - <<'NSEOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo-crashloop-helm
  labels:
    kubernaut.ai/environment: production
    kubernaut.ai/business-unit: engineering
    kubernaut.ai/service-owner: backend-team
    kubernaut.ai/criticality: high
    kubernaut.ai/sla-tier: tier-1
NSEOF
HELM_VALUES_ARGS=""
if [ "$PLATFORM" = "ocp" ]; then
    HELM_VALUES_ARGS="-f ${SCRIPT_DIR}/chart/values-ocp.yaml"
fi
helm upgrade --install demo-crashloop-helm "${SCRIPT_DIR}/chart" \
  -n "${NAMESPACE}" --wait --timeout 120s ${HELM_VALUES_ARGS}
echo "  Helm release installed. Deployment has app.kubernetes.io/managed-by: Helm label."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 2: Deploy Prometheus alerting rules (outside Helm to keep it simple)
echo "==> Step 2: Deploying CrashLoop detection alerting rule..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 3: Baseline
echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""

# Step 4: Inject
echo "==> Step 4: Injecting invalid nginx config via helm upgrade..."
bash "${SCRIPT_DIR}/inject-bad-config.sh"
echo ""
echo "  Waiting for pods to start crashing..."
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 5: Monitor
echo "==> Step 5: Waiting for CrashLoop alert to fire (~2-3 min)..."
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""
# Step 6: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
