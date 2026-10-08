#!/usr/bin/env bash
# Resource Contention Demo -- Fleet Hub Steps
#
# Confirms the ContainerOOMKilling alert fired on the spoke reached the
# hub's Alertmanager, then drives the first remediation cycle on the hub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-analytics"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for alert..."
fleet_wait_for_alert "ContainerOOMKilling" "${NAMESPACE}" 180
echo ""

APPROVE_MODE="--auto-approve"
ALERT_ONLY=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve) APPROVE_MODE="--auto-approve" ;;
        --interactive)  APPROVE_MODE="--interactive" ;;
        --alert-only)   ALERT_ONLY=true ;;
    esac
done

if [ -n "${ALERT_ONLY}" ]; then
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
else
    echo "==> Alert is firing. Driving first remediation cycle on the hub (${APPROVE_MODE})..."
    fleet_drive_pipeline "${NAMESPACE}" "${APPROVE_MODE}"
fi
