#!/usr/bin/env bash
# HPA Maxed Out Demo -- Fleet Spoke Steps
#
# Deploys the workload and generates CPU load against SPOKE_KUBECONFIG.
# Requires metrics-server on the spoke (same prerequisite as local mode --
# HPA needs it to scale on CPU regardless of cluster topology). Touches
# only the spoke -- safe to invoke directly, multiple times, once per spoke
# cluster if demoing across several spokes. Run ../fleet/hub.sh afterward
# (once all spokes are done) to confirm the alert(s) reached the hub's
# Alertmanager, or use ../run.sh which runs both in order for the common
# single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-gateway"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

if ! kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get deployment metrics-server -n kube-system &>/dev/null; then
    echo "ERROR: metrics-server is not installed on the spoke. HPA cannot scale on CPU without it." >&2
    exit 1
fi

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for api-frontend to be ready..."
kubectl_workload wait --for=condition=Available deployment/api-frontend \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload get pods -n "${NAMESPACE}"
kubectl_workload get hpa -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing baseline (15s)..."
sleep 15
echo ""

echo "==> [spoke] Generating CPU load to push HPA to ceiling (background)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-load.sh" &
INJECT_PID=$!
echo ""

echo "==> [spoke] Fault injecting in background (PID ${INJECT_PID}). Run fleet/hub.sh"
echo "    (or ../run.sh) to wait for the alert on the hub -- takes ~3-5 min."
echo "    Kill the load generator when done: kill ${INJECT_PID}"
