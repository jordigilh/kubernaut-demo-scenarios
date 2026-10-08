#!/usr/bin/env bash
# PDB Deadlock Demo -- Fleet Runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/spoke.sh"
bash "${SCRIPT_DIR}/hub.sh" "$@"

# The local runner's post-remediation step uncordons the drained node. Keep the
# same invariant in the split hub/spoke path without deleting the workload.
TARGET_NODE=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get nodes \
    -l kubernaut.ai/managed=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${TARGET_NODE}" ]; then
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" uncordon "${TARGET_NODE}" || true
fi
kubectl --kubeconfig="${SPOKE_KUBECONFIG}" wait --for=condition=Available \
    deployment/payment-service -n demo-payments --timeout=120s || true
