#!/usr/bin/env bash
# RBAC Failure Demo -- Fleet Spoke Steps
# RoleBinding deleted -> 403 Forbidden
#
# Deploys the workload and injects the RBAC fault against SPOKE_KUBECONFIG.
# Touches only the spoke -- safe to invoke directly, multiple times, once
# per spoke cluster if demoing the same fault across several spokes. Run
# ../fleet/hub.sh afterward (once all spokes are done) to confirm the
# alert(s) reached the hub's Alertmanager, or use ../run.sh which runs both
# in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-monitoring"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for deployment to be Available..."
kubectl_workload wait --for=condition=Available deployment/metrics-collector \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
echo ""

echo "==> [spoke] Injecting RBAC failure (delete RoleBinding)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-rbac-revoke.sh"
echo ""

kubectl_workload get pods -n "${NAMESPACE}"
echo ""
POD=$(kubectl_workload get pods -n "${NAMESPACE}" -l app=metrics-collector \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${POD}" ]; then
    kubectl_workload describe pod "${POD}" -n "${NAMESPACE}" || true
fi
echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
