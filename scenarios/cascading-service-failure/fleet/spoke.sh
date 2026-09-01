#!/usr/bin/env bash
# Cascading Service Failure Demo -- Fleet Spoke Steps
#
# Deploys postgres + two dependent apps and injects the postgres failure
# against SPOKE_KUBECONFIG. Touches only the spoke -- safe to invoke
# directly, multiple times, once per spoke cluster if demoing across
# several spokes. Run ../fleet/hub.sh afterward (once all spokes are done)
# to confirm the alert(s) reached the hub's Alertmanager, or use
# ../run.sh which runs both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-order-fulfillment"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for all deployments to be ready..."
kubectl_workload wait --for=condition=Available deployment/postgres \
  -n "${NAMESPACE}" --timeout=180s
kubectl_workload wait --for=condition=Available deployment/order-processor \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload wait --for=condition=Available deployment/inventory-sync \
  -n "${NAMESPACE}" --timeout=120s
echo "  All deployments healthy."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Verifying app connectivity to postgres (10s)..."
sleep 10
for app in order-processor inventory-sync; do
    logs=$(kubectl_workload logs deploy/${app} -n "${NAMESPACE}" --tail=3 2>/dev/null || echo "")
    if echo "$logs" | grep -q "Health check OK"; then
        echo "  ${app}: connected to postgres successfully"
    else
        echo "  WARNING: ${app} may not be connected to postgres yet"
    fi
done
echo ""

echo "==> [spoke] Injecting PostgreSQL failure..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-pg-failure.sh"
echo ""
echo "  Both order-processor and inventory-sync will lose postgres"
echo "  connectivity and start crash-looping. Two independent"
echo "  KubePodCrashLooping alerts will fire, both rooted in Deployment/postgres."

echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
