#!/usr/bin/env bash
# Resource Contention Demo -- Dispatcher
# Issue #231: Demonstrates external actor interference pattern
#
# Usage: ./scenarios/resource-contention/run.sh [--fleet] [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster (OOMKill -> fix -> external actor reverts -> repeat ->
# escalate), as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead.
# Fleet mode runs the first OOMKill -> AIA/WFE remediation cycle. The external
# actor is routed to the hub for RR state and the spoke for workload mutation;
# the Fleet validator asserts the same first-cycle contract as local mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
