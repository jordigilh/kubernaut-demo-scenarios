#!/usr/bin/env bash
# Istio Mesh Routing Failure Demo -- Automated Runner
# Scenario #136: AuthorizationPolicy blocks traffic -> fix policy
#
# Prerequisites:
#   - Cluster with Kubernaut services
#   - Istio installed (Kind: upstream Istio / OCP: OpenShift Service Mesh)
#   - Prometheus scraping Istio sidecar metrics
#
# Usage: ./scenarios/mesh-routing-failure/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-mesh-failure"

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
require_infra istio

echo "============================================="
echo " Istio Mesh Routing Failure Demo (#136)"
echo "============================================="
echo ""

# Step 1: Deploy scenario resources (namespace with istio-injection, workload, monitoring)
echo "==> Step 1: Deploying namespace and meshed workload..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"
ensure_ocp_namespace_monitoring "${NAMESPACE}"

echo "  Waiting for deployments to be ready..."
kubectl wait --for=condition=Available deployment/api-server \
  -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Available deployment/traffic-gen \
  -n "${NAMESPACE}" --timeout=120s
echo "  Workload and traffic generator deployed with Istio sidecars."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 2: Baseline -- let traffic flow so Prometheus scrapes healthy metrics
echo "==> Step 2: Establishing healthy baseline (30s)..."
echo "  traffic-gen is sending requests to api-server through the mesh."
sleep 30
echo "  Baseline established."
echo ""

# Step 3: Inject
echo "==> Step 3: Injecting restrictive AuthorizationPolicy..."
bash "${SCRIPT_DIR}/inject-deny-policy.sh"
echo ""
echo "  Waiting for policy to take effect..."
sleep 5
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 4: Monitor
echo "==> Step 4: Waiting for high error rate alert (~2-3 min)..."
echo "  Istio sidecar will deny all inbound traffic (HTTP 403 Forbidden)."
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""
# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
