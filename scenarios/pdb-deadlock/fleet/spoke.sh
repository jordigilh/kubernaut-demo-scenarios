#!/usr/bin/env bash
# PDB Deadlock Demo -- Fleet Spoke Steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-payments"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

managed_workers=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get nodes \
    -l kubernaut.ai/managed=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${managed_workers:-0}" -lt 2 ]; then
    echo "ERROR: pdb-deadlock Fleet mode needs at least two nodes labelled kubernaut.ai/managed=true on the spoke." >&2
    exit 1
fi

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${MANIFEST_DIR}"

kubectl_workload wait --for=condition=Available deployment/payment-service \
    -n "${NAMESPACE}" --timeout=120s
kubectl_workload get pods -n "${NAMESPACE}" -o wide
kubectl_workload get pdb -n "${NAMESPACE}"

sleep 15
echo "==> [spoke] Starting the PDB-blocked drain..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-drain.sh"
