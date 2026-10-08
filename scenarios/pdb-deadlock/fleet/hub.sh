#!/usr/bin/env bash
# PDB Deadlock Demo -- Fleet Hub Steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-payments"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

fleet_wait_for_alert "KubePodDisruptionBudgetAtLimit" "${NAMESPACE}" 480

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
