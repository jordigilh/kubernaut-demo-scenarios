#!/usr/bin/env bash
# RBAC Failure Demo -- Dispatcher
# RoleBinding deleted -> 403 Forbidden -> RestoreRoleBinding
#
# Usage: ./scenarios/rbac-failure/run.sh [--fleet] [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh.
# Fleet mode: set HUB_KUBECONFIG + SPOKE_KUBECONFIG to run fleet/run.sh
# instead (always --alert-only) -- see scripts/fleet-helper.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
