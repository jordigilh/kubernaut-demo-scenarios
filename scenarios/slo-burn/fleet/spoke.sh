#!/usr/bin/env bash
# SLO Error Budget Burn Demo -- Fleet Spoke Steps
#
# Deploys api-gateway + traffic-gen + blackbox-exporter and injects the bad
# config against SPOKE_KUBECONFIG. Monitoring is operator-native: the Probe
# CRD in manifests/blackbox-exporter.yaml is applied as-is (the spoke
# Prometheus selects Probes in every namespace), preserving blackbox
# /probe semantics. Touches only the spoke -- safe to invoke
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
fleet_bootstrap_monitoring "${MANIFEST_DIR}"

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
