#!/usr/bin/env bash
# Concurrent Cross-Namespace Demo -- Dispatcher (#172)
#
# Usage: ./scenarios/concurrent-cross-namespace/run.sh [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead,
# which deploys the workload on the spoke and always behaves as
# --alert-only (see scripts/fleet-helper.sh). The local risk-tolerance
# policy injection (Steps 0b-0e) only steers the downstream
# validation/approval pipeline, which fleet mode never runs, so it's
# skipped entirely there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if is_fleet_mode; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
