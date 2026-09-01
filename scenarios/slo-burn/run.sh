#!/usr/bin/env bash
# SLO Error Budget Burn Demo -- Dispatcher
# Scenario #128: Error budget burning -> proactive rollback to preserve SLO
#
# Usage: ./scenarios/slo-burn/run.sh [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead,
# which deploys the workload on the spoke and always behaves as
# --alert-only (see scripts/fleet-helper.sh). The Probe CRD (prometheus-
# operator) is skipped like every other operator-only kind on the spoke;
# fleet mode instead adds a raw scrape_configs job that reproduces the
# same blackbox_exporter /probe pattern by hand (params+relabel_configs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if is_fleet_mode; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
