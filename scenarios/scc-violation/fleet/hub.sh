#!/usr/bin/env bash
# SCC Violation Demo -- Fleet Hub Steps
#
# Confirms the SCCViolationPodBlocked alert fired on the spoke reached the
# hub's Alertmanager. Touches only the hub -- run fleet/spoke.sh first (or
# use ../run.sh, which runs both in order for the common single-spoke case).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-agents"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for alert..."
fleet_wait_for_alert "SCCViolationPodBlocked" "${NAMESPACE}" 480
echo ""
echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
echo "    Fleet mode: drive remediation from the Console/APIFrontend on the hub."
