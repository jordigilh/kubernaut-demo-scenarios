#!/usr/bin/env bash
# Database Connection Saturation Demo -- Fleet Hub Steps
#
# Confirms the DatabaseConnectionPoolExhausted alert fired on the spoke
# reached the hub's Alertmanager. Touches only the hub -- run
# fleet/spoke.sh first (or use ../run.sh, which runs both in order for
# the common single-spoke case).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-orders"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for pool to saturate and alert to fire (~2-3 min)..."
fleet_wait_for_alert "DatabaseConnectionPoolExhausted" "${NAMESPACE}" 600
echo ""
echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
echo "    Fleet mode: drive remediation from the Console/APIFrontend on the hub."
