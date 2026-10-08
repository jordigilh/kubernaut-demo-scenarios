#!/usr/bin/env bash
# Prompt Injection Detection Demo -- Dispatcher (Shadow Agent Circuit Breaker)
#
# Usage: ./scenarios/prompt-injection/run.sh [--fleet] [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead.
# Fleet mode drives the full hub-side pipeline unless --alert-only is passed,
# but it deliberately does not mutate the hub's alignmentCheck setting. Enable
# the shadow agent temporarily on the Helm/operator-managed hub when capturing
# this scenario's expected alignment_check_failed transcript, then restore it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
