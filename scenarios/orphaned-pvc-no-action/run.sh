#!/usr/bin/env bash
# Orphaned PVC Demo -- Dispatcher (#60, #122)
#
# Usage: ./scenarios/orphaned-pvc-no-action/run.sh [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead,
# which deploys the workload on the spoke and always behaves as
# --alert-only (see scripts/fleet-helper.sh). The warning-aware approval
# Rego patch from local/run.sh only steers the downstream validation
# pipeline, which fleet mode never runs, so it's skipped entirely there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if is_fleet_mode; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
