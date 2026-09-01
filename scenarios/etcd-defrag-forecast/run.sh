#!/usr/bin/env bash
# etcd Defrag Forecast Demo -- Dispatcher
# Predictive etcd defragmentation: standalone etcd cluster with injected
# fragmentation, LLM investigates health + fragmentation ratio, workflow
# performs rolling defrag with manual approval gate.
#
# Usage: ./scenarios/etcd-defrag-forecast/run.sh [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead,
# which deploys the workload on the spoke and always behaves as
# --alert-only (see scripts/fleet-helper.sh). etcd's own metrics (no
# ServiceMonitor/operator on the spoke) are picked up via a static scrape
# job, same recipe as cert-failure/db-connection-saturation.
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
