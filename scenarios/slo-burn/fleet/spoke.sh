#!/usr/bin/env bash
# SLO Error Budget Burn Demo -- Fleet Spoke Steps
#
# Deploys api-gateway + traffic-gen + blackbox-exporter and injects the bad
# config against SPOKE_KUBECONFIG. The Probe CRD (prometheus-operator) is
# skipped on the spoke like every other operator-only kind; instead this
# adds a raw scrape_configs job that reproduces the same blackbox_exporter
# /probe pattern the Probe CRD would generate: static_configs' target is
# the URL to probe (not blackbox-exporter itself), then relabel_configs
# rewrites it into __param_target/instance and points __address__ at
# blackbox-exporter's own port. Touches only the spoke -- safe to invoke
# directly, multiple times, once per spoke cluster if demoing across
# several spokes. Run ../fleet/hub.sh afterward (once all spokes are done)
# to confirm the alert(s) reached the hub's Alertmanager, or use ../run.sh
# which runs both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-api"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_ensure_scrape_job "blackbox-api-gateway" "http://api-gateway.${NAMESPACE}.svc.cluster.local:8080/api/status" \
  "  metrics_path: /probe
  params:
    module: [http_2xx]
  relabel_configs:
  - source_labels: [__address__]
    target_label: __param_target
  - source_labels: [__param_target]
    target_label: instance
  - target_label: __address__
    replacement: blackbox-exporter.${NAMESPACE}.svc.cluster.local:9115" \
  "      namespace: ${NAMESPACE}"
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"
fleet_reload_spoke_prometheus

echo "==> [spoke] Waiting for deployments to be ready..."
kubectl_workload wait --for=condition=Available deployment/api-gateway \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload wait --for=condition=Available deployment/traffic-gen \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload wait --for=condition=Available deployment/blackbox-exporter \
  -n "${NAMESPACE}" --timeout=60s
echo "  api-gateway, traffic-gen, and blackbox-exporter are healthy."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy traffic baseline (30s)..."
sleep 30
echo "  Baseline established. Error rate should be ~0%."
echo ""

echo "==> [spoke] Injecting bad deployment (500 errors on /api/)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-bad-config.sh"
echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
