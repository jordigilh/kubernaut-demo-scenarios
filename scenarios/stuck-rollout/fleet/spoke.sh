#!/usr/bin/env bash
# Stuck Rollout Demo -- Fleet Spoke Steps
# Scenario #130: Bad image -> stuck rollout
#
# Deploys the workload and injects the bad image tag against
# SPOKE_KUBECONFIG. Touches only the spoke -- safe to invoke directly,
# multiple times, once per spoke cluster if demoing the same fault across
# several spokes. Run ../fleet/hub.sh afterward (once all spokes are done)
# to confirm the alert(s) reached the hub's Alertmanager, or use ../run.sh
# which runs both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-shipping"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for checkout-api to be ready..."
kubectl_workload wait --for=condition=Available deployment/checkout-api \
  -n "${NAMESPACE}" --timeout=120s
echo "  checkout-api is running."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing baseline (15s)..."
sleep 15
echo ""

echo "==> [spoke] Injecting non-existent image tag (triggers stuck rollout)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-bad-image.sh"
echo ""
echo "  Waiting for new pods to fail image pull..."
sleep 10
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Waiting for rollout to exceed progressDeadlineSeconds (~2 min)..."
echo "  Then the KubeDeploymentRolloutStuck alert fires after 1 min more (~3 min total)."
echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
