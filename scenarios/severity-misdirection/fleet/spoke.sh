#!/usr/bin/env bash
# Severity Misdirection Demo -- Fleet Spoke Steps
#
# Deploys postgres + api-gateway and injects an OOM condition on postgres
# against SPOKE_KUBECONFIG. Touches only the spoke -- safe to invoke
# directly, multiple times, once per spoke cluster if demoing across
# several spokes. Run ../fleet/hub.sh afterward (once all spokes are done)
# to confirm the alert(s) reached the hub's Alertmanager, or use
# ../run.sh which runs both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-services"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for postgres to be ready..."
kubectl_workload wait --for=condition=Available deployment/postgres \
  -n "${NAMESPACE}" --timeout=180s
echo "  postgres is running."

echo "==> [spoke] Waiting for api-gateway to be ready..."
kubectl_workload wait --for=condition=Available deployment/api-gateway \
  -n "${NAMESPACE}" --timeout=120s
echo "  api-gateway is running."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Verifying api-gateway connectivity (10s)..."
sleep 10
logs=$(kubectl_workload logs deploy/api-gateway -n "${NAMESPACE}" --tail=3 2>/dev/null || echo "")
if echo "$logs" | grep -q "Health check OK"; then
    echo "  api-gateway: connected to postgres successfully"
else
    echo "  WARNING: api-gateway may not be connected to postgres yet"
fi
echo ""

echo "==> [spoke] Injecting OOM condition on postgres..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-oom.sh"
echo ""
echo "  1. ContainerOOMKilling (warning) fires first -- postgres OOM"
echo "  2. KubePodCrashLooping (critical) fires second -- api-gateway"

echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
