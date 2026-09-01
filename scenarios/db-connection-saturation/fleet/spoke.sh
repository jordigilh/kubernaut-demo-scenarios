#!/usr/bin/env bash
# Database Connection Saturation Demo -- Fleet Spoke Steps
#
# Deploys postgres (+ postgres_exporter sidecar), order-service,
# report-generator, and client-pool against SPOKE_KUBECONFIG. client-pool
# self-saturates the connection pool -- no separate inject script. Touches
# only the spoke -- safe to invoke directly, multiple times, once per
# spoke cluster if demoing across several spokes. Run ../fleet/hub.sh
# afterward (once all spokes are done) to confirm the alert(s) reached the
# hub's Alertmanager, or use ../run.sh which runs both in order for the
# common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-orders"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_ensure_kube_state_metrics
# postgres_exporter's own metrics carry no k8s namespace label (unlike
# cert-manager) -- attach it as a static scrape-time label to match the
# PrometheusRule's namespace="demo-orders" filter.
fleet_ensure_scrape_job "postgres-exporter" "postgres.${NAMESPACE}.svc.cluster.local:9187" "" \
  "      namespace: ${NAMESPACE}"
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"
fleet_reload_spoke_prometheus

echo "==> [spoke] Waiting for postgres to be ready..."
kubectl_workload wait --for=condition=Available deployment/postgres \
  -n "${NAMESPACE}" --timeout=180s
echo "  postgres is running with max_connections=15."

echo "==> [spoke] Waiting for app workloads to be ready..."
kubectl_workload wait --for=condition=Available deployment/order-service \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload wait --for=condition=Available deployment/report-generator \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload wait --for=condition=Available deployment/client-pool \
  -n "${NAMESPACE}" --timeout=120s
echo "  All workloads running."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Verifying postgres_exporter metrics..."
PG_UP="0"
for _i in $(seq 1 12); do
    PG_UP=$(kubectl_workload exec -n "${NAMESPACE}" deploy/postgres -c exporter -- \
      wget -qO- http://localhost:9187/metrics 2>/dev/null \
      | grep '^pg_up ' | awk '{print $2}' || echo "0")
    [ "${PG_UP}" = "1" ] && break
    sleep 5
done
if [ "${PG_UP}" != "1" ]; then
    echo "WARNING: postgres_exporter not reporting pg_up=1 (got: ${PG_UP})"
fi
echo "  postgres_exporter: pg_up=${PG_UP}"
echo ""

echo "==> [spoke] Client pool running (~1 connection every 8s)."
echo "    Pool will saturate within ~2 minutes (10 leaked + system = 15 max)."
echo ""
echo "==> [spoke] Fault self-injecting. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
