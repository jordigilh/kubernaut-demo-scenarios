#!/usr/bin/env bash
# etcd Defrag Forecast Demo -- Fleet Spoke Steps
#
# Deploys the 3-member etcd StatefulSet and injects fragmentation against
# SPOKE_KUBECONFIG. etcd exposes its own /metrics (no ServiceMonitor/operator
# on the spoke), and its metrics carry no k8s namespace label on their own
# (same situation as postgres_exporter in db-connection-saturation) -- attach
# one as a static scrape-time label to match the PrometheusRule's
# namespace="demo-datastore" filter. Touches only the spoke -- safe to invoke
# directly, multiple times, once per spoke cluster if demoing across several
# spokes. Run ../fleet/hub.sh afterward (once all spokes are done) to confirm
# the alert(s) reached the hub's Alertmanager, or use ../run.sh which runs
# both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-datastore"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_ensure_scrape_job "etcd-metrics" "etcd-client.${NAMESPACE}.svc.cluster.local:2381" "" \
  "      namespace: ${NAMESPACE}"
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"
fleet_reload_spoke_prometheus

echo "==> [spoke] Waiting for etcd StatefulSet to be ready..."
kubectl_workload rollout status statefulset/etcd -n "${NAMESPACE}" --timeout=600s
echo "  etcd cluster ready."
kubectl_workload get pods -n "${NAMESPACE}" -l app=etcd
echo ""

echo "==> [spoke] Verifying etcd cluster health..."
kubectl_workload exec etcd-0 -n "${NAMESPACE}" -- \
  etcdctl --endpoints=http://localhost:2379 member list --write-out=table
echo ""

echo "==> [spoke] Waiting for Prometheus to scrape etcd metrics (30s)..."
sleep 30

echo "==> [spoke] Injecting etcd fragmentation..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-fragmentation.sh"
echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
