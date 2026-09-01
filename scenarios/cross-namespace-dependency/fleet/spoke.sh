#!/usr/bin/env bash
# Cross-Namespace Dependency Tracing Demo -- Fleet Spoke Steps
#
# Deploys postgres (demo-xns-infra) and two dependent apps (demo-xns-app)
# and injects the postgres failure against SPOKE_KUBECONFIG. Touches only
# the spoke -- safe to invoke directly, multiple times, once per spoke
# cluster if demoing across several spokes. Run ../fleet/hub.sh afterward
# (once all spokes are done) to confirm the alert(s) reached the hub's
# Alertmanager, or use ../run.sh which runs both in order for the common
# single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_NS="demo-xns-infra"
APP_NS="demo-xns-app"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources (two namespaces)..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for postgres in ${INFRA_NS}..."
kubectl_workload wait --for=condition=Available deployment/postgres \
  -n "${INFRA_NS}" --timeout=180s
echo "  postgres is ready in ${INFRA_NS}."

echo "==> [spoke] Waiting for apps in ${APP_NS}..."
kubectl_workload wait --for=condition=Available deployment/api-gateway \
  -n "${APP_NS}" --timeout=120s
kubectl_workload wait --for=condition=Available deployment/payment-processor \
  -n "${APP_NS}" --timeout=120s
echo "  All app deployments healthy in ${APP_NS}."
kubectl_workload get pods -n "${INFRA_NS}"
kubectl_workload get pods -n "${APP_NS}"
echo ""

echo "==> [spoke] Verifying cross-namespace connectivity (10s)..."
sleep 10
for app in api-gateway payment-processor; do
    logs=$(kubectl_workload logs deploy/${app} -n "${APP_NS}" --tail=3 2>/dev/null || echo "")
    if echo "$logs" | grep -q "Health check OK"; then
        echo "  ${app}: connected to postgres.${INFRA_NS}.svc successfully"
    else
        echo "  WARNING: ${app} may not be connected to postgres yet"
    fi
done
echo ""

echo "==> [spoke] Injecting PostgreSQL failure in ${INFRA_NS}..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-failure.sh"
echo ""
echo "  Both api-gateway and payment-processor will lose postgres"
echo "  connectivity and start crash-looping in ${APP_NS}."

echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
