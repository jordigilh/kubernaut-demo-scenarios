#!/usr/bin/env bash
# SLO Error Budget Burn Demo -- Dispatcher
# Scenario #128: Error budget burning -> proactive rollback to preserve SLO
#
# Usage: ./scenarios/slo-burn/run.sh [--fleet] [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead,
# which deploys the workload on the spoke and always behaves as
# --alert-only (see scripts/fleet-helper.sh). The Probe CRD and PrometheusRule
# are applied natively to the spoke's operator-managed Prometheus, preserving
# the same blackbox_exporter /probe behavior as local mode without editing
# prometheus-config or restarting Prometheus.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
