#!/usr/bin/env bash
# PVC Capacity Forecast Demo -- Dispatcher (RHACM PoC)
#
# Usage: ./scenarios/pvc-capacity-forecast/run.sh [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead,
# which deploys the workload on the spoke and always behaves as
# --alert-only (see scripts/fleet-helper.sh). local/run.sh's StorageClass
# expansion-support preflight only gates the downstream remediation step
# (ExpandPersistentVolumeClaim), which fleet mode never runs -- skipped
# entirely here, since Kind's default StorageClass doesn't set
# allowVolumeExpansion anyway. kubelet_volume_stats_* isn't reported by
# cAdvisor, so fleet mode adds a second kubelet scrape job (kubelet's main
# /metrics, not /metrics/cadvisor) via fleet_ensure_kubelet_metrics_job.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if is_fleet_mode; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
