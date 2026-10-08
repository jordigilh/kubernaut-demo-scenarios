#!/usr/bin/env bash
# Pending Pods Taint Removal Demo -- Fleet Spoke Steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-scheduler"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Applying the scheduling taint..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-taint.sh"

echo "==> [spoke] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${MANIFEST_DIR}"

sleep 5
kubectl_workload get pods -n "${NAMESPACE}" -o wide
echo "==> [spoke] Pods should remain Pending until remove-taint-v1 runs."
