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
# Only the first OOMKill -> ContainerOOMKilling alert is exercised --
# fleet mode never runs the AIA/WFE remediation loop (single-cluster only
# today), so the external-actor revert cycle and ineffective-remediation-
# chain escalation this scenario is really about don't happen here. See
# kubernaut-demo-scenarios#423 for the fuller story.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    fleet_warn_ignored_args "$@"
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
