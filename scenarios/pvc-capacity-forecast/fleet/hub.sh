#!/usr/bin/env bash
# PVC Capacity Forecast Demo -- Fleet Hub Steps
#
# Confirms the PVRunwayShort alert fired on the spoke reached the hub's
# Alertmanager. Touches only the hub -- run fleet/spoke.sh first (or use
# ../run.sh, which runs both in order for the common single-spoke case).
#
# KNOWN BLOCKER (untested end-to-end): on the fleet-e2e Kind spoke's kubelet
# (v1.36.1 as of this writing), kubelet_volume_stats_used_bytes/capacity_bytes
# never register on /metrics -- matches a kubelet metrics-registration
# regression (https://github.com/kubernetes/kubernetes/issues/133847),
# tracked against this repo's Kind image at kubernaut#2338. The alert can't
# fire on affected spokes until that's resolved; this script is otherwise
# correct and will work once the metric is exposed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-archive"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for alert (predict_linear needs 5-7 min of trend data)..."
fleet_wait_for_alert "PVRunwayShort" "${NAMESPACE}" 900
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
