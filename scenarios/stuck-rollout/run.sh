#!/usr/bin/env bash
# Stuck Rollout Demo -- Dispatcher
# Scenario #130: Bad image -> stuck rollout -> rollback
#
# Usage: ./scenarios/stuck-rollout/run.sh [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh.
# Fleet mode: set HUB_KUBECONFIG + SPOKE_KUBECONFIG to run fleet/run.sh
# instead (always --alert-only) -- see scripts/fleet-helper.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if is_fleet_mode; then
    fleet_warn_ignored_args "$@"
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
