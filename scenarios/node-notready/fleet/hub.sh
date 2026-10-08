#!/usr/bin/env bash
# Node NotReady Demo -- Fleet Hub Steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-compute"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity
fleet_wait_for_alert "KubeNodeNotReady" "${NAMESPACE}" 480

# The node must recover during EffectivenessMonitor's stabilization window.
# This mirrors the local validator's hook while keeping the operation scoped
# explicitly to the spoke cluster.
_on_verifying() {
    local worker
    worker=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get nodes \
        -l 'kubernaut.ai/managed=true,!node-role.kubernetes.io/control-plane' \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${worker}" ]; then
        echo "==> [spoke] Unpausing ${worker} for effectiveness verification..."
        podman unpause "${worker}" 2>/dev/null || true
    fi
}
ON_VERIFYING_HOOK=_on_verifying

APPROVE_MODE="--auto-approve"
ALERT_ONLY=""
for _arg in "$@"; do
    case "${_arg}" in
        --auto-approve) APPROVE_MODE="--auto-approve" ;;
        --interactive)  APPROVE_MODE="--interactive" ;;
        --alert-only)   ALERT_ONLY=true ;;
    esac
done

if [ -n "${ALERT_ONLY}" ]; then
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
else
    fleet_drive_pipeline "${NAMESPACE}" "${APPROVE_MODE}"
fi
