#!/usr/bin/env bash
# Prompt Injection Detection Demo -- Fleet Hub Steps
#
# Confirms the KubePodCrashLooping alert fired on the spoke reached the
# hub's Alertmanager. Touches only the hub -- run fleet/spoke.sh first (or
# use ../run.sh, which runs both in order for the common single-spoke case).
# Note: fleet mode does not exercise the shadow-agent/HumanReviewNeeded
# escalation this scenario is really about -- that's downstream of the
# alert, in validate.sh, which fleet mode skips. This only proves the
# CrashLoop signal reaches the hub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-workers"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for alert..."
fleet_wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 480
echo ""
echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
echo "    Fleet mode: drive remediation from the Console/APIFrontend on the hub."
