#!/usr/bin/env bash
# Resource Contention Demo -- Fleet Runner (hub + spoke)
#
# Dispatched from ../run.sh via --fleet (validated against HUB_KUBECONFIG and
# SPOKE_KUBECONFIG). Runs spoke.sh, starts the split-target external actor,
# then drives the first remediation cycle on the hub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================="
echo " Resource Contention Demo (Issue #231)"
echo "============================================="
echo ""

bash "${SCRIPT_DIR}/spoke.sh"
echo ""

ACTOR_PID=""
stop_actor() {
    if [ -n "${ACTOR_PID}" ]; then
        kill "${ACTOR_PID}" 2>/dev/null || true
        wait "${ACTOR_PID}" 2>/dev/null || true
    fi
}
trap stop_actor EXIT

echo "==> [fleet] Starting external actor (hub RR state + spoke workload)..."
FLEET_MODE=true HUB_KUBECONFIG="${HUB_KUBECONFIG}" \
    SPOKE_KUBECONFIG="${SPOKE_KUBECONFIG}" \
    bash "${SCRIPT_DIR}/../scripts/external-actor.sh" &
ACTOR_PID=$!

bash "${SCRIPT_DIR}/hub.sh" "$@"
