#!/usr/bin/env bash
# Red Herring / Multi-Incident Separation Demo -- Fleet Spoke Steps
#
# Deploys postgres + api-gateway + worker and injects the postgres failure
# (canary-v2 red herring is deployed by inject-faults.sh itself, ~45s
# later) against SPOKE_KUBECONFIG. Touches only the spoke -- safe to invoke
# directly, multiple times, once per spoke cluster if demoing across
# several spokes. Run ../fleet/hub.sh afterward (once all spokes are done)
# to confirm the alert(s) reached the hub's Alertmanager, or use
# ../run.sh which runs both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-microservices"

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

echo "==> [spoke] Waiting for app workloads to be ready..."
kubectl_workload wait --for=condition=Available deployment/api-gateway \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload wait --for=condition=Available deployment/worker \
  -n "${NAMESPACE}" --timeout=120s
echo "  api-gateway and worker are running."
echo "  NOTE: canary-v2 will be deployed after the postgres fault (red herring)."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Verifying app connectivity to postgres (10s)..."
sleep 10
for app in api-gateway worker; do
    logs=$(kubectl_workload logs deploy/${app} -n "${NAMESPACE}" --tail=3 2>/dev/null || echo "")
    if echo "$logs" | grep -q "Health check OK"; then
        echo "  ${app}: connected to postgres successfully"
    else
        echo "  WARNING: ${app} may not be connected to postgres yet"
    fi
done
echo ""

echo "==> [spoke] Injecting PostgreSQL failure (canary red herring follows in ~45s)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-faults.sh"
echo ""
echo "  PRIMARY: KubePodCrashLooping (api-gateway, worker) -> root cause: postgres"
echo "  RED HERRING: ImagePullBackOffPersistent (canary-v2) -> independent issue"

echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
