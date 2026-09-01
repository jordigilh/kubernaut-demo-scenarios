#!/usr/bin/env bash
# NetworkPolicy Traffic Block Demo -- Fleet Spoke Steps
#
# Deploys the workload and injects the deny-all NetworkPolicy against
# SPOKE_KUBECONFIG. Touches only the spoke -- safe to invoke directly,
# multiple times, once per spoke cluster if demoing across several spokes.
# Run ../fleet/hub.sh afterward (once all spokes are done) to confirm the
# alert(s) reached the hub's Alertmanager, or use ../run.sh which runs both
# in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-frontend"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for deployment to be healthy..."
kubectl_workload wait --for=condition=Available deployment/web-frontend \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""

echo "==> [spoke] Injecting deny-all NetworkPolicy..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-deny-all-netpol.sh"
echo ""
echo "  Waiting for health checks to fail..."
sleep 5
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
