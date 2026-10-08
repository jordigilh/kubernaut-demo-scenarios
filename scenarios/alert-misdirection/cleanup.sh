#!/usr/bin/env bash
# Cleanup for Alert Misdirection Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # Control-plane restoration stays on the hub; workload and monitoring
    # resources are deleted from the spoke by the shared helper.
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    disable_prometheus_toolset || true
    restore_production_approval || true
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-backend
    purge_pipeline_crds
    restart_alertmanager
    exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true
restore_production_approval || true

echo "==> Cleaning up alert-misdirection demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-backend -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-backend --ignore-not-found --wait=true

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

purge_pipeline_crds

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-backend &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-backend still terminating after 120s, proceeding..."
    break
  fi
done

restart_alertmanager

echo "==> Cleanup complete."
