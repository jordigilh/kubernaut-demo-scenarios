#!/usr/bin/env bash
# Duplicate Alert Suppression Demo -- Fleet Spoke Steps
#
# Deploys the 5-replica workload and injects the fault against
# SPOKE_KUBECONFIG. Touches only the spoke -- safe to invoke directly,
# multiple times, once per spoke cluster if demoing across several spokes.
# Run ../fleet/hub.sh afterward (once all spokes are done) to confirm the
# alert(s) reached the hub's Alertmanager, or use ../run.sh which runs both
# in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-ingress"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for all 5 replicas to be healthy..."
kubectl_workload wait --for=condition=Available deployment/api-gateway \
  -n "${NAMESPACE}" --timeout=120s
echo "  All 5 pods are running."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
echo ""

echo "==> [spoke] Injecting invalid config (all 5 pods will CrashLoop)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-bad-config.sh"
echo ""
echo "  Waiting for pods to start crashing..."
sleep 10
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] All 5 pods belong to Deployment/api-gateway, so the Gateway"
echo "    OwnerResolver on the hub maps every alert to the same fingerprint."
sleep 30
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
