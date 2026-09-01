#!/usr/bin/env bash
# Resource Contention Demo -- Fleet Hub Steps
#
# Confirms the ContainerOOMKilling alert fired on the spoke reached the
# hub's Alertmanager. Touches only the hub -- run fleet/spoke.sh first (or
# use ../run.sh, which runs both in order for the common single-spoke case).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-analytics"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for alert..."
fleet_wait_for_alert "ContainerOOMKilling" "${NAMESPACE}" 180
echo ""
echo "==> Alert is firing. Note: fleet mode stops here (alert-only) -- the"
echo "    external-actor revert loop and ineffective-remediation-chain"
echo "    escalation this scenario demonstrates need the full pipeline,"
echo "    single-cluster only today. See kubernaut-demo-scenarios#423."
