#!/usr/bin/env bash
# Proactive Memory Exhaustion Demo -- Fleet Hub Steps
#
# Confirms the ContainerMemoryExhaustionPredicted alert fired on the spoke
# reached the hub's Alertmanager. Touches only the hub -- run fleet/spoke.sh
# first (or use ../run.sh, which runs both in order for the common
# single-spoke case).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-telemetry"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for alert (predict_linear needs 5-7 min of trend data)..."
fleet_wait_for_alert "ContainerMemoryExhaustionPredicted" "${NAMESPACE}" 600
echo ""

APPROVE_MODE="--auto-approve"
ALERT_ONLY=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --alert-only)    ALERT_ONLY=true ;;
    esac
done

if [ -n "$ALERT_ONLY" ]; then
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
    echo "    Fleet mode: drive remediation from the Console/APIFrontend on the hub."
else
    echo "==> Alert is firing. Driving full remediation pipeline on the hub (${APPROVE_MODE})..."
    fleet_drive_pipeline "${NAMESPACE}" "${APPROVE_MODE}"
fi
