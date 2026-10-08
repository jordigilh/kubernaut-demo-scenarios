#!/usr/bin/env bash
# Cleanup for Prompt Injection Detection Demo (Shadow Agent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # Restore hub-side agent policy and clean the workload/monitoring objects
    # from the spoke.
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    disable_prometheus_toolset || true
    restore_production_approval || true
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-workers
    purge_pipeline_crds
    restart_alertmanager
    exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true
restore_production_approval || true

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

echo "==> Cleaning up Prompt Injection demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-workers -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-workers --ignore-not-found --wait=true

# Shadow agent stays enabled — it should be the default-on state so we
# can track false positives across all subsequent scenario runs.

purge_pipeline_crds

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-workers &>/dev/null; do
  sleep 2
done

restart_alertmanager

echo "==> Cleanup complete."
