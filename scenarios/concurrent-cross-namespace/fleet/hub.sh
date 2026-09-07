#!/usr/bin/env bash
# Concurrent Cross-Namespace Demo -- Fleet Hub Steps
#
# Confirms the KubePodCrashLooping alert fired on the spoke (in
# demo-team-alpha) reached the hub's Alertmanager. Touches only the hub --
# run fleet/spoke.sh first (or use ../run.sh, which runs both in order for
# the common single-spoke case).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for alert..."
fleet_wait_for_alert "KubePodCrashLooping" "demo-team-alpha" 480
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
    fleet_drive_pipeline "demo-team-alpha" "${APPROVE_MODE}"
fi
