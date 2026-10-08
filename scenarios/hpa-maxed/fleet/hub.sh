#!/usr/bin/env bash
# HPA Maxed Out Demo -- Fleet Hub Steps
#
# Confirms the KubeHpaMaxedOut alert fired on the spoke reached the hub's
# Alertmanager. Touches only the hub -- run fleet/spoke.sh first (or use
# ../run.sh, which runs both in order for the common single-spoke case).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-gateway"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

echo "==> [hub=${HUB_KUBECONFIG}] Waiting for HPA to reach maxReplicas and alert to fire (~3-5 min)..."
fleet_wait_for_alert "KubeHpaMaxedOut" "${NAMESPACE}" 300
echo ""

# Fleet drives the pipeline here rather than through validate.sh, so install
# the same verification hook that local validation uses.  Without stopping
# the spoke's CPU stress when verification begins, the HPA remains saturated
# and EffectivenessMonitor reports an Inconclusive outcome even though the
# workflow correctly raised maxReplicas.
_kill_yes='for f in /proc/*/comm; do [ "$(cat "$f" 2>/dev/null)" = "yes" ] && kill "$(echo "$f" | cut -d/ -f3)" 2>/dev/null; done; true'
on_verifying() {
    echo "==> [spoke] Stopping CPU stress before effectiveness verification..."
    for pod in $(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get pods \
        -n "${NAMESPACE}" -l app=api-frontend -o name 2>/dev/null); do
        kubectl --kubeconfig="${SPOKE_KUBECONFIG}" exec -n "${NAMESPACE}" "$pod" \
            -- /bin/sh -c "${_kill_yes}" 2>/dev/null || true
    done
}
ON_VERIFYING_HOOK=on_verifying

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
