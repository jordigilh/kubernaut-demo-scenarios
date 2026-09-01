#!/usr/bin/env bash
# StatefulSet PVC Failure Demo -- Fleet Spoke Steps
#
# Deploys the kv-store StatefulSet and injects the PVC failure against
# SPOKE_KUBECONFIG. Touches only the spoke -- safe to invoke directly,
# multiple times, once per spoke cluster if demoing across several spokes.
# Run ../fleet/hub.sh afterward (once all spokes are done) to confirm the
# alert(s) reached the hub's Alertmanager, or use ../run.sh which runs both
# in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-keystore"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for all StatefulSet pods to be ready..."
kubectl_workload rollout status statefulset/kv-store -n "${NAMESPACE}" --timeout=180s
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""

echo "==> [spoke] Injecting PVC failure..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-pvc-issue.sh"
echo ""

echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
